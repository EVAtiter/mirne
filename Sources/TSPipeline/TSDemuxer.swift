import Foundation

/// PMT に書かれた 1 本のエレメンタリーストリーム。
public struct ElementaryStream: Sendable, Equatable {
    public let pid: UInt16
    public let streamType: UInt8
    /// ストリーム識別記述子（0x52）の component_tag。ARIB では主音声 0x10・副音声 0x11・字幕 0x30 など
    public var componentTag: UInt8?
    /// この ES に付いた限定受信方式記述子（0x09）の ECM の PID
    public var ecmPID: UInt16?

    public init(pid: UInt16, streamType: UInt8, componentTag: UInt8? = nil, ecmPID: UInt16? = nil) {
        self.pid = pid
        self.streamType = streamType
        self.componentTag = componentTag
        self.ecmPID = ecmPID
    }

    /// MPEG-2 Video（ISO/IEC 13818-2）
    public static let mpeg2Video: UInt8 = 0x02
    /// AAC（ADTS）
    public static let aacADTS: UInt8 = 0x0F
    /// H.264（ワンセグ。1.0 では扱わない）
    public static let h264: UInt8 = 0x1B
    /// 字幕・文字スーパー（ARIB の独立 PES）
    public static let privatePES: UInt8 = 0x06
}

/// 1 サービスの PMT。
public struct ProgramMap: Sendable, Equatable {
    public let programNumber: UInt16
    public let version: UInt8
    public let pcrPID: UInt16
    public let streams: [ElementaryStream]
    /// 番組全体に付いた限定受信方式記述子（0x09）の ECM の PID
    public var ecmPIDs: [UInt16] = []

    /// 最初の映像（MPEG-2 Video）
    public var video: ElementaryStream? { streams.first { $0.streamType == ElementaryStream.mpeg2Video } }
    /// 音声（AAC）。複数あれば先頭が主音声
    public var audio: [ElementaryStream] { streams.filter { $0.streamType == ElementaryStream.aacADTS } }
}

/// 組み立て終えた PES。
public struct PESPacket: Sendable {
    public let pid: UInt16
    public let streamID: UInt8
    /// 90 kHz・33 ビット（巻き戻りは呼び出し側で扱う）
    public let pts: Int64?
    public let dts: Int64?
    public let payload: Data
    /// 組み立ての途中で continuity_counter が飛んだ（中身が欠けている）
    public let damaged: Bool
}

/// demux の出来事。
public enum TSDemuxEvent: Sendable {
    /// PMT が見つかった、または版が変わった
    case program(ProgramMap)
    case pes(PESPacket)
    /// PCR（27 MHz の値を 90 kHz に丸めたもの）。`discontinuity` は送出側が立てた不連続の印
    case pcr(base: Int64, discontinuity: Bool)
}

/// TS を PAT → PMT → PES の順にほどく。
///
/// 1 サービスだけを相手にする（`serviceID` を指定しなければ PAT の最初の番組）。
/// 映像・音声・字幕の PES と PCR を出来事として返す。PSI は CRC を確かめてから使う。
///
/// これがサービスフィルタを兼ねる。Mirakurun の TSFilter は対象サービスだけの TS を作って
/// プレイヤーへ渡す（PAT を 1 番組に書き換える）が、mirne は自分で demux するので、ここで対象の PMT の
/// PID だけを拾えば足りる。番組情報（SDT・EIT・TOT など）は SI の解析が TS 全体から読む。
public final class TSDemuxer {
    /// 対象のサービス。nil なら PAT の最初の番組
    public private(set) var serviceID: UInt16?
    /// 直近の PAT（番組番号 → PMT の PID。NIT の 0 番は除く）
    public private(set) var programs: [UInt16: UInt16] = [:]

    private var residue = [UInt8]()
    private var pmtPID: UInt16?
    private var program: ProgramMap?
    private var sections: [UInt16: SectionAssembler] = [:]
    private var pes: [UInt16: PESAssembler] = [:]
    private var lastCounter = [Int8](repeating: -1, count: 8192)

    public init(serviceID: UInt16? = nil) {
        self.serviceID = serviceID
    }

    /// 今の PMT
    public var currentProgram: ProgramMap? { program }

    /// 届いたバイト列を渡す。受信の切れ目はパケットの境目と一致しなくてよい
    public func feed(_ data: Data) -> [TSDemuxEvent] {
        var events: [TSDemuxEvent] = []
        residue.append(contentsOf: data)
        var offset = 0
        while residue.count - offset >= TSPacket.size {
            if residue[offset] != TSPacket.syncByte {
                offset += 1
                continue
            }
            residue.withUnsafeBufferPointer { buffer in
                handlePacket(UnsafeBufferPointer(rebasing: buffer[offset..<offset + TSPacket.size]), into: &events)
            }
            offset += TSPacket.size
        }
        residue.removeFirst(offset)
        return events
    }

