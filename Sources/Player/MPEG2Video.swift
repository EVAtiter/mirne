import CoreMedia
import CoreVideo
import Foundation
import os
import VideoToolbox

/// MPEG-2 Video のスタートコード。
enum MPEG2StartCode {
    static let picture: UInt8 = 0x00
    static let sequenceHeader: UInt8 = 0xB3
    static let `extension`: UInt8 = 0xB5
    static let sequenceEnd: UInt8 = 0xB7
    static let groupOfPictures: UInt8 = 0xB8

    /// extension_start_code_identifier
    static let sequenceExtension: UInt8 = 1
    static let pictureCodingExtension: UInt8 = 8
}

/// シーケンスヘッダ（＋シーケンス拡張）から読んだもの。変わったら復号器を作り直す。
public struct MPEG2Sequence: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// aspect_ratio_information（2 = 4:3、3 = 16:9）
    public var aspectRatioCode: UInt8
    public var frameRateCode: UInt8
    public var progressiveSequence: Bool

    /// 表示のアスペクト比（幅 ÷ 高さ）。1440×1080 も 16:9 で表示する
    public var displayAspectRatio: Double {
        switch aspectRatioCode {
        case 2: 4.0 / 3.0
        case 3: 16.0 / 9.0
        case 4: 2.21
        default: Double(width) / Double(height)
        }
    }
}

/// ピクチャヘッダ（＋ピクチャ符号化拡張）から読んだもの。
public struct MPEG2PictureInfo: Sendable, Equatable {
    public enum CodingType: UInt8, Sendable { case intra = 1, predicted = 2, bidirectional = 3 }

    public var codingType: CodingType
    public var temporalReference: Int
    /// 3 = フレーム構造。1・2 はフィールド構造（地上波ではまず無い）
    public var pictureStructure: UInt8 = 3
    public var topFieldFirst = true
    public var repeatFirstField = false
    public var progressiveFrame = false
}

/// PES の中身を走査して、シーケンスとピクチャの情報を拾う。
///
/// 地上デジタル放送の映像の PES は 1 ピクチャずつ（ARIB の運用）なので、最初のピクチャだけを見る。
enum MPEG2Parser {
    static func scan(_ data: Data) -> (sequence: MPEG2Sequence?, picture: MPEG2PictureInfo?, pictureCount: Int) {
        var sequence: MPEG2Sequence?
        var picture: MPEG2PictureInfo?
        var pictures = 0
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var index = 0
            while index + 4 <= count {
                guard bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 else {
                    index += 1
                    continue
                }
                let code = bytes[index + 3]
                let body = index + 4
                func byte(_ offset: Int) -> UInt8 { body + offset < count ? bytes[body + offset] : 0 }
                switch code {
                case MPEG2StartCode.sequenceHeader:
                    sequence = MPEG2Sequence(
                        width: Int(byte(0)) << 4 | Int(byte(1)) >> 4,
                        height: Int(byte(1) & 0x0F) << 8 | Int(byte(2)),
                        aspectRatioCode: byte(3) >> 4,
                        frameRateCode: byte(3) & 0x0F,
                        progressiveSequence: false)
                case MPEG2StartCode.extension:
                    let identifier = byte(0) >> 4
                    if identifier == MPEG2StartCode.sequenceExtension, sequence != nil {
                        sequence!.progressiveSequence = (byte(1) >> 3) & 1 == 1
                        sequence!.width |= (Int(byte(1) & 1) << 1 | Int(byte(2) >> 7)) << 12
                        sequence!.height |= Int((byte(2) >> 5) & 3) << 12
                    } else if identifier == MPEG2StartCode.pictureCodingExtension, picture != nil, pictures == 1 {
                        picture!.pictureStructure = byte(2) & 3
                        picture!.topFieldFirst = byte(3) >> 7 == 1
                        picture!.repeatFirstField = (byte(3) >> 1) & 1 == 1
                        picture!.progressiveFrame = byte(4) >> 7 == 1
                    }
                case MPEG2StartCode.picture:
                    pictures += 1
                    if pictures == 1, let type = MPEG2PictureInfo.CodingType(rawValue: (byte(1) >> 3) & 7) {
                        picture = MPEG2PictureInfo(codingType: type, temporalReference: Int(byte(0)) << 2 | Int(byte(1)) >> 6)
                    }
                default:
                    break
                }
                index = body
            }
        }
        return (sequence, picture, pictures)
    }
}

