import Foundation

/// 番組（EIT の 1 イベント）。
public struct BroadcastEvent: Sendable, Equatable {
    public var tableID: UInt8
    public var serviceID: UInt16
    public var eventID: UInt16
    /// 番組を運ぶ TS（`transport_stream_id`）とネットワーク（`original_network_id`）。番組を一意に決めるのに使う
    public var transportStreamID: UInt16 = 0
    public var originalNetworkID: UInt16 = 0
    /// 開始時刻（日本時間）。不明なら nil
    public var start: Date?
    /// 長さ（秒）。不明なら nil
    public var duration: Int?
    public var title: String
    public var text: String
    /// 番組名と概要が欠けなく復号できたか
    public var lossless: Bool
    /// ジャンル（コンテント記述子の最初のジャンル）。放送が付けていない・まだ集め直していない番組は nil
    public var genre: ProgramGenre? = nil

    /// 終了時刻。開始か長さが不明なら nil
    public var end: Date? {
        guard let start, let duration else { return nil }
        return start.addingTimeInterval(TimeInterval(duration))
    }
}

/// 番組のジャンル（ARIB STD-B10 のコンテント記述子の content_nibble_level_1・level_2）。
public struct ProgramGenre: Sendable, Equatable, Hashable {
    /// 大分類（0x0〜0xF）
    public var major: UInt8
    /// 中分類（0x0〜0xF）
    public var minor: UInt8

    public init(major: UInt8, minor: UInt8) {
        self.major = major & 0x0F
        self.minor = minor & 0x0F
    }

    /// 1 バイト（上位 4 ビットが大分類）から。番組表のデータベースに 1 列で持つため
    public init(byte: UInt8) {
        self.init(major: byte >> 4, minor: byte & 0x0F)
    }

    public var byte: UInt8 { major << 4 | minor }

    /// 大分類 0xE は「拡張」（番組付属情報などで、ジャンルそのものではない）
    static let extensionMajor: UInt8 = 0xE

    /// コンテント記述子の本体（2 バイトずつ：level_1・level_2・user_nibble × 2）から、拡張を除いた最初のジャンル
    static func first(inContentDescriptor body: ArraySlice<UInt8>) -> ProgramGenre? {
        var index = body.startIndex
        while index + 1 < body.endIndex {
            let genre = ProgramGenre(byte: body[index])
            if genre.major != extensionMajor { return genre }
            index += 2
        }
        return nil
    }
}

/// EIT の 1 セクション。版が変わったときだけ `SIReader` が返す。
public struct EITSection: Sendable, Equatable {
    public var tableID: UInt8
    public var serviceID: UInt16
    public var transportStreamID: UInt16
    public var originalNetworkID: UInt16
    public var version: UInt8
    public var sectionNumber: UInt8
    /// 番組。短形式イベント記述子の無いイベントは含まない（番組名が無いので）
    public var events: [BroadcastEvent]

    /// 自 TS の現在・次の番組（EIT[p/f] actual）。セクション 0 が現在、1 が次
    public var isPresentFollowing: Bool { tableID == SITables.tableIDPresentFollowing }
    /// 自 TS の番組表（EIT[schedule] actual）
    public var isSchedule: Bool { SITables.scheduleTableIDs.contains(tableID) }
}

/// 番組情報の表の読み方（ARIB STD-B10）。
enum SITables {
    /// EIT を運ぶ PID（H-EIT・M-EIT・L-EIT）
    static let eitPIDs: Set<UInt16> = [0x0012, 0x0026, 0x0027]
    /// TDT・TOT を運ぶ PID
    static let timePID: UInt16 = 0x0014
    /// EIT の table_id（p/f の自 TS から、スケジュールの他 TS まで）
    static let eitTableIDs: ClosedRange<UInt8> = 0x4E...0x6F
    /// 自 TS の現在・次の番組
    static let tableIDPresentFollowing: UInt8 = 0x4E
    /// 自 TS の番組表（基本情報 0x50〜0x57・拡張情報 0x58〜0x5F）
    static let scheduleTableIDs: ClosedRange<UInt8> = 0x50...0x5F
    static let tableIDTDT: UInt8 = 0x70
    static let tableIDTOT: UInt8 = 0x73
    /// 短形式イベント記述子
    static let shortEventDescriptor: UInt8 = 0x4D
    /// コンテント記述子（ジャンル）
    static let contentDescriptor: UInt8 = 0x54