    /// 同じ TS の中で別のサービスに切り替える。
    ///
    /// 受信の途中の端数は残し、PMT と組み立て途中の PES を捨てる。PAT は覚えているので、
    /// 次の PMT が届けば（通常 0.1 秒以内）新しいサービスの PES が出始める。
    public func select(serviceID newServiceID: UInt16?) {
        serviceID = newServiceID
        program = nil
        pes.removeAll()
        // 指定が無ければ PAT の最初の番組。指定したサービスが PAT に無ければ、次の PAT を待つ
        let found = newServiceID.map { programs[$0] } ?? programs.keys.min().flatMap { programs[$0] }
        if let pmt = found {
            if pmtPID != pmt { sections[pmt] = nil }
            pmtPID = pmt
        } else {
            pmtPID = nil
        }
    }

    /// 選局し直したときなど、途中の状態を捨てる（PMT は次に届いたもので決め直す）
    public func reset() {
        residue.removeAll()
        pmtPID = nil
        program = nil
        programs.removeAll()
        sections.removeAll()
        pes.removeAll()
        lastCounter = [Int8](repeating: -1, count: 8192)
    }

    // MARK: - パケット

    private func handlePacket(_ packet: UnsafeBufferPointer<UInt8>, into events: inout [TSDemuxEvent]) {
        let transportError = packet[1] & 0x80 != 0
        let unitStart = packet[1] & 0x40 != 0
        let pid = (UInt16(packet[1] & 0x1F) << 8) | UInt16(packet[2])
        let control = packet[3]
        let hasAdaptation = control & 0x20 != 0
        let hasPayload = control & 0x10 != 0
        let counter = Int8(control & 0x0F)
        if pid == TSPacket.nullPID || transportError { return }

        var payloadStart = 4
        var discontinuityIndicator = false
        if hasAdaptation {
            let length = Int(packet[4])
            payloadStart = 5 + length
            if length > 0 {
                let flags = packet[5]
                discontinuityIndicator = flags & 0x80 != 0
                // PCR
                if flags & 0x10 != 0, length >= 7, pid == program?.pcrPID {
                    let base = (Int64(packet[6]) << 25) | (Int64(packet[7]) << 17) | (Int64(packet[8]) << 9)
                        | (Int64(packet[9]) << 1) | (Int64(packet[10]) >> 7)
                    events.append(.pcr(base: base, discontinuity: discontinuityIndicator))
                }
            }
        }

        // continuity_counter（数え方は TSPacketCounter と同じ）
        var lost = false
        let last = lastCounter[Int(pid)]
        if hasPayload, last >= 0, !discontinuityIndicator, counter != last, counter != (last + 1) & 0x0F {
            lost = true
        }
        if hasPayload { lastCounter[Int(pid)] = counter }

        guard hasPayload, payloadStart < TSPacket.size else { return }
        let payload = UnsafeBufferPointer(rebasing: packet[payloadStart..<TSPacket.size])

        if pid == 0 {
            feedSection(pid: pid, payload: payload, unitStart: unitStart, lost: lost) { self.handlePAT($0) }
        } else if pid == pmtPID {
            feedSection(pid: pid, payload: payload, unitStart: unitStart, lost: lost) { section in
                if let map = self.handlePMT(section) { events.append(.program(map)) }
            }
        } else if let program, program.streams.contains(where: { $0.pid == pid }) {
            feedPES(pid: pid, payload: payload, unitStart: unitStart, lost: lost, into: &events)
        }
    }

    // MARK: - PSI

    private func feedSection(pid: UInt16, payload: UnsafeBufferPointer<UInt8>, unitStart: Bool, lost: Bool,
                             handler: ([UInt8]) -> Void) {
        let assembler = sections[pid] ?? SectionAssembler()
        sections[pid] = assembler
        for section in assembler.feed(payload, unitStart: unitStart, lost: lost) where PSI.crcIsValid(section) {
            handler(section)
        }
    }

    private func handlePAT(_ section: [UInt8]) {
        guard let table = PSI.parsePAT(section) else { return }
        programs = table
        let wanted = serviceID ?? table.keys.min()
        guard let wanted, let pid = table[wanted] else { return }
        if pmtPID != pid {
            pmtPID = pid
            program = nil
        }
    }

    private func handlePMT(_ section: [UInt8]) -> ProgramMap? {
        guard let map = PSI.parsePMT(section) else { return nil }
        if let serviceID, serviceID != map.programNumber { return nil }
        guard map != program else { return nil }
        // ES の構成が変わったら、組み立て途中の PES を捨てる
        let kept = Set(map.streams.map(\.pid))
        pes = pes.filter { kept.contains($0.key) }
        program = map
        return map
    }

