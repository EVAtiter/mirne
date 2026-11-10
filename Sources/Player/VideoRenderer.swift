import AppKit
import CoreVideo
import Foundation
import ImageIO
import Metal
import os
import QuartzCore

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
    /// 表示のタイミングを作り直してから、描けているかを記録するまで
    static let restartCheckDelay: Duration = .seconds(1)
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
    /// 描画の中で描き込む先（drawable）を待った時間の最大（ミリ秒）。CAMetalDisplayLink が渡すので、ほぼ 0 になる
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
///
/// 描くのは描画専用のスレッド（`VideoRenderCore`）。このクラスはメインスレッドから設定と統計を受け渡す窓口。
@MainActor
public final class VideoRenderer {
    public let view: VideoLayerView
    private let core: VideoRenderCore

    public var deinterlace: DeinterlaceMode {
        get { core.deinterlace }
        set { core.deinterlace = newValue }
    }
    /// 表示すべき時刻（90 kHz）を返す。nil ならまだ始まっていない。描画のスレッドから呼ぶ
    public var clock: @Sendable () -> Int64? {
        get { core.clock }
        set { core.clock = newValue }
    }
    /// ホスト時刻（CACurrentMediaTime の秒）を、時計の時刻（90 kHz）に換算する。A/V のずれの計測に使う
    public var mediaTimeAtHost: @Sendable (CFTimeInterval) -> Int64? {
        get { core.mediaTimeAtHost }
        set { core.mediaTimeAtHost = newValue }
    }
    /// 時計を張り直した回数（`PlayerEngine.clockEpoch`）。描いた後に張り直したら、その絵のずれは数えない
    /// （新しい時計で古い絵を測ると、選局し直しのたびに十数秒のずれとして出てしまう）
    public var clockEpoch: @Sendable () -> Int {
        get { core.clockEpoch }
        set { core.clockEpoch = newValue }
    }
    public var avSync: AVSyncRecorder { core.avSync }

    /// 今の見込みの遅れ（ミリ秒。表示用）
    public var presentationDelayMilliseconds: Double { Double(core.presentationDelay.value) / 90.0 }
    /// 今の見込みの遅れ（90 kHz）。字幕も映像と同じく、このぶん先の時刻のものを出す
    public var presentationDelayTicks: Int64 { core.presentationDelay.value }
    /// 最後に描いたフレームの表示アスペクト比（まだ描いていなければ nil）。字幕を映像の矩形に重ねるのに使う
    public var displayAspectRatio: Double? { core.displayAspectRatio }
    public var statistics: VideoRenderStatistics { core.statistics }
    /// 描き込む先の大きさ（画素。表示用）
    public var drawableSize: CGSize { view.metalLayer.drawableSize }

    /// 映像を出す窓が画面に見えているか（閉じた・しまった・ほかの窓に隠れた・別の操作スペースにあるときは false）。
    /// 見えていない間は描かない
    public var isOnScreen = true {
        didSet {
            guard isOnScreen != oldValue else { return }
            core.setOnScreen(isOnScreen)
        }
    }

    public init?(frames: FrameQueue) {
        guard let core = VideoRenderCore(frames: frames) else { return nil }
        self.core = core
        view = VideoLayerView(device: core.device)
        core.attach(view.metalLayer)
        // 窓に置いた・別の画面へ移ったら、表示のタイミングをその画面に合わせて作り直す
        view.onDisplayChange = { [weak core] reason in core?.restart(reason: reason) }
    }

    /// 表示のタイミングを作り直す（視聴ウィンドウを開き直したとき・スリープから復帰したとき）。
    /// 描いている間なら今すぐ、止めている間なら次に描き始めるときに作り、その後 1 秒で何回描けたかを記録する
    public func restartDrawing(reason: String) {
        core.restart(reason: reason)
    }

    public func resetStatistics() {
        core.resetStatistics()
    }

    /// 次に描くフレーム（デインターレース後・元の画素数）を PNG に書き出す（検証用）
    public func requestSnapshot(to url: URL) {
        core.requestSnapshot(to: url)
    }
}

