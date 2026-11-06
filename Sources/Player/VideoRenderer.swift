import CoreVideo
import Foundation
import ImageIO
import Metal
import MetalKit
import os

/// デインターレースの方式。
public enum DeinterlaceMode: UInt32, Sendable, CaseIterable {
    /// 織り込み（2 フィールドをそのまま 1 枚に。動きのある所が櫛状になる）
    case weave = 0
    /// フィールドごとに上下を補って表示（59.94 枚/秒。縦の解像度は半分）
    case bob = 1
    /// 動き適応（yadif と同じ考え方）。止まっている所は 2 フィールド分の縦の解像度、動く所は bob。
    /// 前後のフレームが要る（無いときは bob になる）
    case adaptive = 2
}

/// 描画の寸法と時間。
enum VideoRenderTiming {
    /// 画面の書き換えの頻度。放送のフィールド（59.94 枚/秒）を出せる値
    static let framesPerSecond = 60
    /// 計算シェーダーのスレッドグループの大きさ
    static let threadgroupWidth = 16
    static let threadgroupHeight = 16
}

/// 描画の統計（計測用）
public struct VideoRenderStatistics: Sendable {
    /// draw が呼ばれた回数（フレームの有無によらない）
    public var calls = 0
    public var drawn = 0
    /// 表示すべきフレームがまだ無かった描画
    public var starved = 0
    /// 描画時刻と、選んだフィールドの表示開始時刻の差の最大値（ミリ秒）
    public var maximumLateness = 0.0
    /// 直前の描画で使ったフレームの大きさ
    public var lastSize = ""
    /// draw の中で currentDrawable を待った時間の最大（ミリ秒）
    public var maximumDrawableWait = 0.0
    /// draw 全体にかかった時間の最大（ミリ秒）
    public var maximumDrawTime = 0.0
    /// 動き適応で描いたフィールドと、前後のフレームが無くて bob にしたフィールド
    public var adaptiveFields = 0
    public var adaptiveFallbacks = 0
}

/// 映像が実際に画面に出た時刻と、そのフィールドの表示時刻（PTS）の差を集める（A/V のずれの計測）。
///
/// 差 = 画面に出た瞬間の時計（音声と同じ AVSampleBufferRenderSynchronizer の時刻）− フィールドの PTS。
/// 正なら映像が音声より遅れて出ている。音声は synchronizer が出力の遅延を見込んで時計どおりに鳴らす前提。
public final class AVSyncRecorder: @unchecked Sendable {
    /// 再生開始直後の不安定な分を数えない回数（約 1 秒）
    static let warmUpSamples = 60
    /// 保持する上限（それを超えたら古いものを捨てる）
    static let capacity = 20_000

    private let lock = NSLock()
    private var samples: [Double] = []
    private var seen = 0
    /// 画面に出なかった（presentedTime が 0）描画
    private(set) var notPresented = 0

    func record(milliseconds: Double?) {
        lock.lock()
        defer { lock.unlock() }
        guard let milliseconds else {
            notPresented += 1
            return
        }
        seen += 1
        guard seen > Self.warmUpSamples else { return }
        samples.append(milliseconds)
        if samples.count > Self.capacity { samples.removeFirst() }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll()
        seen = 0
        notPresented = 0
    }

    /// 5・50・95 パーセンタイルと最小・最大（ミリ秒）
    public var summary: (count: Int, p5: Double, p50: Double, p95: Double, minimum: Double, maximum: Double)? {
        lock.lock()
        let sorted = samples.sorted()
        lock.unlock()
        guard !sorted.isEmpty else { return nil }
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        return (sorted.count, percentile(0.05), percentile(0.5), percentile(0.95), sorted.first!, sorted.last!)
    }
}

/// 描いてから画面に出るまでの遅れ（90 kHz）を、画面に出た時刻から測って平均する。
final class PresentationDelayEstimator: @unchecked Sendable {
    /// 指数移動平均の重み（新しい値の割合）
    static let smoothing = 0.1
    /// これより大きい値は外れ値として捨てる（90 kHz。0.5 秒）
    static let outlierLimit: Int64 = 45_000

    private let lock = NSLock()
    private var average = Double(PlaybackTiming.initialPresentationDelay)