    // MARK: - PES

    private func feedPES(pid: UInt16, payload: UnsafeBufferPointer<UInt8>, unitStart: Bool, lost: Bool,
                         into events: inout [TSDemuxEvent]) {
        if unitStart {
            // 前の PES を出し切る（映像の PES は長さが 0 = 不定なので、次の始まりで区切る）
            if let finished = pes[pid]?.finish(pid: pid) { events.append(.pes(finished)) }
            let assembler = PESAssembler(first: payload)
            // 1 パケットに収まる PES（字幕など）は、ここで完結している。次の PES の始まりまで待たせない
            // （待たせると、字幕が次の字幕の届く 0.5〜1 秒後まで出なかった）
            if assembler.isComplete, let finished = assembler.finish(pid: pid) {
                pes[pid] = nil
                events.append(.pes(finished))
            } else {
                pes[pid] = assembler
            }
            return
        }
        guard let assembler = pes[pid] else { return }  // 途中から始まった PES は捨てる
        if lost { assembler.damaged = true }
        assembler.append(payload)
        if assembler.isComplete, let finished = assembler.finish(pid: pid) {
            pes[pid] = nil
            events.append(.pes(finished))
        }
    }
}

/// PSI のセクションを組み立てる（pointer_field と、パケットをまたぐセクションに対応）。
final class SectionAssembler {
    private var buffer = [UInt8]()
    private var collecting = false

    func feed(_ payload: UnsafeBufferPointer<UInt8>, unitStart: Bool, lost: Bool) -> [[UInt8]] {
        var output: [[UInt8]] = []
        if lost {
            buffer.removeAll()
            collecting = false
        }
        var bytes = Array(payload)
        if unitStart {
            guard let pointer = bytes.first else { return output }
            // pointer_field の前は、前のセクションの続き
            let tail = Array(bytes[1..<min(1 + Int(pointer), bytes.count)])
            if collecting {
                buffer.append(contentsOf: tail)
                output.append(contentsOf: drain())
            }
            buffer = Array(bytes[min(1 + Int(pointer), bytes.count)...])
            collecting = true
            bytes = []
        } else if collecting {
            buffer.append(contentsOf: bytes)
        }
        output.append(contentsOf: drain())
        return output
    }

    /// バッファから完成したセクションを取り出す
    private func drain() -> [[UInt8]] {
        var output: [[UInt8]] = []
        while buffer.count >= 3 {
            if buffer[0] == 0xFF {
                // スタッフィング。この後にセクションは無い
                buffer.removeAll()
                collecting = false
                break
            }
            let length = 3 + Int((UInt16(buffer[1] & 0x0F) << 8) | UInt16(buffer[2]))
            guard buffer.count >= length else { break }
            output.append(Array(buffer[0..<length]))
            buffer.removeFirst(length)
        }
        return output
    }
}

/// PES を組み立てる。
final class PESAssembler {
    private var buffer: [UInt8]
    var damaged = false

    init(first payload: UnsafeBufferPointer<UInt8>) {
        buffer = Array(payload)
    }

    func append(_ payload: UnsafeBufferPointer<UInt8>) {
        buffer.append(contentsOf: payload)
    }

    /// PES_packet_length が書かれていて、そのぶん揃った
    var isComplete: Bool {
        guard buffer.count >= 6 else { return false }
        let length = Int((UInt16(buffer[4]) << 8) | UInt16(buffer[5]))
        return length > 0 && buffer.count >= 6 + length
    }

    func finish(pid: UInt16) -> PESPacket? {
        guard buffer.count >= 9, buffer[0] == 0, buffer[1] == 0, buffer[2] == 1 else { return nil }
        let streamID = buffer[3]
        let declared = Int((UInt16(buffer[4]) << 8) | UInt16(buffer[5]))
        let headerLength = Int(buffer[8])
        let flags = buffer[7]
        var pts: Int64?
        var dts: Int64?
        if flags & 0x80 != 0, buffer.count >= 14 { pts = Self.timestamp(buffer, at: 9) }
        if flags & 0x40 != 0, buffer.count >= 19 { dts = Self.timestamp(buffer, at: 14) }
        let start = 9 + headerLength
        let end = declared > 0 ? min(buffer.count, 6 + declared) : buffer.count
        guard start <= end else { return nil }
        return PESPacket(pid: pid, streamID: streamID, pts: pts, dts: dts,
                         payload: Data(buffer[start..<end]), damaged: damaged)
    }