/// 復号した 1 フレーム。
public struct DecodedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// 90 kHz・巻き戻りを解いた値
    public let pts: Int64
    public let sequence: MPEG2Sequence
    public let picture: MPEG2PictureInfo
}

/// MPEG-2 Video を VideoToolbox で復号する。
///
/// - 最初の I ピクチャ（シーケンスヘッダ付き）まで捨てる
/// - その直後の B ピクチャ（前の GOP を参照する先頭の B）は、最初の P を復号するまで捨てる
/// - 欠けた PES もそのまま復号に回す。MPEG-2 はスライスごとに立ち直れるので、ブロックノイズは出ても
///   映像は止まらない（テレビと同じ振る舞い）。次の I まで捨てる方針は、0.1% のパケット欠落で
///   897 フレーム中 77 しか表示できず、止まって見えたので採らなかった（実測）
/// - シーケンス（大きさ・アスペクト比）が変わったら、セッションを作り直す
public final class MPEG2VideoDecoder: @unchecked Sendable {
    public typealias FrameHandler = @Sendable (DecodedFrame) -> Void

    /// 欲しい画素形式: 4:2:0・2 平面・ビデオレンジ（Metal でそのまま読める）
    static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    private let onFrame: FrameHandler
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sequence: MPEG2Sequence?
    private var state = State.waitingForIntra
    private let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "video")

    /// 復号に出したフレームのメタデータ。VideoToolbox には番号だけを渡し、コールバックで引き当てる
    /// （同期的に失敗したときにコールバックが呼ばれるかどうかに依存しないため）
    private let pendingLock = NSLock()
    private var pending: [Int: PendingFrame] = [:]
    private var nextToken = 1

    /// 捨てたピクチャの数（理由ごと）
    public private(set) var skippedBeforeIntra = 0
    public private(set) var skippedLeadingB = 0
    /// 欠けたまま復号に回したピクチャ
    public private(set) var damagedPictures = 0
    public private(set) var decodeErrors = 0

    private enum State {
        case waitingForIntra
        /// I を復号した。P が来るまで B を捨てる
        case afterIntra
        case running
    }

    public init(onFrame: @escaping FrameHandler) {
        self.onFrame = onFrame
    }

    deinit {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// 1 つの PES（1 ピクチャ）を渡す。`pts` は巻き戻りを解いた値
    public func decode(_ payload: Data, pts: Int64, dts: Int64?, damaged: Bool) {
        let scanned = MPEG2Parser.scan(payload)
        if scanned.pictureCount > 1 {
            logger.debug("1 つの PES に \(scanned.pictureCount, privacy: .public) ピクチャ")
        }
        if let newSequence = scanned.sequence, newSequence != sequence {
            logger.info("シーケンスが変わった: \(newSequence.width, privacy: .public)×\(newSequence.height, privacy: .public)")
            rebuildSession(for: newSequence)
        }
        guard let picture = scanned.picture, let sequence else { return }

        if damaged {
            damagedPictures += 1
        }
        switch (state, picture.codingType) {
        case (.waitingForIntra, .intra) where scanned.sequence != nil:
            state = .afterIntra
        case (.waitingForIntra, _):
            skippedBeforeIntra += 1
            return
        case (.afterIntra, .bidirectional):
            skippedLeadingB += 1
            return
        case (.afterIntra, .predicted):
            state = .running
        default:
            break
        }
        submit(payload, pts: pts, dts: dts, sequence: sequence, picture: picture)
    }

    /// 選局し直したときなど、復号途中のものを捨てて最初の I から始め直す
    public func reset() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        state = .waitingForIntra
    }

    /// 送ったものの復号が終わるまで待つ
    public func flush() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
    }

    // MARK: - VideoToolbox

    private func rebuildSession(for newSequence: MPEG2Sequence) {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        sequence = newSequence
        state = .waitingForIntra

        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_MPEG2Video,
                                       width: Int32(newSequence.width), height: Int32(newSequence.height),
                                       extensions: nil, formatDescriptionOut: &description)
        guard let description else { return }
        formatDescription = description

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Self.pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { decoderReference, frameReference, status, _, imageBuffer, _, _ in
                guard let decoderReference else { return }
                let decoder = Unmanaged<MPEG2VideoDecoder>.fromOpaque(decoderReference).takeUnretainedValue()
                let token = Int(bitPattern: frameReference)
                guard let pending = decoder.takePending(token) else { return }
                guard status == noErr, let imageBuffer else {
                    decoder.recordError(status)
                    return
                }
                decoder.deliver(DecodedFrame(pixelBuffer: imageBuffer, pts: pending.pts,
                                             sequence: pending.sequence, picture: pending.picture))
            },
            // セッションは deinit で無効にするので、自分を強く参照しなくてよい
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: description,
                                                  decoderSpecification: nil,
                                                  imageBufferAttributes: attributes as CFDictionary,
                                                  outputCallback: &callback, decompressionSessionOut: &created)
        if status != noErr {
            logger.error("VTDecompressionSessionCreate が失敗した: \(status, privacy: .public)")
        }
        session = created
    }

    private func submit(_ payload: Data, pts: Int64, dts: Int64?, sequence: MPEG2Sequence, picture: MPEG2PictureInfo) {
        guard let session, let formatDescription else { return }
        var block: CMBlockBuffer?
        let length = payload.count
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: length,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else { return }
        payload.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: pts, timescale: 90_000),
                                        decodeTimeStamp: dts.map { CMTime(value: $0, timescale: 90_000) } ?? .invalid)
        var size = length
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: formatDescription,
                                  sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                  sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard let sample else { return }

        pendingLock.lock()
        let token = nextToken
        nextToken += 1
        pending[token] = PendingFrame(pts: pts, sequence: sequence, picture: picture)
        pendingLock.unlock()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                                                       flags: [._EnableAsynchronousDecompression],
                                                       frameRefcon: UnsafeMutableRawPointer(bitPattern: token),
                                                       infoFlagsOut: nil)
        if status != noErr, takePending(token) != nil {
            recordError(status)
        }
    }

    fileprivate func takePending(_ token: Int) -> PendingFrame? {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pending.removeValue(forKey: token)
    }

    fileprivate func deliver(_ frame: DecodedFrame) {
        onFrame(frame)
    }

    fileprivate func recordError(_ status: OSStatus) {
        decodeErrors += 1
        logger.debug("復号に失敗した: \(status, privacy: .public)")
    }
}

/// 復号に出したフレームのメタデータ
private struct PendingFrame {
    let pts: Int64
    let sequence: MPEG2Sequence
    let picture: MPEG2PictureInfo
}

/// 33 ビットの PTS・PCR の巻き戻り（約 26.5 時間ごと）を解いて、単調な値にする。
public struct TimestampUnwrapper: Sendable {
    static let period: Int64 = 1 << 33
    private var last: Int64?
    private var offset: Int64 = 0

    public init() {}

    public mutating func unwrap(_ value: Int64) -> Int64 {
        if let last {
            let candidate = value + offset
            if candidate < last - Self.period / 2 { offset += Self.period }
            if candidate > last + Self.period / 2 { offset -= Self.period }
        }
        let result = value + offset
        last = result
        return result
    }

    public mutating func reset() {
        last = nil
        offset = 0
    }
}