    var value: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return Int64(average.rounded())
    }

    func update(_ measured: Int64) {
        guard measured >= 0, measured < Self.outlierLimit else { return }
        lock.lock()
        average += (Double(measured) - average) * Self.smoothing
        lock.unlock()
    }

    func reset() {
        lock.lock()
        average = Double(PlaybackTiming.initialPresentationDelay)
        lock.unlock()
    }
}

/// 時計に合わせて、FrameQueue のフレームを Metal で描く。
///
/// 描画のたびに時計の時刻を読み、その時刻に表示すべきフレームとフィールドを選ぶ。
/// 時計（`clock`）は音声の出力と同じもの（AVSampleBufferRenderSynchronizer）なので、映像と音声が揃う。
@MainActor
public final class VideoRenderer: NSObject, MTKViewDelegate {
    public let view: MTKView
    public var deinterlace = DeinterlaceMode.adaptive
    /// 表示すべき時刻（90 kHz）を返す。nil ならまだ始まっていない
    public var clock: () -> Int64? = { nil }
    /// ホスト時刻（CACurrentMediaTime の秒）を、時計の時刻（90 kHz）に換算する。A/V のずれの計測に使う
    public var mediaTimeAtHost: @Sendable (CFTimeInterval) -> Int64? = { _ in nil }
    /// 時計を張り直した回数（`PlayerEngine.clockEpoch`）。描いた後に張り直したら、その絵のずれは数えない
    /// （新しい時計で古い絵を測ると、選局し直しのたびに十数秒のずれとして出てしまう）
    public var clockEpoch: @Sendable () -> Int = { 0 }
    public let avSync = AVSyncRecorder()
    /// 描いてから画面に出るまでの遅れ。そのぶん先の時刻のフレームを選ぶ
    private let presentationDelay = PresentationDelayEstimator()

