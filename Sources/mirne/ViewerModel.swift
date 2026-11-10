import AppKit
import Foundation
import Observation
import os

/// 視聴画面の操作の決まり。
enum ViewerTiming {
    /// マウスを動かしてからオーバーレイを消すまで
    static let overlayVisible: Duration = .seconds(3)
}

/// スリープからの復帰の決まり。
enum WakeTiming {
    /// 復帰してから選局し直すまで待つ時間。USB の機器が数え直されるのを待つ
    static let retuneDelay: Duration = .seconds(2)
}

/// 音量の操作の決まり。
enum VolumeStep {
    /// 1 回の「音量を上げる・下げる」で変える量
    static let increment: Float = 0.1
}

/// チューナーがつながっているか（初回起動の案内）。
enum TunerAvailability: Equatable {
    case checking
    case connected
    /// coaxd は動いたが CECH-ZD1 J が無い
    case missing
    /// coaxd を起動できない
    case unavailable(String)
}

/// 案内のボタンでできること。
enum GuideAction: Equatable {
    case recheckTuner
    case scan
    case openSettings
}

/// 映像の上に出し続ける案内（選局中・失敗・初回の準備など）。
struct Guide: Equatable {
    let title: String
    var detail: String?
    var action: GuideAction?
}

/// 視聴画面の状態と操作（選局・再生・チャンネル一覧・スキャン・初回の案内）。
@MainActor
@Observable
final class ViewerModel {
    let reception: Reception
    let playback: LivePlayback
    /// 受信状態。`showsSignal` の間だけ coaxd に尋ねる
    let signal: SignalMonitor
    let renderer: VideoRenderer?
    /// 字幕の重ね描き
    let captions: CaptionOverlayModel
    /// 視聴ウィンドウの最前面・大きさ・位置
    let windowController = ViewerWindowController()
    /// 番組表のウィンドウ（別ウィンドウで開いたとき）の位置と大きさ
    @ObservationIgnored let guideWindowController = GuideWindowController()
    /// 番組表の別ウィンドウを開いて見せた回数（番組表がこれを見て「今」の位置へ送る）
    var guideWindowShowCount = 0

    /// チャンネル一覧（まだスキャンしていなければ nil）
    private(set) var channels: ChannelList? {
        didSet { rebuildLineup() }
    }
    /// 選んでいるサービス
    private(set) var current: ChannelList.Entry?
    /// 読み込み・スキャンの失敗
    private(set) var problem: String?
    /// スキャン中の進み具合（スキャン中でなければ nil）
    private(set) var scanProgress: ScanProgress?
    private(set) var isScanning = false
    /// オーバーレイを出しているか
    private(set) var isOverlayVisible = true
    /// チューナーがつながっているか
    private(set) var tunerAvailability = TunerAvailability.checking
    /// 番組表を視聴ウィンドウに重ねて出しているか。出している間は視聴を止めて番組表を巡回する
    var isGuideSheetPresented = false {
        didSet {
            guard isGuideSheetPresented != oldValue else { return }
            if isGuideSheetPresented { guideSheetOpened() } else { guideSheetClosed() }
        }
    }
    /// 巡回が番組表を保存した回数（開いている番組表が読み直す合図）
    private(set) var patrolRevision = 0
    /// 受信状態のパネルを出しているか。既定は出さない
    var showsSignal = false
    /// 外部フィルタの設定。変えたら保存し、次の選局から使う
    var filterSettings: FilterSettings {
        didSet { AppSettings.filter = filterSettings }
    }
    /// 字幕の既定。起動したときに字幕を出すか。変えても、いま出しているかは変えない
    var captionsByDefault: Bool {
        didSet { AppSettings.captionsByDefault = captionsByDefault }
    }
    /// チャンネル一覧の編集。変えたら保存し、見ている局の名前も当て直す
    var channelEdits: ChannelEdits {
        didSet {
            AppSettings.channelEdits = channelEdits
            rebuildLineup()
            if let current, let edited = channels?.allServices(with: channelEdits).first(where: { $0.id == current.id }) {
                self.current = edited
            }
        }
    }
    /// 起動したときに前回の局を選局するか
    var autoTuneLastChannel: Bool {
        didSet { AppSettings.autoTuneLastChannel = autoTuneLastChannel }
    }
    /// 番組表でジャンルをどう示すか
    var guideGenreStyle: GuideGenreStyle = AppSettings.guideGenreStyle {
        didSet { AppSettings.guideGenreStyle = guideGenreStyle }
    }
    /// 番組表のジャンルの色
    var guideGenreColors: GuideGenreColors = AppSettings.guideGenreColors {
        didSet { AppSettings.guideGenreColors = guideGenreColors }
    }
    /// デインターレースの方式
    var deinterlace: DeinterlaceMode {
        didSet {
            renderer?.deinterlace = deinterlace
            AppSettings.deinterlace = deinterlace
        }
    }