    /// 日本時間
    static let japan = TimeZone(secondsFromGMT: 9 * 3600)!

    /// MJD（16 ビット）＋ BCD の時分秒（24 ビット）。すべて 1 なら不明
    static func time(_ bytes: ArraySlice<UInt8>) -> Date? {
        let base = bytes.startIndex
        guard bytes.count >= 5, !bytes.allSatisfy({ $0 == 0xFF }) else { return nil }
        let mjd = Int(bytes[base]) << 8 | Int(bytes[base + 1])
        // MJD 40587 = 1970-01-01
        let days = mjd - 40587
        guard let hours = bcd(bytes[base + 2]), let minutes = bcd(bytes[base + 3]), let seconds = bcd(bytes[base + 4]) else { return nil }
        let local = TimeInterval(days * 86400 + hours * 3600 + minutes * 60 + seconds)
        return Date(timeIntervalSince1970: local - TimeInterval(japan.secondsFromGMT()))
    }

    /// BCD の時分秒の長さ（秒）。すべて 1 なら不明
    static func duration(_ bytes: ArraySlice<UInt8>) -> Int? {
        let base = bytes.startIndex
        guard bytes.count >= 3, !bytes.allSatisfy({ $0 == 0xFF }),
              let hours = bcd(bytes[base]), let minutes = bcd(bytes[base + 1]), let seconds = bcd(bytes[base + 2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func bcd(_ byte: UInt8) -> Int? {
        let high = Int(byte >> 4), low = Int(byte & 0x0F)
        guard high < 10, low < 10 else { return nil }
        return high * 10 + low
    }

    /// EIT のセクションを読む（CRC は呼び出し側で確かめる）
    static func parseEIT(_ section: [UInt8]) -> EITSection? {
        guard section.count >= 18, eitTableIDs.contains(section[0]) else { return nil }
        let tableID = section[0]
        let serviceID = UInt16(section[3]) << 8 | UInt16(section[4])
        let version = (section[5] >> 1) & 0x1F
        let sectionNumber = section[6]
        let transportStreamID = UInt16(section[8]) << 8 | UInt16(section[9])
        let originalNetworkID = UInt16(section[10]) << 8 | UInt16(section[11])
        let end = section.count - 4
        var events: [BroadcastEvent] = []
        var offset = 14
        while offset + 12 <= end {
            let eventID = UInt16(section[offset]) << 8 | UInt16(section[offset + 1])
            let start = time(section[(offset + 2)..<(offset + 7)])
            let duration = duration(section[(offset + 7)..<(offset + 10)])
            let loopLength = Int(section[offset + 10] & 0x0F) << 8 | Int(section[offset + 11])
            let loopEnd = offset + 12 + loopLength
            guard loopEnd <= end else { break }
            var short: (String, String, Bool)?
            var genre: ProgramGenre?
            for (tag, body) in PSI.descriptors(section, from: offset + 12, to: loopEnd) {
                switch tag {
                case shortEventDescriptor: short = short ?? shortEvent(body)
                case contentDescriptor: genre = genre ?? ProgramGenre.first(inContentDescriptor: body)
                default: break
                }
            }
            // 番組名の無い番組（拡張情報だけのセクション）は載せない
            if let (title, text, lossless) = short {
                events.append(BroadcastEvent(tableID: tableID, serviceID: serviceID, eventID: eventID,
                                             transportStreamID: transportStreamID, originalNetworkID: originalNetworkID,
                                             start: start, duration: duration, title: title, text: text, lossless: lossless,
                                             genre: genre))
            }
            offset = loopEnd
        }
        return EITSection(tableID: tableID, serviceID: serviceID, transportStreamID: transportStreamID,
                          originalNetworkID: originalNetworkID, version: version, sectionNumber: sectionNumber, events: events)
    }

    /// 短形式イベント記述子（言語 3 バイト・番組名・概要）
    static func shortEvent(_ body: ArraySlice<UInt8>) -> (String, String, Bool)? {
        let bytes = Array(body)
        guard bytes.count >= 5 else { return nil }
        let titleLength = Int(bytes[3])
        let textAt = 4 + titleLength
        guard textAt < bytes.count else { return nil }
        let textLength = Int(bytes[textAt])
        guard textAt + 1 + textLength <= bytes.count else { return nil }
        let title = ARIBStringDecoder.decode(bytes[4..<textAt])
        let text = ARIBStringDecoder.decode(bytes[(textAt + 1)..<(textAt + 1 + textLength)])
        return (title.text, text.text, title.lossless && text.lossless)
    }
}

/// TS から番組情報（EIT）と放送の時刻（TDT・TOT）を読む。
public final class SIReader {
    public enum Item: Sendable, Equatable {
        /// 版が変わった（または初めて届いた）EIT のセクション
        case eventSection(EITSection)
        /// TDT・TOT の時刻
        case time(Date)
    }

    /// 同じ表の同じセクションを見分ける
    private struct SectionKey: Hashable {
        var tableID: UInt8
        var transportStreamID: UInt16
        var serviceID: UInt16
        var sectionNumber: UInt8
    }

    private var residue = [UInt8]()
    private var sections: [UInt16: SectionAssembler] = [:]
    /// 同じ版の同じセクションは繰り返し届くので、版が変わったときだけ返す。
    /// 版ごとに覚えると番組が切り替わるたびに増え続けるので、セクションごとに最後の版だけを持つ
    /// （数は表・サービス・セクション番号の組み合わせで頭打ちになる）
    private var versions: [SectionKey: UInt8] = [:]

    public init() {}

    public func feed(_ data: Data) -> [Item] {
        var items: [Item] = []
        residue.append(contentsOf: data)
        var offset = 0
        while residue.count - offset >= TSPacket.size {
            guard residue[offset] == TSPacket.syncByte else {
                offset += 1
                continue
            }
            let packet = residue[offset..<offset + TSPacket.size]
            offset += TSPacket.size
            let base = packet.startIndex
            let pid = UInt16(packet[base + 1] & 0x1F) << 8 | UInt16(packet[base + 2])
            guard SITables.eitPIDs.contains(pid) || pid == SITables.timePID, packet[base + 3] & 0x10 != 0 else { continue }
            let start = 4 + (packet[base + 3] & 0x20 != 0 ? 1 + Int(packet[base + 4]) : 0)
            guard start < TSPacket.size else { continue }
            let assembler = sections[pid] ?? SectionAssembler()
            sections[pid] = assembler
            let found = Array(packet).withUnsafeBufferPointer {
                assembler.feed(UnsafeBufferPointer(rebasing: $0[start...]), unitStart: packet[base + 1] & 0x40 != 0, lost: false)
            }
            for section in found {
                if let item = handle(section) { items.append(item) }
            }
        }
        residue.removeFirst(offset)
        return items
    }

    private func handle(_ section: [UInt8]) -> Item? {
        guard let tableID = section.first else { return nil }
        if tableID == SITables.tableIDTDT || tableID == SITables.tableIDTOT {
            // TDT には CRC が無い
            guard tableID == SITables.tableIDTDT || PSI.crcIsValid(section), section.count >= 8,
                  let time = SITables.time(section[3..<8]) else { return nil }
            return .time(time)
        }
        guard PSI.crcIsValid(section), let parsed = SITables.parseEIT(section) else { return nil }
        let key = SectionKey(tableID: tableID, transportStreamID: parsed.transportStreamID, serviceID: parsed.serviceID,
                             sectionNumber: parsed.sectionNumber)
        guard versions.updateValue(parsed.version, forKey: key) != parsed.version else { return nil }
        return .eventSection(parsed)
    }
}
