import AudioToolbox
import CoreMedia
import Foundation
import os

/// ADTS ヘッダ（地上デジタル放送の音声は AAC-LC・48 kHz の ADTS）。
struct ADTSHeader: Equatable {
    static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
    /// AAC の 1 フレームのサンプル数
    static let samplesPerFrame = 1024

    /// audioObjectType（2 = AAC-LC）
    let objectType: Int
    let sampleRateIndex: Int
    let channelConfiguration: Int
    /// ヘッダを含むフレーム全体の長さ
    let frameLength: Int
    let headerLength: Int

    var sampleRate: Int { Self.sampleRates[min(sampleRateIndex, Self.sampleRates.count - 1)] }
    /// channel_configuration 0（PCE で指定）は、いまはステレオとして扱う
    var channels: Int { channelConfiguration == 7 ? 8 : max(channelConfiguration, 2) }

    init?(_ bytes: UnsafeRawBufferPointer, at offset: Int) {
        guard offset + 7 <= bytes.count, bytes[offset] == 0xFF, bytes[offset + 1] & 0xF0 == 0xF0 else { return nil }
        let protectionAbsent = bytes[offset + 1] & 1 == 1
        objectType = Int(bytes[offset + 2] >> 6) + 1
        sampleRateIndex = Int((bytes[offset + 2] >> 2) & 0x0F)
        channelConfiguration = Int((bytes[offset + 2] & 1) << 2 | bytes[offset + 3] >> 6)
        frameLength = Int(bytes[offset + 3] & 0x03) << 11 | Int(bytes[offset + 4]) << 3 | Int(bytes[offset + 5] >> 5)
        headerLength = protectionAbsent ? 7 : 9
        guard frameLength > headerLength, sampleRateIndex < Self.sampleRates.count else { return nil }
    }

    /// 同じ形式か（変わったら変換器を作り直す）
    func sameFormat(as other: ADTSHeader) -> Bool {
        objectType == other.objectType && sampleRateIndex == other.sampleRateIndex
            && channelConfiguration == other.channelConfiguration
    }
}

/// 二重音声（デュアルモノ）のどちらを出すか。
public enum DualMonoChannel: Sendable, Equatable, CaseIterable {
    /// 主音声を左右から
    case main
    /// 副音声を左右から
    case sub
    /// 主を左、副を右から
    case both

    /// 二重音声の番組で最初に出すもの（テレビと同じく主音声）
    public static let initial = DualMonoChannel.main
}