/// 映像を出すビュー。CAMetalLayer を持ち、描き込む先の大きさを画面の画素に合わせるだけで、自分では描かない
/// （描くのは `VideoRenderCore` が描画のスレッドで）
public final class VideoLayerView: NSView {
    let metalLayer = CAMetalLayer()
    /// 窓に置いた・別の画面へ移ったとき（理由の文言を渡す）
    var onDisplayChange: ((String) -> Void)?
    private var screenObserver: (any NSObjectProtocol)?

    init(device: MTLDevice) {
        super.init(frame: .zero)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    override public func makeBackingLayer() -> CALayer { metalLayer }
    override public var isOpaque: Bool { true }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        updateDrawableSize()
        guard let window else { return }
        screenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateDrawableSize()
                self?.onDisplayChange?("窓が別の画面へ移った")
            }
        }
        onDisplayChange?("窓に置いた")
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 1
        if metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size.width > 0, size.height > 0, metalLayer.drawableSize != size else { return }
        metalLayer.drawableSize = size
    }
}

/// 描画のスレッドで描く本体。
///
/// 表示のタイミングは CAMetalDisplayLink を描画のスレッドの run loop に置いて受け取る。描き込む先（drawable）は
/// CAMetalDisplayLink が用意して渡すので、描き込む先が空くのを待ってスレッドが止まることがない
/// （メインスレッドの MTKView で描いていたときは、待ちが 33〜66 ms 出て、そのあいだ番組表などの操作も止まった）。
///
/// 表示のタイミングは、描いている間だけ持つ。止めるとき（見えていない・表示するものが無い）は捨て、描き始めるときに作る。
/// 作るたびに今の画面に合ったものになるので、閉じている間・止めている間にスリープして画面の構成が変わっても、
/// 止まったままのタイミングを使い続けることがない。
///
/// スレッドの分担：
/// - 描画のスレッドだけが触るもの: `link`・`pendingCheck`・`currentFrame`・`previousFrame`・`intermediate`・`textureCache`
/// - どのスレッドからも触るもの: `shared`（ロックで守る）
final class VideoRenderCore: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    /// メインスレッドと描画のスレッドで受け渡す値
    private struct Shared {
        var deinterlace = DeinterlaceMode.adaptive
        var clock: @Sendable () -> Int64? = { nil }
        var mediaTimeAtHost: @Sendable (CFTimeInterval) -> Int64? = { _ in nil }
        var clockEpoch: @Sendable () -> Int = { 0 }
        var statistics = VideoRenderStatistics()
        var displayAspectRatio: Double?
        var snapshotRequest: URL?
        /// 映像を出す窓が見えているか
        var isOnScreen = true
        /// 表示するものが無いので描くのを止めているか（次のフレームが入ったら描き始める）
        var isIdle = false
        /// 表示のタイミングを捨てた回数（描けているかの記録の間に止めたかを見る）
        var linkStops = 0
        /// 描くべきか
        var shouldDraw: Bool { isOnScreen && !isIdle }
    }

    let device: MTLDevice
    let avSync = AVSyncRecorder()
    /// 描いてから画面に出るまでの遅れ。そのぶん先の時刻のフレームを選ぶ
    let presentationDelay = PresentationDelayEstimator()

    private let queue: MTLCommandQueue
    private let convertPipeline: MTLComputePipelineState
    private let presentPipeline: MTLRenderPipelineState
    private let frames: FrameQueue
    private let thread = RenderThread(name: "mirne.video")
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "video")

    // 描画のスレッドだけが触る
    private var layer: CAMetalLayer?
    private var link: CAMetalDisplayLink?
    /// 表示のタイミングを作り直した理由。次に作ったときに、描けているかを記録する
    private var pendingCheck: String?
    private var textureCache: CVMetalTextureCache?
    private var intermediate: MTLTexture?
    /// 今表示しているフレームと、その前に表示していたフレーム（動き適応で使う）
    private var currentFrame: DecodedFrame?
    private var previousFrame: DecodedFrame?

    init?(frames: FrameQueue) {
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
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    deinit {
        thread.stop()
    }

    // MARK: - メインスレッドから

    var deinterlace: DeinterlaceMode {
        get { shared.withLock { $0.deinterlace } }
        set { shared.withLock { $0.deinterlace = newValue } }
    }
    var clock: @Sendable () -> Int64? {
        get { shared.withLock { $0.clock } }
        set { shared.withLock { $0.clock = newValue } }
    }
    var mediaTimeAtHost: @Sendable (CFTimeInterval) -> Int64? {
        get { shared.withLock { $0.mediaTimeAtHost } }
        set { shared.withLock { $0.mediaTimeAtHost = newValue } }
    }
    var clockEpoch: @Sendable () -> Int {
        get { shared.withLock { $0.clockEpoch } }
        set { shared.withLock { $0.clockEpoch = newValue } }
    }
    var statistics: VideoRenderStatistics { shared.withLock { $0.statistics } }
    var displayAspectRatio: Double? { shared.withLock { $0.displayAspectRatio } }

    func attach(_ layer: CAMetalLayer) {
        nonisolated(unsafe) let layer = layer
        thread.perform { [self] in
            self.layer = layer
            reconcile()
        }
    }

    func setOnScreen(_ visible: Bool) {
        shared.withLock { $0.isOnScreen = visible }
        thread.perform { [self] in reconcile() }
    }

    func restart(reason: String) {
        thread.perform { [self] in
            pendingCheck = reason
            if link != nil {
                stopLink()
                reconcile()
            } else {
                logger.info("表示のタイミングは止めているので、描き始めるときに作り直す（\(reason, privacy: .public)）")
            }
        }
    }

    func resetStatistics() {
        shared.withLock { $0.statistics = VideoRenderStatistics() }
        avSync.reset()
        presentationDelay.reset()
    }

    func requestSnapshot(to url: URL) {
        shared.withLock { $0.snapshotRequest = url }
    }

    // MARK: - 描くのを止める・始める（描画のスレッドで）

    /// 描くべきかに合わせて、表示のタイミングを作る・捨てる
    private func reconcile() {
        let state = shared.withLock { $0 }
        if state.shouldDraw, link == nil, let layer {
            startLink(layer)
            logger.debug("描画を始めた（見えている \(state.isOnScreen, privacy: .public)・表示するもの無し \(state.isIdle, privacy: .public)）")
        } else if !state.shouldDraw, link != nil {
            stopLink()
            logger.debug("描画を止めた（見えている \(state.isOnScreen, privacy: .public)・表示するもの無し \(state.isIdle, privacy: .public)）")
        }
    }

    private func startLink(_ layer: CAMetalLayer) {
        let link = CAMetalDisplayLink(metalLayer: layer)
        let rate = Float(VideoRenderTiming.framesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.delegate = self
        link.add(to: .current, forMode: .default)
        self.link = link
        if let reason = pendingCheck {
            pendingCheck = nil
            checkDrawing(after: reason)
        }
    }

    private func stopLink() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        shared.withLock { $0.linkStops += 1 }
    }

    /// 表示のタイミングを作り直した後に、1 秒で何回描けたかを記録する。
    /// その 1 秒の間に止めたら（選局し直しの間は表示するものが無い）数が意味を持たないので、次に描き始めたときに測り直す
    private func checkDrawing(after reason: String) {
        let (before, stops) = shared.withLock { ($0.statistics.calls, $0.linkStops) }
        DispatchQueue.global().asyncAfter(deadline: .now() + VideoRenderTiming.restartCheckDelay.milliseconds / 1000) { [weak self] in
            guard let self else { return }
            let (calls, stopsNow) = shared.withLock { ($0.statistics.calls - before, $0.linkStops) }
            guard stopsNow == stops else {
                thread.perform { [self] in
                    if link == nil {
                        pendingCheck = pendingCheck ?? reason
                    } else {
                        checkDrawing(after: reason)
                    }
                }
                return
            }
            logger.info("表示のタイミングを作り直した（\(reason, privacy: .public)）: 1 秒で \(calls, privacy: .public) 回描いた")
        }
    }

    /// 時計が止まっていて（再生していない）フレームも無ければ、今の黒い画面を出したところで描くのを止める。
    /// 受信を止めている間（番組表を重ねている・選局の切り替えの間）に、黒い画面を 1 秒に 60 回描き続けないように
    private func enterIdleIfNothingToShow() {
        // 先に止める印を付けてから、次のフレームで起こしてもらう。逆の順にすると、印を付ける前にフレームが入ったとき、
        // 起こす側が「止めていない」と見て何もせず、その後で印を付けて止めたままになる
        let marked = shared.withLock { state -> Bool in
            guard !state.isIdle else { return false }
            state.isIdle = true
            return true
        }
        guard marked else { return }
        let waiting = frames.wakeOnNextPushIfEmpty { [weak self] in self?.leaveIdle() }
        if !waiting {
            shared.withLock { $0.isIdle = false }
            return
        }
        // 表示のタイミングのコールバックの中で、そのタイミングを捨てないよう、後で行う
        thread.perform { [self] in reconcile() }
    }

    /// 次のフレームが入った（フレームを足したスレッドから呼ばれる）
    private func leaveIdle() {
        let changed = shared.withLock { state -> Bool in
            guard state.isIdle else { return false }
            state.isIdle = false
            return true
        }
        guard changed else { return }
        thread.perform { [self] in reconcile() }
    }

    // MARK: - 描く（描画のスレッドで）

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        draw(update.drawable)
    }

    private func draw(_ drawable: CAMetalDrawable) {
        let drawStarted = ContinuousClock.now
        let settings = shared.withLock { state in
            state.statistics.calls += 1
            let snapshot = state.snapshotRequest
            state.snapshotRequest = nil
            return (state.deinterlace, state.clock, state.mediaTimeAtHost, state.clockEpoch, snapshot)
        }
        let (mode, clock, mediaTimeAtHost, clockEpoch, snapshotRequest) = settings
        var statistics = DrawStatistics()
        defer {
            statistics.drawTime = (ContinuousClock.now - drawStarted).milliseconds
            let finished = statistics
            shared.withLock { state in
                finished.apply(to: &state.statistics)
                if let aspect = finished.displayAspectRatio { state.displayAspectRatio = aspect }
            }
        }
        guard let commands = queue.makeCommandBuffer() else { return }
        statistics.drawableWait = (ContinuousClock.now - drawStarted).milliseconds
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

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
                (field, fieldStart) = selectField(frame, at: now, statistics: &statistics)
                firstField = now - frame.pts < MPEG2FrameRate.frameDuration90k(code: frame.sequence.frameRateCode) / 2
                if frame.pts != currentFrame?.pts {
                    previousFrame = currentFrame
                    currentFrame = frame
                }
            } else {
                statistics.starved = true
            }
        }

        if let frame = frameToShow,
           let source = convert(frame, mode: mode, field: field, firstField: firstField, commands: commands, statistics: &statistics) {
            if let snapshotRequest {
                snapshot(source, to: snapshotRequest, commands: commands)
            }
            statistics.drawnSize = "\(frame.sequence.width)×\(frame.sequence.height)"
            if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
                statistics.displayAspectRatio = frame.sequence.displayAspectRatio
                let target = CGSize(width: drawable.texture.width, height: drawable.texture.height)
                var scale = letterboxScale(displayAspect: frame.sequence.displayAspectRatio, drawable: target)
                encoder.setRenderPipelineState(presentPipeline)
                encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
                encoder.setFragmentTexture(source, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                encoder.endEncoding()
            }
        } else {
            if let snapshotRequest {
                // まだ描けるフレームが無いので、次の描画に回す
                shared.withLock { $0.snapshotRequest = $0.snapshotRequest ?? snapshotRequest }
            }
            if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
                encoder.endEncoding()
            }
        }
        if let fieldStart, let clockAtDraw {
            // 画面に実際に出た時刻を音声と同じ時計に換算し、ずれと、描いてから出るまでの遅れを記録する
            let recorder = avSync
            let delay = presentationDelay
            drawable.addPresentedHandler { presented in
                let host = presented.presentedTime
                guard clockEpoch() == drawnEpoch else { return }
                guard host > 0, let media = mediaTimeAtHost(host) else {
                    recorder.record(milliseconds: nil)
                    return
                }
                delay.update(media - clockAtDraw)
                recorder.record(milliseconds: Double(media - fieldStart) / 90.0)
            }
        }
        commands.present(drawable)
        commands.commit()
        if clockAtDraw == nil { enterIdleIfNothingToShow() }
    }

    /// 1 回の描画で増えた統計。描き終えてから 1 度のロックでまとめて足す
    private struct DrawStatistics {
        var drawnSize: String?
        var starved = false
        var lateness: Double?
        var drawableWait = 0.0
        var drawTime = 0.0
        var adaptive = false
        var adaptiveFallback = false
        var displayAspectRatio: Double?

        func apply(to statistics: inout VideoRenderStatistics) {
            if let drawnSize {
                statistics.drawn += 1
                statistics.lastSize = drawnSize
            }
            if starved { statistics.starved += 1 }
            if let lateness { statistics.maximumLateness = max(statistics.maximumLateness, lateness) }
            statistics.maximumDrawableWait = max(statistics.maximumDrawableWait, drawableWait)
            statistics.maximumDrawTime = max(statistics.maximumDrawTime, drawTime)
            if adaptive { statistics.adaptiveFields += 1 }
            if adaptiveFallback { statistics.adaptiveFallbacks += 1 }
        }
    }

    /// bob のとき、時刻 now に表示するフィールド（トップファーストなら前半がトップ）と、その表示開始時刻
    private func selectField(_ frame: DecodedFrame, at now: Int64, statistics: inout DrawStatistics) -> (UInt32, Int64) {
        let frameDuration = MPEG2FrameRate.frameDuration90k(code: frame.sequence.frameRateCode)
        let elapsed = now - frame.pts
        let second = elapsed >= frameDuration / 2
        let fieldStart = frame.pts + (second ? frameDuration / 2 : 0)
        statistics.lateness = Double(now - fieldStart) / 90.0
        let top: UInt32 = frame.picture.topFieldFirst ? 0 : 1
        return (second ? 1 - top : top, fieldStart)
    }

    /// 1 段目: YUV → RGB とデインターレースを、元の画素数の中間テクスチャへ
    private func convert(_ frame: DecodedFrame, mode requested: DeinterlaceMode, field: UInt32, firstField: Bool,
                         commands: MTLCommandBuffer, statistics: inout DrawStatistics) -> MTLTexture? {
        guard let cache = textureCache,
              let (lumaReference, luma) = texture(from: frame.pixelBuffer, plane: 0, format: .r8Unorm, cache: cache),
              let (chromaReference, chroma) = texture(from: frame.pixelBuffer, plane: 1, format: .rg8Unorm, cache: cache) else { return nil }
        var references = [lumaReference, chromaReference]

        // 動き適応は前後のフレームが要る。大きさが違う（シーケンスが変わった）か、まだ無ければ bob にする
        var mode = requested
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
                statistics.adaptive = true
            } else {
                mode = .bob
                statistics.adaptiveFallback = true
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

/// 描画専用のスレッド。run loop を回し続け、`perform` で渡した処理を渡した順に行う
/// （表示のタイミングのコールバックも、この run loop で受け取る）
final class RenderThread: @unchecked Sendable {
    private let runLoop: CFRunLoop
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    init(name: String) {
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var started: CFRunLoop?
        let stopped = self.stopped
        let thread = Thread {
            started = CFRunLoopGetCurrent()
            // 処理が何も無い間も run loop が戻らないよう、ポートを 1 つ置いておく
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            while !stopped.withLock({ $0 }) {
                _ = RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        runLoop = started!
    }

    /// 描画のスレッドで行う（渡した順に）
    func perform(_ work: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    func stop() {
        stopped.withLock { $0 = true }
        // CFRunLoopStop はほかのスレッドから呼んでよい
        CFRunLoopStop(runLoop)
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