    @ObservationIgnored private let tunerService: any TunerService
    @ObservationIgnored private let store: ChannelStore?
    /// 番組表。開けなければ保存しない（視聴は続ける）
    @ObservationIgnored let epgStore: EPGStore?
    @ObservationIgnored private var scanner: ChannelScanner?
    @ObservationIgnored private var overlayTimer: Task<Void, Never>?
    /// スリープの前に見ていたサービス。復帰したら選局し直す
    @ObservationIgnored private var resumeAfterWake: ChannelList.Entry?
    @ObservationIgnored private var powerObservers: [NSObjectProtocol] = []
    /// 起動したときの前回の局の選局を、もう試したか（「もう一度確かめる」で選局し直さないように）
    @ObservationIgnored private var triedAutoTune = false
    /// 視聴中にディスプレイを眠らせない
    @ObservationIgnored private let displaySleep = DisplaySleepBlocker()
    @ObservationIgnored private var displaySleepTask: Task<Void, Never>?
    /// チューナーの抜き差しの見張り
    @ObservationIgnored private let hotplug = TunerHotplugMonitor()
    /// 番組表の巡回。番組表を保存できないときは回らない
    @ObservationIgnored private var patrol: GuidePatrol?
    @ObservationIgnored private var patrolStart: Task<Void, Never>?
    /// 視聴ウィンドウを閉じる前に見ていたサービス。開き直したら選局し直す
    @ObservationIgnored private var resumeAfterReopen: ChannelList.Entry?
    /// 番組表を重ねて出す前に見ていたサービス。番組を選ばずに閉じたら選局し直す
    @ObservationIgnored private var resumeAfterGuideSheet: ChannelList.Entry?
    /// 番組表を重ねて出したので巡回しているか
    @ObservationIgnored private var patrolsForGuideSheet = false