/// AAC（ADTS）を AudioToolbox で PCM（Float32・インターリーブ）に復号し、CMSampleBuffer にする。
///
/// 自分で PCM にしてから出力へ渡すのは、二重音声の主・副を選んで左右へ振り分けるため。
///
/// **二重音声**は、channel_configuration 2 の ADTS の 1 フレームに単一チャンネル要素（SCE）が 2 つ入る形
/// （普通のステレオは 2 チャンネルの要素 CPE が 1 つ）。AudioToolbox は channel_configuration 2 のままだと
/// このフレームを 1 つも復号できない（実測。235 フレームすべて失敗）。そこで、SCE を前方の 2 チャンネルに
/// 割り当てる PCE を入れた設定（AudioSpecificConfig）を ESDS に包んで magic cookie として渡す
/// （AudioSpecificConfig をそのまま渡すと受け付けない）。復号すると主が左、副が右の 2 チャンネルになる。
final class AACDecoder {
    private var converter: AudioConverterRef?
    private var current: ADTSHeader?
    /// 今の変換器が二重音声として作られているか
    private(set) var isDualMono = false
    /// 今の変換器のチャンネル構成（まだ 1 フレームも読んでいなければ nil）
    var layout: AudioLayout? {
        current.map { AudioLayout(channelConfiguration: $0.channelConfiguration, dualMono: isDualMono) }
    }
    private var outputFormat = AudioStreamBasicDescription()
    private(set) var formatDescription: CMAudioFormatDescription?
    private let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "audio")

    /// 復号できなかったフレーム
    private(set) var failures = 0
    private(set) var decodedFrames = 0
    /// 受け取った PES の数・PTS の無いもの・頭が ADTS の同期語でないもの（診断用）
    private(set) var pesCount = 0
    private(set) var pesWithoutPTS = 0
    private(set) var pesNotStartingWithSync = 0
    /// PES をまたいで組み立てたフレーム・同期語を探すために読み飛ばしたバイト・時刻が分からず捨てたフレーム（診断用）
    private(set) var framesAcrossPES = 0
    private(set) var skippedBytes = 0
    private(set) var untimedFrames = 0

    /// 前の PES から持ち越した、まだ 1 フレームにならない分。放送では ADTS のフレームが PES をまたぐことがある
    private var carried = Data()
    /// 次のフレームの時刻の見込み（90 kHz）。PES の PTS が当たらないフレームに使う
    private var nextPTS: Int64?

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }

    /// 1 つの PES の中身を復号する。二重音声なら `dualMono` の音声を出す（二重音声でなければ使わない）。
    ///
    /// ADTS のフレームは PES の区切りと揃っているとは限らない（実放送で、頭が同期語でない PES ばかりの局があり、
    /// PES の頭から読む作りでは 1 フレームも読めず音が出なかった）。読み切れなかった残りは次の PES へ持ち越し、
    /// 同期語がずれていれば探し直す。`pts`（PES の PTS）は、その PES の中で始まる最初のフレームの時刻。
    /// それ以外のフレームは、前のフレームから 1024 サンプルずつ進めた時刻にする
    func decode(_ payload: Data, pts: Int64?, dualMono: DualMonoChannel = .initial) -> [CMSampleBuffer] {
        pesCount += 1
        if pts == nil { pesWithoutPTS += 1 }
        if payload.count < 2 || payload[payload.startIndex] != 0xFF || payload[payload.startIndex + 1] & 0xF0 != 0xF0 {
            pesNotStartingWithSync += 1
        }
        let carriedCount = carried.count
        var bytes = carried
        bytes.append(payload)
        var output: [CMSampleBuffer] = []
        var usedPTS = false
        var consumed = 0
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset + 7 <= buffer.count {
                guard let header = ADTSHeader(buffer, at: offset), Self.followedBySync(buffer, after: offset + header.frameLength) else {
                    // 同期語でない（または偽の同期語）。1 バイトずつ探し直す
                    offset += 1
                    skippedBytes += 1
                    continue
                }
                guard offset + header.frameLength <= buffer.count else { break }  // 続きは次の PES
                let frameDuration = Int64(ADTSHeader.samplesPerFrame) * 90_000 / Int64(header.sampleRate)
                let framePTS: Int64
                if let pts, !usedPTS, offset >= carriedCount {
                    framePTS = pts
                    usedPTS = true
                } else if let next = nextPTS {
                    framePTS = next
                } else {
                    // 時刻の分からないフレーム（受信の始めで、PTS の付いたフレームより前）は捨てる
                    untimedFrames += 1
                    offset += header.frameLength
                    continue
                }
                if offset < carriedCount { framesAcrossPES += 1 }
                nextPTS = framePTS + frameDuration
                let raw = UnsafeRawBufferPointer(rebasing: buffer[(offset + header.headerLength)..<(offset + header.frameLength)])
                let dualMonoFrame = header.channelConfiguration == 2 && AACRawDataBlock.startsWithSingleChannelElement(raw)
                if current.map({ !header.sameFormat(as: $0) }) ?? true || dualMonoFrame != isDualMono {
                    rebuild(for: header, dualMono: dualMonoFrame)
                }
                if let sample = decodeFrame(raw, pts: framePTS, dualMono: isDualMono ? dualMono : nil) {
                    output.append(sample)
                    decodedFrames += 1
                } else {
                    failures += 1
                }
                offset += header.frameLength
            }
            consumed = min(offset, buffer.count)
        }
        carried = consumed < bytes.count ? bytes.subdata(in: (bytes.startIndex + consumed)..<bytes.endIndex) : Data()
        if carried.count > AACFraming.carryLimit {
            // フレームにならないまま溜まり続けている（壊れた入力）。持ち越しを捨てて次の PES から読み直す
            skippedBytes += carried.count
            carried = Data()
        }
        return output
    }

    /// 持ち越しを捨てる（PES が欠けたとき。欠けた PES とつなぐと、偽のフレームを作ってしまう）
    func discardCarried() {
        carried = Data()
        nextPTS = nil
    }

    /// 途中の状態を捨てる（選局し直したときなど）
    func reset() {
        if let converter { AudioConverterReset(converter) }
        discardCarried()
    }

    /// `offset` に次のフレームの同期語があるか（バッファの終わりなら、まだ分からないので認める）。偽の同期語を見分ける
    private static func followedBySync(_ buffer: UnsafeRawBufferPointer, after offset: Int) -> Bool {
        guard offset + 2 <= buffer.count else { return true }
        return buffer[offset] == 0xFF && buffer[offset + 1] & 0xF0 == 0xF0
    }

    private func rebuild(for header: ADTSHeader, dualMono: Bool) {
        if let converter { AudioConverterDispose(converter) }
        converter = nil
        current = header
        isDualMono = dualMono

        var input = AudioStreamBasicDescription(
            mSampleRate: Float64(header.sampleRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(ADTSHeader.samplesPerFrame), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(header.channels), mBitsPerChannel: 0, mReserved: 0)
        outputFormat = AudioStreamBasicDescription(
            mSampleRate: Float64(header.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * header.channels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * header.channels), mChannelsPerFrame: UInt32(header.channels),
            mBitsPerChannel: 32, mReserved: 0)
        let status = AudioConverterNew(&input, &outputFormat, &converter)
        guard status == noErr, let converter else {
            logger.error("AudioConverterNew が失敗した: \(status, privacy: .public)")
            return
        }
        if dualMono {
            let cookie = DualMonoConfiguration.esds(
                DualMonoConfiguration.audioSpecificConfig(objectType: header.objectType, sampleRateIndex: header.sampleRateIndex))
            let set = cookie.withUnsafeBytes {
                AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32($0.count), $0.baseAddress!)
            }
            if set != noErr { logger.error("二重音声の設定を渡せない: \(set, privacy: .public)") }
        }

        // 出力のチャンネル配置（5.1ch の並びを出力側へ正しく伝える）
        var layoutSize: UInt32 = 0
        var layoutData: Data?
        if AudioConverterGetPropertyInfo(converter, kAudioConverterOutputChannelLayout, &layoutSize, nil) == noErr, layoutSize > 0 {
            var buffer = Data(count: Int(layoutSize))
            let got = buffer.withUnsafeMutableBytes {
                AudioConverterGetProperty(converter, kAudioConverterOutputChannelLayout, &layoutSize, $0.baseAddress!)
            }
            if got == noErr { layoutData = buffer }
        }
        if layoutData == nil {
            var stereo = AudioChannelLayout()
            stereo.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            layoutData = Data(bytes: &stereo, count: MemoryLayout<AudioChannelLayout>.size)
        }
        var description: CMAudioFormatDescription?
        layoutData!.withUnsafeBytes { layout in
            _ = CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &outputFormat, layoutSize: layout.count,
                layout: layout.bindMemory(to: AudioChannelLayout.self).baseAddress,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        }
        formatDescription = description
        logger.info("AAC: \(header.sampleRate, privacy: .public) Hz・\(header.channels, privacy: .public) ch（channel_configuration \(header.channelConfiguration, privacy: .public)\(dualMono ? "・二重音声" : "", privacy: .public)）")
    }

    /// `dualMono` が nil でなければ、二重音声の主（左）・副（右）からそれを選んで左右へ出す
    private func decodeFrame(_ raw: UnsafeRawBufferPointer, pts: Int64, dualMono: DualMonoChannel?) -> CMSampleBuffer? {
        guard let converter, let formatDescription, let base = raw.baseAddress else { return nil }
        let channels = Int(outputFormat.mChannelsPerFrame)
        let byteCount = ADTSHeader.samplesPerFrame * channels * MemoryLayout<Float32>.size
        let pcm = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)

        let context = ConverterInput(data: base, size: UInt32(raw.count))
        var packets = UInt32(ADTSHeader.samplesPerFrame)
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: UInt32(channels), mDataByteSize: UInt32(byteCount), mData: pcm))
        let status = withExtendedLifetime(context) {
            AudioConverterFillComplexBuffer(converter, { _, packetCount, data, descriptions, userData in
                let input = Unmanaged<ConverterInput>.fromOpaque(userData!).takeUnretainedValue()
                guard !input.consumed else {
                    packetCount.pointee = 0
                    return ConverterInput.noMoreData
                }
                input.consumed = true
                data.pointee.mNumberBuffers = 1
                data.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: input.data)
                data.pointee.mBuffers.mDataByteSize = input.size
                data.pointee.mBuffers.mNumberChannels = 0
                input.description.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                          mDataByteSize: input.size)
                descriptions?.pointee = input.description
                packetCount.pointee = 1
                return noErr
            }, Unmanaged.passUnretained(context).toOpaque(), &packets, &list, nil)
        }
        guard status == noErr || status == ConverterInput.noMoreData, packets > 0 else {
            pcm.deallocate()
            return nil
        }
        let filled = Int(list.mBuffers.mDataByteSize)
        if let dualMono, dualMono != .both, channels == 2 {
            let frames = pcm.bindMemory(to: Float32.self, capacity: ADTSHeader.samplesPerFrame * 2)
            let source = dualMono == .main ? 0 : 1
            for frame in 0..<Int(packets) {
                let value = frames[frame * 2 + source]
                frames[frame * 2] = value
                frames[frame * 2 + 1] = value
            }
        }
        var block: CMBlockBuffer?
        // pcm の解放は CMBlockBuffer に任せる
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: pcm, blockLength: byteCount,
                                           blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                           offsetToData: 0, dataLength: filled, flags: 0, blockBufferOut: &block)
        guard let block else {
            pcm.deallocate()
            return nil
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: formatDescription,
            sampleCount: Int(packets), presentationTimeStamp: CMTime(value: pts, timescale: 90_000),
            packetDescriptions: nil, sampleBufferOut: &sample)
        return sample
    }
}