    /// 今の見込みの遅れ（ミリ秒。表示用）
    public var presentationDelayMilliseconds: Double { Double(presentationDelay.value) / 90.0 }
    /// 今の見込みの遅れ（90 kHz）。字幕も映像と同じく、このぶん先の時刻のものを出す
    public var presentationDelayTicks: Int64 { presentationDelay.value }
    /// 最後に描いたフレームの表示アスペクト比（まだ描いていなければ nil）。字幕を映像の矩形に重ねるのに使う
    public private(set) var displayAspectRatio: Double?

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let convertPipeline: MTLComputePipelineState
    private let presentPipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private var intermediate: MTLTexture?
    private let frames: FrameQueue
    /// 今表示しているフレームと、その前に表示していたフレーム（動き適応で使う）
    private var currentFrame: DecodedFrame?
    private var previousFrame: DecodedFrame?
    public private(set) var statistics = VideoRenderStatistics()
    /// 次に描いたフレームを PNG で書き出す先（検証用）
    private var snapshotRequest: URL?
    private let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "video")

    public init?(frames: FrameQueue) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: MetalShaderSource.video, options: nil),
              let convert = library.makeFunction(name: "convertFrame"),
              let vertex = library.makeFunction(name: "presentVertex"),
              let fragment = library.makeFunction(name: "presentFragment") else { return nil }
        self.device = device
        self.queue = queue
        self.frames = frames
        do {
            convertPipeline = try device.makeComputePipelineState(function: convert)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            presentPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        view = MTKView(frame: .zero, device: device)
        super.init()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = VideoRenderTiming.framesPerSecond
        view.framebufferOnly = true
        view.delegate = self
    }

    public func resetStatistics() {
        statistics = VideoRenderStatistics()
        avSync.reset()
        presentationDelay.reset()
    }

    /// 次に描くフレーム（デインターレース後・元の画素数）を PNG に書き出す（検証用）
    public func requestSnapshot(to url: URL) {
        snapshotRequest = url
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        let drawStarted = ContinuousClock.now
        statistics.calls += 1
        defer { statistics.maximumDrawTime = max(statistics.maximumDrawTime, (ContinuousClock.now - drawStarted).milliseconds) }
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let commands = queue.makeCommandBuffer() else { return }
        statistics.maximumDrawableWait = max(statistics.maximumDrawableWait, (ContinuousClock.now - drawStarted).milliseconds)
        pass.colorAttachments[0].loadAction = .clear

        var frameToShow: DecodedFrame?
        var field: UInt32 = 0
        var firstField = true
        var fieldStart: Int64?
        // 時計を読む前に、時計を張り直した回数を読む（読んだ後に張り直されたら、この絵のずれは数えない）
        let drawnEpoch = clockEpoch()
        let clockAtDraw = clock()
        if let clockAtDraw {
            // 描いた絵が画面に出るころの時刻のフレームを選ぶ
            let now = clockAtDraw + presentationDelay.value
            frameToShow = frames.frame(at: now)
            if let frame = frameToShow {
                (field, fieldStart) = selectField(frame, at: now)
                firstField = now - frame.pts < MPEG2FrameRate.frameDuration90k(code: frame.sequence.frameRateCode) / 2
                if frame.pts != currentFrame?.pts {
                    previousFrame = currentFrame
                    currentFrame = frame
                }
            } else {
                statistics.starved += 1
            }
        }

        if let frame = frameToShow, let source = convert(frame, field: field, firstField: firstField, commands: commands) {
            if let url = snapshotRequest {
                snapshotRequest = nil
                snapshot(source, to: url, commands: commands)
            }
            statistics.drawn += 1
            statistics.lastSize = "\(frame.sequence.width)×\(frame.sequence.height)"
            if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
                displayAspectRatio = frame.sequence.displayAspectRatio
                var scale = letterboxScale(displayAspect: frame.sequence.displayAspectRatio, drawable: view.drawableSize)
                encoder.setRenderPipelineState(presentPipeline)
                encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
                encoder.setFragmentTexture(source, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                encoder.endEncoding()
            }
        } else if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            encoder.endEncoding()
        }
        if let fieldStart, let clockAtDraw {
            // 画面に実際に出た時刻を音声と同じ時計に換算し、ずれと、描いてから出るまでの遅れを記録する
            let recorder = avSync
            let delay = presentationDelay
            let convert = mediaTimeAtHost
            let epoch = clockEpoch
            drawable.addPresentedHandler { presented in
                let host = presented.presentedTime
                guard epoch() == drawnEpoch else { return }
                guard host > 0, let media = convert(host) else {
                    recorder.record(milliseconds: nil)
                    return
                }
                delay.update(media - clockAtDraw)
                recorder.record(milliseconds: Double(media - fieldStart) / 90.0)
            }
        }
        commands.present(drawable)
        commands.commit()
    }

    /// bob のとき、時刻 now に表示するフィールド（トップファーストなら前半がトップ）と、その表示開始時刻
    private func selectField(_ frame: DecodedFrame, at now: Int64) -> (UInt32, Int64) {
        let frameDuration = MPEG2FrameRate.frameDuration90k(code: frame.sequence.frameRateCode)
        let elapsed = now - frame.pts
        let second = elapsed >= frameDuration / 2
        let fieldStart = frame.pts + (second ? frameDuration / 2 : 0)
        statistics.maximumLateness = max(statistics.maximumLateness, Double(now - fieldStart) / 90.0)
        let top: UInt32 = frame.picture.topFieldFirst ? 0 : 1
        return (second ? 1 - top : top, fieldStart)
    }

    /// 1 段目: YUV → RGB とデインターレースを、元の画素数の中間テクスチャへ
    private func convert(_ frame: DecodedFrame, field: UInt32, firstField: Bool, commands: MTLCommandBuffer) -> MTLTexture? {
        guard let cache = textureCache,
              let (lumaReference, luma) = texture(from: frame.pixelBuffer, plane: 0, format: .r8Unorm, cache: cache),
              let (chromaReference, chroma) = texture(from: frame.pixelBuffer, plane: 1, format: .rg8Unorm, cache: cache) else { return nil }
        var references = [lumaReference, chromaReference]

        // 動き適応は前後のフレームが要る。大きさが違う（シーケンスが変わった）か、まだ無ければ bob にする
        var mode = deinterlace
        var previousLuma = luma
        var nextLuma = luma
        if mode == .adaptive {
            let sameSize = { (other: DecodedFrame) in other.sequence.width == frame.sequence.width && other.sequence.height == frame.sequence.height }
            if let previous = previousFrame, sameSize(previous), let next = frames.frame(after: frame.pts), sameSize(next),
               let (previousReference, previousTexture) = texture(from: previous.pixelBuffer, plane: 0, format: .r8Unorm, cache: cache),
               let (nextReference, nextTexture) = texture(from: next.pixelBuffer, plane: 0, format: .r8Unorm, cache: cache) {
                previousLuma = previousTexture
                nextLuma = nextTexture
                references += [previousReference, nextReference]
                statistics.adaptiveFields += 1
            } else {
                mode = .bob
                statistics.adaptiveFallbacks += 1
            }
        }
        // CVMetalTexture は GPU が読み終えるまで手放さない（先に解放すると、画素バッファが再利用されうる）
        nonisolated(unsafe) let held = references
        commands.addCompletedHandler { _ in _ = held }
        let width = luma.width
        let height = luma.height
        if intermediate?.width != width || intermediate?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            intermediate = device.makeTexture(descriptor: descriptor)
        }
        guard let intermediate, let encoder = commands.makeComputeCommandEncoder() else { return nil }
        let progressive = frame.picture.progressiveFrame || frame.sequence.progressiveSequence
        var parameters = SIMD4<UInt32>(mode.rawValue, field, progressive ? 1 : 0, firstField ? 1 : 0)
        encoder.setComputePipelineState(convertPipeline)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setTexture(intermediate, index: 2)
        encoder.setTexture(previousLuma, index: 3)
        encoder.setTexture(nextLuma, index: 4)
        encoder.setBytes(&parameters, length: MemoryLayout<SIMD4<UInt32>>.size, index: 0)
        let group = MTLSize(width: VideoRenderTiming.threadgroupWidth, height: VideoRenderTiming.threadgroupHeight, depth: 1)
        let grid = MTLSize(width: (width + group.width - 1) / group.width, height: (height + group.height - 1) / group.height, depth: 1)
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
        encoder.endEncoding()
        return intermediate
    }

    private func snapshot(_ texture: MTLTexture, to url: URL, commands: MTLCommandBuffer) {
        let bytesPerRow = texture.width * 4
        guard let buffer = device.makeBuffer(length: bytesPerRow * texture.height, options: .storageModeShared),
              let blit = commands.makeBlitCommandEncoder() else { return }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: 0)
        blit.endEncoding()
        let (width, height) = (texture.width, texture.height)
        nonisolated(unsafe) let held = buffer
        commands.addCompletedHandler { _ in
            let data = Data(bytes: held.contents(), count: bytesPerRow * height)
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                      space: CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    private func texture(from buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat,
                         cache: CVMetalTextureCache) -> (CVMetalTexture, MTLTexture)? {
        var reference: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format,
                                                  CVPixelBufferGetWidthOfPlane(buffer, plane),
                                                  CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &reference)
        guard let reference, let texture = CVMetalTextureGetTexture(reference) else { return nil }
        return (reference, texture)
    }

    /// 表示のアスペクト比を保って画面に収める倍率（1 未満の側に黒帯が入る）
    private func letterboxScale(displayAspect: Double, drawable: CGSize) -> SIMD2<Float> {
        guard drawable.width > 0, drawable.height > 0 else { return SIMD2(1, 1) }
        let viewAspect = drawable.width / drawable.height
        if viewAspect > displayAspect {
            return SIMD2(Float(displayAspect / viewAspect), 1)
        }
        return SIMD2(1, Float(viewAspect / displayAspect))
    }
}

extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}

/// MPEG-2 の frame_rate_code
enum MPEG2FrameRate {
    /// 1 フレームの長さ（90 kHz）
    static func frameDuration90k(code: UInt8) -> Int64 {
        switch code {
        case 1: 3754   // 23.976
        case 2: 3750   // 24
        case 3: 3600   // 25
        case 4: 3003   // 29.97（地上デジタル放送）
        case 5: 3000   // 30
        case 6: 1800   // 50
        case 7: 1502   // 59.94
        case 8: 1500   // 60
        default: 3003
        }
    }
}