    private static let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "tuner")

    init() {
        let engine = PlayerEngine()
        playback = LivePlayback(engine: engine)
        let renderer = VideoRenderer(frames: engine.frames)
        renderer?.clock = { engine.presentationTime() }
        renderer?.mediaTimeAtHost = { engine.mediaTime(atHost: $0) }
        renderer?.clockEpoch = { engine.clockEpoch }
        self.renderer = renderer
        let showsCaptions = AppSettings.captionsByDefault
        captionsByDefault = showsCaptions
        captions = CaptionOverlayModel(engine: engine, renderer: renderer, isEnabled: showsCaptions)

        let service: any TunerService = AppSettings.coaxdExecutable().map { CoaxTunerService(launcher: CoaxdLauncher(executable: $0)) }
            ?? MissingDaemon()
        tunerService = service
        let filter = AppSettings.filter
        let mode = AppSettings.deinterlace
        autoTuneLastChannel = AppSettings.autoTuneLastChannel
        channelEdits = AppSettings.channelEdits
        filterSettings = filter
        deinterlace = mode
        renderer?.deinterlace = mode
        reception = Reception(tuner: TunerSession(service: service), filterSettings: filter)
        signal = SignalMonitor(reception: reception)

        store = try? ChannelStore(fileURL: ChannelStore.defaultFileURL())
        do {
            epgStore = try EPGStore(fileURL: EPGStore.defaultFileURL())
        } catch {
            epgStore = nil
            Self.logger.error("番組表を開けない: \(error.localizedDescription, privacy: .public)")
        }
        playback.broadcast.onSchedule = { [epgStore] sections, receivedAt in
            epgStore?.save(sections, receivedAt: receivedAt)
        }
        if let volume = AppSettings.volume { playback.volume = volume }
        reception.onOutput = { [weak self] output in
            guard let self else { return }
            playback.play(output, serviceID: current.map { UInt16($0.service.serviceID) })
        }
        loadChannels()
        // 初期化の中で値を入れたときは didSet が呼ばれないことがあるので、ここで必ず作る
        rebuildLineup()
        showOverlay()
        checkTuner()
        observeSleep()
        watchDisplaySleep()
        watchHotplug()
        if let epgStore {
            let patrol = GuidePatrol(service: service, store: epgStore)
            patrol.onSave = { [weak self] in self?.patrolRevision += 1 }
            self.patrol = patrol
        }
        watchViewerWindow()
    }

    // MARK: - 番組表の巡回

    /// 視聴ウィンドウを閉じたら受信を止め、少し待ってから番組表を巡回する。開き直したら巡回をやめて、前に見ていた局に戻る
    private func watchViewerWindow() {
        windowController.onClose = { [weak self] in self?.viewerWindowClosed() }
        windowController.onReopen = { [weak self] in self?.viewerWindowReopened() }
        windowController.onVisibilityChange = { [weak renderer = self.renderer] visible in renderer?.isOnScreen = visible }
        guideWindowController.onShow = { [weak self] in self?.guideWindowShowCount += 1 }
    }

    private func viewerWindowClosed() {
        // 番組表を重ねて出したまま閉じたら、その前に見ていた局に戻る（巡回は窓を閉じた分として続ける）
        resumeAfterReopen = patrolsForGuideSheet ? resumeAfterGuideSheet : current
        patrolsForGuideSheet = false
        resumeAfterGuideSheet = nil
        Self.logger.notice("視聴ウィンドウを閉じたので受信を止める")
        reception.stop()
        Task { await playback.stop() }
        patrolStart?.cancel()
        patrolStart = Task { [weak self] in
            try? await Task.sleep(for: GuidePatrolTiming.startDelay)
            guard !Task.isCancelled, let self, !self.isScanning else { return }
            self.patrol?.start { [weak self] in self?.lineup.map(\.channel) ?? [] }
        }
    }

    private func viewerWindowReopened() {
        patrolStart?.cancel()
        patrolStart = nil
        // 閉じている間にスリープすると描画が止まったままになることがあるので、開き直したら張り直す
        renderer?.restartDrawing(reason: "視聴ウィンドウを開いた")
        let entry = resumeAfterReopen
        resumeAfterReopen = nil
        Task {
            await patrol?.stop()
            if let entry, reception.tuner.state == .idle {
                Self.logger.notice("視聴ウィンドウを開いたので選局し直す（\(entry.service.name, privacy: .public)）")
                select(entry)
            }
        }
    }

    /// 番組表を重ねて出したら、視聴を止めて巡回する。チューナーは 1 つなので、
    /// ほかの局を集める間は見ている局の映像と音が止まる。集まった分はその場で番組表に出る（`patrolRevision`）
    private func guideSheetOpened() {
        guard let patrol, !isScanning, !patrol.isRunning else { return }
        resumeAfterGuideSheet = current
        patrolsForGuideSheet = true
        Self.logger.notice("番組表を重ねて出したので受信を止めて巡回する")
        reception.stop()
        Task { await playback.stop() }
        patrolStart?.cancel()
        patrolStart = Task { [weak self] in
            // 視聴のストリームを coaxd が解放し終えるのを待つ（すぐ選局すると「使用中」になる）
            try? await Task.sleep(for: GuidePatrolTiming.guideSheetStartDelay)
            guard !Task.isCancelled, let self, self.patrolsForGuideSheet, !self.isScanning else { return }
            self.patrol?.start { [weak self] in self?.lineup.map(\.channel) ?? [] }
        }
    }

    /// 番組表を閉じたら巡回をやめ、番組を選ばずに閉じたなら前に見ていた局に戻る（選んだなら、その局の選局が始まっている）
    private func guideSheetClosed() {
        guard patrolsForGuideSheet else { return }
        patrolsForGuideSheet = false
        patrolStart?.cancel()
        patrolStart = nil
        let entry = resumeAfterGuideSheet
        resumeAfterGuideSheet = nil
        Task {
            await patrol?.stop()
            if let entry, reception.tuner.state == .idle {
                Self.logger.notice("番組表を閉じたので選局し直す（\(entry.service.name, privacy: .public)）")
                select(entry)
            }
        }
    }

    // MARK: - チューナーの抜き差し

    /// 挿されたら、少し待ってからチューナーを確かめ直す。見ていた局が失敗していれば選局し直し（`checkTuner`）、
    /// 起動してまだ選局していなければ前回の局を選局する。抜かれたら「つながっていない」にする
    /// （受信中なら受信が途切れ、選局し直しで「チューナーが接続されていません」になる）
    private func watchHotplug() {
        hotplug.onAttach = { [weak self] in
            Task { [weak self] in
                try? await Task.sleep(for: HotplugTiming.attachSettleDelay)
                self?.checkTuner()
            }
        }
        hotplug.onDetach = { [weak self] in
            self?.tunerAvailability = .missing
        }
        hotplug.start()
    }

    // MARK: - ディスプレイのスリープ

    /// 受信して映像を出している間（窓をしまっているときを除く）、ディスプレイを眠らせない。
    /// mirne には一時停止が無いので、「一時停止中」は選局していない・失敗した・スキャン中（受信していない）として扱う
    private func watchDisplaySleep() {
        displaySleepTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let receiving = if case .receiving = self.reception.tuner.state { true } else { false }
                let playing = receiving && self.playback.engine.presentationTime() != nil
                self.displaySleep.update(blocking: playing && !self.windowController.isMiniaturized)
                try? await Task.sleep(for: DisplaySleepTiming.checkInterval)
            }
        }
    }

    // MARK: - 起動したときの選局

    /// 前回の局（覚えていて、いまの一覧にあれば）
    private var lastEntry: ChannelList.Entry? {
        guard let id = AppSettings.lastChannel else { return nil }
        return channels?.allServices(with: channelEdits).first { $0.id == id }
    }

    /// 起動してチューナーが見つかったら、前回の局を選局する。起動から映像までを測ってログに残す（目標 5 秒）
    private func tuneLastChannelIfNeeded() {
        guard !triedAutoTune, autoTuneLastChannel, current == nil, !isScanning, let entry = lastEntry else { return }
        triedAutoTune = true
        Self.logger.notice("起動したので前回の局を選局する（\(entry.service.name, privacy: .public)）")
        let tunedAt = ContinuousClock.now
        select(entry)
        measureStartup(tunedAt: tunedAt)
    }

    private func measureStartup(tunedAt: ContinuousClock.Instant) {
        guard let renderer else { return }
        let drawnBefore = renderer.statistics.drawn
        let launched = ProcessLaunch.startDate()
        Task {
            while ContinuousClock.now - tunedAt < StartupTiming.measureLimit {
                if renderer.statistics.drawn > drawnBefore {
                    let fromTune = (ContinuousClock.now - tunedAt).milliseconds
                    let fromLaunch = launched.map { Date().timeIntervalSince($0) * 1000 }
                    Self.logger.notice("起動から映像まで \(fromLaunch.map { String(format: "%.0f ms", $0) } ?? "-", privacy: .public)（プロセスの起動から）・選局から \(String(format: "%.0f ms", fromTune), privacy: .public)")
                    return
                }
                try? await Task.sleep(for: StartupTiming.measureInterval)
            }
            Self.logger.notice("起動から映像まで：選局から \(StartupTiming.measureLimit.formatted(.units(allowed: [.seconds])), privacy: .public)たっても映像が出ない")
        }
    }

    // MARK: - スリープ

    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        powerObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.willSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didWake() }
            },
        ]
    }

    /// スリープの前にストリームを閉じる（チューナーと外部フィルタを手放す）。
    /// 視聴ウィンドウを閉じている間・番組表を重ねて巡回している間は、もう視聴していないので、復帰したときに選局し直す局を覚えない。
    /// 覚えると、復帰したときに閉じた窓のまま選局し直して隠れたまま再生し、チューナーがふさがって、窓を開き直したときの選局
    /// （チューナーが空いているときだけ）が走らず、映像が戻らなかった
    private func willSleep() {
        let viewing = !windowController.isClosed && !patrolsForGuideSheet
        resumeAfterWake = viewing ? current : nil
        Self.logger.notice("スリープの前に受信を止める（\(viewing ? (self.current?.service.name ?? "-") : "視聴していない", privacy: .public)）")
        reception.stop()
    }

    /// 復帰したら、少し待ってから同じサービスを選局し直す
    private func didWake() {
        guard let entry = resumeAfterWake else { return }
        resumeAfterWake = nil
        renderer?.restartDrawing(reason: "スリープから復帰した")
        Self.logger.notice("スリープから復帰した。\(WakeTiming.retuneDelay.formatted(.units(allowed: [.seconds])), privacy: .public)後に選局し直す")
        Task {
            try? await Task.sleep(for: WakeTiming.retuneDelay)
            // 待っている間に利用者が別の局を選んでいたら、そちらを生かす
            guard current?.id == entry.id, reception.tuner.state == .idle else { return }
            select(entry)
        }
    }

    // MARK: - チューナー

    /// coaxd を起動し、CECH-ZD1 J がつながっているかを確かめる。
    /// 起動のときに coaxd を先に立ち上げておくと、最初の選局が速くなる（coaxd の起動に 1.5 秒かかる）。
    /// 選局に失敗していて、チューナーが見つかったら、同じサービスを選局し直す（抜き差しの後）
    func checkTuner() {
        tunerAvailability = .checking
        let service = tunerService
        Task {
            do {
                try await service.prepare()
                tunerAvailability = try await service.findTuner() == nil ? .missing : .connected
            } catch {
                tunerAvailability = .unavailable(TunerFailure(error).advice)
            }
            if tunerAvailability == .connected, let current, case .failed = reception.tuner.state {
                select(current)
            }
            if tunerAvailability == .connected { tuneLastChannelIfNeeded() }
        }
    }

    // MARK: - 一覧

    /// 一覧に出すサービス（リモコンキーの順・主のサービスだけ）。
    /// 並べ替えに手間がかかり、画面の描き直しのたびに何度も読まれるので、チャンネル一覧か編集が変わったときだけ作り直す
    private(set) var lineup: [ChannelList.Entry] = []

    private func rebuildLineup() {
        let rebuilt = channels?.lineup(with: channelEdits) ?? []
        if rebuilt != lineup { lineup = rebuilt }
    }

    /// 設定の表に出す局（隠した局も含む・編集を当てた順）
    var editableStations: [ChannelList.Entry] { channels?.stations(with: channelEdits) ?? [] }

    /// 局の元の名前（スキャンで得た主のサービスの名前。名前の上書きの手がかりに出す）
    func originalName(of channel: PhysicalChannel) -> String {
        channels?.lineup.first { $0.channel.frequency == channel.frequency }?.service.name ?? ""
    }

    /// いまの物理チャンネルのサービス（サブチャンネル）
    var subServices: [ChannelList.Entry] {
        guard let current, let channels else { return [] }
        return channels.subServices(of: current.channel, with: channelEdits)
    }

    private func loadChannels() {
        do {
            channels = try store?.load()
        } catch {
            problem = "チャンネル一覧を読めません: \(error.localizedDescription)"
        }
    }

    // MARK: - 選局

    /// サービスを選ぶ。同じ物理チャンネルの中なら選局し直さずに切り替える
    func select(_ entry: ChannelList.Entry) {
        guard !isScanning else { return }
        let sameChannel = current?.channel.frequency == entry.channel.frequency
        current = entry
        AppSettings.lastChannel = entry.id
        problem = nil
        showOverlay()
        if sameChannel, case .receiving = reception.tuner.state {
            playback.selectService(UInt16(entry.service.serviceID))
        } else {
            reception.filterSettings = filterSettings
            reception.tune(entry.channel.tuningTarget)
        }
    }

    /// リモコンキーで選ぶ。同じキーを続けて押したら次の枝番へは進まない（主のサービスを選ぶ）
    func select(remoteControlKey key: Int) {
        guard let entry = lineup.first(where: { $0.remoteControlKey == key }) else { return }
        select(entry)
    }

    /// 一覧の前後の局へ
    func step(_ offset: Int) {
        let entries = lineup
        guard !entries.isEmpty else { return }
        let index = current.flatMap { now in entries.firstIndex { $0.channel.frequency == now.channel.frequency } }
        let next = index.map { ($0 + offset + entries.count) % entries.count } ?? 0
        select(entries[next])
    }

    /// 受信をやめる（終了時）
    func stop() {
        displaySleep.update(blocking: false)
        patrolStart?.cancel()
        Task { await patrol?.stop() }
        reception.stop()
        scanner?.cancel()
    }

    // MARK: - 音声

    func toggleMute() {
        playback.isMuted.toggle()
        showOverlay()
    }

    /// 二重音声の主・副・主+副を選ぶ
    func selectDualMono(_ channel: DualMonoChannel) {
        playback.dualMonoChannel = channel
        showOverlay()
    }

    /// 字幕を出す・消す（C キー）
    func toggleCaptions() {
        captions.isEnabled.toggle()
        showOverlay()
    }

    /// 音声 ES を選ぶ
    func selectAudio(_ track: AudioTrack) {
        playback.selectAudio(track)
        showOverlay()
    }

    /// 「音声を切り替える」（A キー）。音声 ES と二重音声の主・副・主+副を順に回る
    func cycleAudio() {
        guard let choice = playback.audio.nextChoice(after: playback.dualMonoChannel) else { return }
        playback.selectAudio(choice.track)
        playback.dualMonoChannel = choice.dualMono
        showOverlay()
    }

    /// 「音声を切り替える」で選べるものが 2 つ以上あるか
    var canCycleAudio: Bool {
        playback.audio.nextChoice(after: playback.dualMonoChannel) != nil
    }

    func changeVolume(by delta: Float) {
        playback.volume += delta
        AppSettings.volume = playback.volume
        showOverlay()
    }

    // MARK: - スキャン

    /// チャンネルスキャン。視聴を止めてから行う
    func startScan() {
        guard !isScanning else { return }
        guard let coax = CoaxPCSCSocket.locateCoax(),
              let directory = try? ChannelStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("scan") else {
            problem = "coax が見つかりません"
            return
        }
        reception.stop()
        current = nil
        isScanning = true
        problem = nil
        scanProgress = nil
        let scanner = ChannelScanner(coax: coax, workDirectory: directory)
        self.scanner = scanner
        let report: @Sendable (ScanProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.scanProgress = progress }
        }
        Task {
            do {
                let list = try await scanner.run(onProgress: report)
                try store?.save(list)
                channels = list
            } catch ChannelScanError.cancelled {
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            isScanning = false
            scanProgress = nil
            self.scanner = nil
        }
    }

    func cancelScan() {
        scanner?.cancel()
    }

    // MARK: - オーバーレイ

    /// オーバーレイを出し、しばらくしたら消す
    func showOverlay() {
        isOverlayVisible = true
        overlayTimer?.cancel()
        overlayTimer = Task { [weak self] in
            try? await Task.sleep(for: ViewerTiming.overlayVisible)
            guard !Task.isCancelled else { return }
            self?.isOverlayVisible = false
        }
    }

    /// いまのサービスの現在・次の番組。局を切り替えた直後は、その局の EIT[p/f] が届くまで「取得中」
    var program: ProgramDisplay.Status {
        guard let current else { return .unavailable }
        let isReceiving: Bool = switch reception.tuner.state {
        case .tuning, .receiving: true
        case .idle, .failed: false
        }
        return ProgramDisplay.status(playback.broadcast.presentFollowing[UInt16(current.service.serviceID)], isReceiving: isReceiving)
    }

    /// 放送の時刻。TOT が届くまで nil
    var broadcastClock: BroadcastClock? { playback.broadcast.clock }

    /// 番組表で使う今の時刻。放送の時刻が分かっていればそれ、無ければ Mac の時刻
    var guideNow: Date { Date().addingTimeInterval(guideClockOffset) }

    /// 番組表で使う、放送の時刻と Mac の時刻の差（秒）。放送の時刻が分かっていなければ 0。
    /// 時刻が届くたび（数秒ごと）ではなく、差が変わったときだけ変わる（番組表を描き直しすぎないように）
    var guideClockOffset: TimeInterval { TimeInterval(playback.broadcast.clockOffsetSeconds ?? 0) }

    /// 映像の上に出し続ける案内。無ければ nil。
    /// 初回の準備は、チューナー → チャンネル一覧 → 外部フィルタ の順に案内する
    var guide: Guide? {
        if isScanning { return nil }
        if let problem { return Guide(title: problem) }
        if current == nil {
            switch tunerAvailability {
            case .checking:
                return Guide(title: "チューナーを確かめています")
            case .missing:
                return Guide(title: "チューナーが接続されていません",
                             detail: "CECH-ZD1 J を USB につないでから、もう一度確かめてください。",
                             action: .recheckTuner)
            case let .unavailable(detail):
                return Guide(title: "coaxd を起動できません", detail: detail, action: .recheckTuner)
            case .connected:
                break
            }
        }
        if channels == nil {
            return Guide(title: "チャンネル一覧がありません",
                         detail: "チャンネルスキャンで、受信できるチャンネルの一覧を作ります（10 分ほどかかります）。",
                         action: .scan)
        }
        guard current != nil else {
            if filterSettings.command == nil {
                return Guide(title: "外部フィルタが設定されていません",
                             detail: "放送はスクランブルされているので、そのままでは映像も音声も出ません。mirne は復号の処理を含まないので、設定で外部フィルタを指定してください。",
                             action: .openSettings)
            }
            return Guide(title: "チャンネルを選んでください")
        }
        switch reception.tuner.state {
        case .idle:
            return nil
        case let .tuning(_, attempt):
            return Guide(title: attempt > 1 ? "選局し直しています（\(attempt) 回目）" : "選局しています")
        case let .failed(_, failure):
            return Guide(title: failure.title, detail: failure.advice,
                         action: failure == .notConnected ? .recheckTuner : nil)
        case .receiving:
            guard reception.descramble == .scrambled else { return nil }
            return Guide(title: "復号されていません",
                         detail: filterSettings.command == nil
                            ? "外部フィルタが設定されていません。設定で指定してください。"
                            : "外部フィルタを通した放送が、まだスクランブルされています。設定の外部フィルタを確かめてください。",
                         action: .openSettings)
        }
    }
}

/// coaxd が見つからないときの窓口（選局すると失敗として表示する）
private struct MissingDaemon: TunerService {
    func prepare() async throws { throw CoaxError.daemonNotFound }
    func findTuner() async throws -> CoaxTuner? { nil }
    func open(_ request: CoaxStreamRequest) async throws -> any TunerStreamHandle { throw CoaxError.daemonNotFound }
    func status(of tunerID: String) async throws -> CoaxTunerStatus { throw CoaxError.daemonNotFound }
}