/// AudioConverter の入力コールバックへ渡す 1 フレーム分のデータ
private final class ConverterInput {
    /// 「もう入力が無い」を表す独自の値（変換器はこれを受けて、ここまでの出力を返す）
    static let noMoreData: OSStatus = 0x6D6F7265  // 'more'

    let data: UnsafeRawPointer
    let size: UInt32
    var consumed = false
    /// 変換器に渡すパケットの記述。変換器が読み終えるまで同じ場所にある必要があるので、自分で確保する
    let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)

    init(data: UnsafeRawPointer, size: UInt32) {
        self.data = data
        self.size = size
    }

    deinit {
        description.deallocate()
    }
}


/// AAC の生データブロック（raw_data_block）を少しだけ読む。
enum AACRawDataBlock {
    static let idSingleChannel = 0b000
    static let idFill = 0b110

    /// 最初の要素（FIL は飛ばす）が単一チャンネル要素か。channel_configuration 2 でこれなら二重音声
    static func startsWithSingleChannelElement(_ raw: UnsafeRawBufferPointer) -> Bool {
        var position = 0
        func read(_ count: Int) -> Int? {
            guard position + count <= raw.count * 8 else { return nil }
            var value = 0
            for _ in 0..<count {
                value = value << 1 | Int(raw[position / 8] >> (7 - position % 8) & 1)
                position += 1
            }
            return value
        }
        while let id = read(3) {
            guard id == idFill else { return id == idSingleChannel }
            guard var count = read(4) else { return false }
            if count == 15 {
                guard let escape = read(8) else { return false }
                count += escape - 1
            }
            position += count * 8
        }
        return false
    }
}