    private static func timestamp(_ bytes: [UInt8], at offset: Int) -> Int64 {
        (Int64(bytes[offset] & 0x0E) << 29) | (Int64(bytes[offset + 1]) << 22) | (Int64(bytes[offset + 2] & 0xFE) << 14)
            | (Int64(bytes[offset + 3]) << 7) | (Int64(bytes[offset + 4]) >> 1)
    }
}

/// PSI の共通部分。
enum PSI {
    static let tableIDPAT: UInt8 = 0x00
    static let tableIDPMT: UInt8 = 0x02
    /// 限定受信方式記述子
    static let conditionalAccessDescriptor: UInt8 = 0x09
    /// ストリーム識別記述子
    static let streamIdentifierDescriptor: UInt8 = 0x52

    /// PAT を読む（番組番号 → PMT の PID。NIT の 0 番は除く）
    static func parsePAT(_ section: [UInt8]) -> [UInt16: UInt16]? {
        guard section.first == tableIDPAT, section.count >= 12 else { return nil }
        var table: [UInt16: UInt16] = [:]
        let end = section.count - 4
        var offset = 8
        while offset + 4 <= end {
            let number = (UInt16(section[offset]) << 8) | UInt16(section[offset + 1])
            let pid = (UInt16(section[offset + 2] & 0x1F) << 8) | UInt16(section[offset + 3])
            offset += 4
            if number != 0 { table[number] = pid }
        }
        return table
    }

    /// PMT を読む
    static func parsePMT(_ section: [UInt8]) -> ProgramMap? {
        guard section.first == tableIDPMT, section.count >= 16 else { return nil }
        let number = (UInt16(section[3]) << 8) | UInt16(section[4])
        let version = (section[5] >> 1) & 0x1F
        let pcrPID = (UInt16(section[8] & 0x1F) << 8) | UInt16(section[9])
        let infoLength = Int((UInt16(section[10] & 0x0F) << 8) | UInt16(section[11]))
        let end = section.count - 4
        guard 12 + infoLength <= end else { return nil }
        let programDescriptors = descriptors(section, from: 12, to: 12 + infoLength)
        var offset = 12 + infoLength
        var streams: [ElementaryStream] = []
        while offset + 5 <= end {
            let type = section[offset]
            let pid = (UInt16(section[offset + 1] & 0x1F) << 8) | UInt16(section[offset + 2])
            let descriptorLength = Int((UInt16(section[offset + 3] & 0x0F) << 8) | UInt16(section[offset + 4]))
            var stream = ElementaryStream(pid: pid, streamType: type)
            for (tag, body) in descriptors(section, from: offset + 5, to: min(offset + 5 + descriptorLength, end)) {
                if tag == streamIdentifierDescriptor, let first = body.first { stream.componentTag = first }
                if tag == conditionalAccessDescriptor { stream.ecmPID = caPID(body) }
            }
            streams.append(stream)
            offset += 5 + descriptorLength
        }
        var map = ProgramMap(programNumber: number, version: version, pcrPID: pcrPID, streams: streams)
        map.ecmPIDs = programDescriptors.filter { $0.tag == conditionalAccessDescriptor }.compactMap { caPID($0.body) }
        return map
    }

    /// 記述子の並びを (tag, 本体) に分ける
    static func descriptors(_ bytes: [UInt8], from start: Int, to end: Int) -> [(tag: UInt8, body: ArraySlice<UInt8>)] {
        var output: [(UInt8, ArraySlice<UInt8>)] = []
        var offset = start
        while offset + 2 <= end {
            let tag = bytes[offset]
            let length = Int(bytes[offset + 1])
            guard offset + 2 + length <= end else { break }
            output.append((tag, bytes[(offset + 2)..<(offset + 2 + length)]))
            offset += 2 + length
        }
        return output
    }

    /// 限定受信方式記述子の CA_PID（CA_system_id 2 バイトの後の 13 ビット）。
    /// 地上デジタル放送の字幕の ES には CA_PID が 0x1FFF（ヌル）の記述子が付く（スクランブルしない印）ので、
    /// それは ECM として扱わない（実放送で確認）
    private static func caPID(_ body: ArraySlice<UInt8>) -> UInt16? {
        guard body.count >= 4 else { return nil }
        let base = body.startIndex
        let pid = (UInt16(body[base + 2] & 0x1F) << 8) | UInt16(body[base + 3])
        return pid == TSPacket.nullPID ? nil : pid
    }

    /// CRC-32/MPEG-2 の表
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index) << 24
        for _ in 0..<8 {
            value = value & 0x8000_0000 != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1
        }
        return value
    }

    /// セクション全体（CRC を含む）の CRC が 0 になるか
    static func crcIsValid(_ section: [UInt8]) -> Bool {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in section {
            crc = (crc << 8) ^ table[Int(((crc >> 24) ^ UInt32(byte)) & 0xFF)]
        }
        return crc == 0
    }
}