/// 二重音声を AudioToolbox に復号させるための設定（`AACDecoder` の説明を参照）。
enum DualMonoConfiguration {
    /// channel_configuration 0 と、前方に SCE を 2 つ（タグ 0 と 1）置く PCE の AudioSpecificConfig（ISO/IEC 14496-3）
    static func audioSpecificConfig(objectType: Int, sampleRateIndex: Int) -> [UInt8] {
        var bits: [Int] = []
        func put(_ value: Int, _ count: Int) {
            for shift in stride(from: count - 1, through: 0, by: -1) { bits.append((value >> shift) & 1) }
        }
        put(objectType, 5); put(sampleRateIndex, 4); put(0, 4)   // channelConfiguration 0 = PCE で指定
        put(0, 1); put(0, 1); put(0, 1)                         // frameLengthFlag・dependsOnCoreCoder・extensionFlag
        // program_config_element
        put(0, 4); put(objectType - 1, 2); put(sampleRateIndex, 4)
        put(2, 4); put(0, 4); put(0, 4); put(0, 2); put(0, 3); put(0, 4)   // 前方 2・横 0・後 0・LFE 0・データ 0・CC 0
        put(0, 1); put(0, 1); put(0, 1)                                     // ミックスダウンの指定なし
        put(0, 1); put(0, 4)                                                // 前方 1: SCE タグ 0（主）
        put(0, 1); put(1, 4)                                                // 前方 2: SCE タグ 1（副）
        while bits.count % 8 != 0 { bits.append(0) }                        // byte_alignment
        put(0, 8)                                                           // comment_field_bytes
        while bits.count % 8 != 0 { bits.append(0) }
        return stride(from: 0, to: bits.count, by: 8).map { start in
            UInt8(bits[start..<start + 8].reduce(0) { $0 << 1 | $1 })
        }
    }

    /// AudioSpecificConfig を ESDS（ISO/IEC 14496-1 の ES_Descriptor）に包む。AudioConverter の magic cookie はこの形で渡す
    static func esds(_ audioSpecificConfig: [UInt8]) -> [UInt8] {
        func descriptor(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag, 0x80, 0x80, 0x80, UInt8(body.count)] + body }
        let decoderSpecific = descriptor(0x05, audioSpecificConfig)
        // objectTypeIndication 0x40（MPEG-4 Audio）・streamType 0x15（音声）・バッファとビットレートは 0
        let decoderConfig = descriptor(0x04, [0x40, 0x15] + [UInt8](repeating: 0, count: 11) + decoderSpecific)
        let syncLayer = descriptor(0x06, [0x02])
        return descriptor(0x03, [0, 0, 0] + decoderConfig + syncLayer)
    }
}

/// ADTS の組み立ての決まり。
enum AACFraming {
    /// 持ち越しの上限（バイト）。ADTS の 1 フレームは最大 8191 バイトなので、それを超えて溜まるのは壊れた入力
    static let carryLimit = 8192
}
