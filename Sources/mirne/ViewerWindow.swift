import AppKit
import Observation
import os
import SwiftUI

/// 視聴ウィンドウの大きさの決まり
enum ViewerWindowLayout {
    /// 映像の部分の縦横比（放送の 16:9。描画の letterbox と同じ値）
    static let videoAspectRatio = PlayerWindowLayout.aspectRatio
    /// 「標準の大きさ」の映像の部分（大きさの初期化で戻す大きさ）
    static let standardVideoSize = CGSize(width: 960, height: 540)
    /// 映像の部分の最小の幅（これより小さくはリサイズさせない）
    static let minimumVideoWidth: CGFloat = 320
    /// サイドバー（チャンネル一覧）の幅の範囲と既定（ViewerView の列の幅）
    static let sidebarMinimumWidth: CGFloat = 180
    static let sidebarIdealWidth: CGFloat = 220
    static let sidebarMaximumWidth: CGFloat = 320
}

/// 視聴ウィンドウを動かす時刻の決まり
enum ViewerWindowTiming {
    /// 画面の構成が変わった・スリープから戻ったとき、最後の通知からこの時間たってから 1 回だけ置き直す。
    /// 通知の間隔は最大 1.1 秒ほど空く（参照実装の実測）ので、0.5 秒では通知が続いている途中で動かしてしまう
    static let repositionDebounce: Duration = .milliseconds(1500)
    /// サイドバーの出し入れ・仕切りの移動で映像の部分の幅が変わったとき、落ち着くまで待つ時間
    /// （サイドバーの開閉のアニメーションより長く）
    static let layoutSettleDelay: Duration = .milliseconds(400)
    /// 起動したとき、窓が画面に出るのを待つ間隔と回数（合わせて 2 秒まで）
    static let restoreWaitInterval: Duration = .milliseconds(50)
    static let restoreWaitAttempts = 40
    /// 復元するまで窓を透明にしておくが、復元できなかったときはこの時間で見せる
    /// （復元を待つ 2 秒より長く。映像の部分の大きさが届かないと、復元が始まらないため）
    static let revealFallback: Duration = .seconds(3)
    /// 窓が別の画面へ移ってからこの時間の内に、マウスで操作していないのに大きさが変わろうとしたら、macOS の当て直しとみなして止める。
    /// 実測では、画面が替わってから 0.6〜1.1 秒後に、その画面で前に使った大きさ（無ければ既定の大きさ）が当てられた
    static let screenChangeResizeGuard: Duration = .seconds(3)
}

/// 画面外の救済の決まり（参照実装：EVA Clock Nixie の WindowPositioning）
enum ViewerWindowPositioning {
    /// 起動時・画面構成の変化の後に、どれかの画面に最低限見えていてほしい量（掴んで戻せる大きさ。体感の値）
    static let minVisibleOnRestore = CGSize(width: 160, height: 120)
    /// 窓が小さいとき、要求量を窓の大きさのこの割合で頭打ちにする（要求量が窓より大きいと、判定が常に偽になり内側へ押し続ける）
    static let keepVisibleRatio: CGFloat = 0.75

    static func minVisible(for size: CGSize) -> CGSize {
        CGSize(width: min(minVisibleOnRestore.width, size.width * keepVisibleRatio),
               height: min(minVisibleOnRestore.height, size.height * keepVisibleRatio))
    }

    /// 保存した位置の窓が、どれかの画面の `visibleFrame` に十分見えていればそのまま、足りなければ
    /// 保存先の画面（無ければプライマリ）の `visibleFrame` へ、要求量だけ見えるように引き戻した位置。
    /// 判定も救済も `visibleFrame` で数える（メニューバーと Dock に覆われた帯は掴めない）。
    /// `intersects()` の真偽や、`visibleFrame` への無条件のクランプにはしない（どちらも、画面の端に少し掛かっただけの窓を見落とすか、動かす必要の無い窓まで動かす）
    static func resolvedOrigin(savedOrigin: CGPoint, targetScreen: NSScreen?, windowSize: CGSize) -> CGPoint? {
        let rect = NSRect(origin: savedOrigin, size: windowSize)
        let minVisible = minVisible(for: windowSize)
        let visible = NSScreen.screens
            .map { $0.visibleFrame.intersection(rect) }
            .filter { !$0.isNull }
            .max { $0.width * $0.height < $1.width * $1.height }
        if let visible, visible.width >= minVisible.width, visible.height >= minVisible.height {
            return savedOrigin
        }
        guard let anchor = targetScreen ?? primaryScreen() else { return nil }
        let frame = anchor.visibleFrame
        return CGPoint(
            x: min(max(savedOrigin.x, frame.minX - (windowSize.width - minVisible.width)), frame.maxX - minVisible.width),
            y: min(max(savedOrigin.y, frame.minY - (windowSize.height - minVisible.height)), frame.maxY - minVisible.height))
    }

    /// プライマリの画面（原点が (0,0) の画面）。`NSScreen.main` はキーウィンドウのある画面なので使わない
    static func primaryScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
    }
}

/// 保存する視聴ウィンドウの位置と大きさ。
///
/// 位置は画面の UUID と、その画面の `frame` の左下からの「窓の左上」の位置。
/// 左上で持つのは、窓の高さが映像の幅とサイドバー・ツールバーから決まるので、左上を保つほうが見た目の位置が変わらないため。
/// 大きさは映像の部分の幅（高さは 16:9 から決まる。サイドバーの幅は起動のたびに測る）
struct ViewerWindowPlacement: Codable, Equatable {
    var displayUUID: String?
    var left: Double
    var top: Double
    var videoWidth: Double
}

extension NSScreen {
    /// 画面の永続的な UUID（`CGDirectDisplayID` は接続の順などで変わるので保存には使わない）
    var displayUUID: String? {
        guard let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, uuid.takeRetainedValue()) as String?
    }

    static func screen(forUUID uuid: String) -> NSScreen? {
        screens.first { $0.displayUUID == uuid }
    }
}

/// 視聴ウィンドウの「常に最前面」・16:9 を保つリサイズ・位置と大きさの保存と復元・大きさの初期化。
///
/// SwiftUI の `Window` の NSWindow を受け取って扱う。保存の決まり:
/// - 保存先の画面を書き換えるのは、人が窓を動かした・大きさを変えたときだけ（画面の構成が変わっている間・自分で動かしたとき・全画面の間は保存しない）
/// - 画面の構成の変化・スリープからの復帰では、最後の通知から 1.5 秒たってから 1 回だけ置き直す
/// - 画面外の救済は「十分見えているか」で判定する
///
/// SwiftUI が付けている自動保存（"NSWindow Frame viewer"）は止め、残っている記録も消す。初めて起動したとき（保存が無いとき）は、
/// 自動保存で開いた位置をそのまま引き継ぐ。
/// 窓は復元するまで透明にしておく（SwiftUI が自動保存や既定の位置に一度出してから、保存した位置へ動かすことになるため）
@MainActor
@Observable
final class ViewerWindowController: NSObject {
    /// 常に最前面。全画面の間は効かせない
    var isAlwaysOnTop = AppSettings.alwaysOnTop {
        didSet {
            AppSettings.alwaysOnTop = isAlwaysOnTop
            applyLevel()
        }
    }
    /// 全画面か（メニューの使える・使えないに使う）
    private(set) var isFullScreen = false

    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var delegateProxy: WindowDelegateProxy?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// 映像の部分の大きさ（SwiftUI から知らせてもらう）
    @ObservationIgnored private var videoSize: CGSize = .zero
    /// 窓のうち映像でない部分（サイドバーの幅・タイトルバーとツールバーの高さ）。窓の大きさが変わっていないときに測る
    @ObservationIgnored private var chrome: CGSize?
    /// 保つ映像の幅（人が大きさを変えた・初期化した・復元したときに決める。サイドバーを出し入れしても変えない）
    @ObservationIgnored private var keptVideoWidth: CGFloat?
    /// 人がリサイズしている間に合わせる辺（リサイズの始めに 1 度だけ決める）
    @ObservationIgnored private var resizeAxis: ResizeAxis?
    @ObservationIgnored private var resizeAnchor: ResizeAnchor?
    /// サイドバー（NSSplitViewItem）の開閉の見張り
    @ObservationIgnored private var sidebarObservation: NSKeyValueObservation?
    /// サイドバーの開閉の途中（窓の幅をサイドバーに合わせて直し続ける）
    @ObservationIgnored private var followingSidebar = false
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    /// 復元できなかったときに窓を見せる見張り
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    /// 窓を閉じたか（開き直したら知らせる）
    @ObservationIgnored private var closed = false
    /// 窓を閉じた・開き直した（視聴を止めて番組表を巡回する・視聴に戻る）
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var onReopen: (() -> Void)?
    /// 自分で窓を動かしている間（そのときの移動は保存しない）
    @ObservationIgnored private var applyingFrame = false
    /// 画面の構成が変わっている間・スリープの前後（その間の移動は macOS の都合なので保存しない）
    @ObservationIgnored private var reconfiguring = false
    @ObservationIgnored private var fullScreenTransition = false
    @ObservationIgnored private var repositionTask: Task<Void, Never>?
    /// 窓が別の画面へ移った時刻（macOS が大きさを当て直すのを見分ける）
    @ObservationIgnored private var screenChangedAt: ContinuousClock.Instant?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "window")

    // MARK: - SwiftUI からの知らせ

    /// 視聴ウィンドウが決まった
    func attach(_ window: NSWindow) {
        guard window !== self.window || closed else { return }
        if window !== self.window {
            self.window = window
            installDelegateProxy(on: window)
            observe(window)
        }
        let reopened = closed
        if reopened {
            // 開き直した窓は SwiftUI が既定の位置に置くことがあるので、保存した位置と大きさをもう一度当てる
            closed = false
            restored = false
            restoreTask = nil
            sidebarObservation = nil
        }
        if !restored { hideUntilRestored(window) }
        // 開き直した窓は映像の部分の大きさが前と同じだと知らせが来ないので、ここから復元を始める
        if reopened, videoSize.width > 0 { scheduleRestore(window) }
        applyLevel()
        if reopened { onReopen?() }
    }

    /// 映像の部分の大きさが変わった
    func videoAreaDidChange(_ size: CGSize) {
        videoSize = size
        // 映像の部分の大きさの移り変わり（リサイズ・サイドバーの開閉の途中で 16:9 から外れないかを確かめる。debug なのでふだんは残らない）
        logger.debug("映像の部分: \(size.width, privacy: .public)×\(size.height, privacy: .public)・窓 \(self.window?.frame.width ?? 0, privacy: .public)×\(self.window?.frame.height ?? 0, privacy: .public)")
        guard let window, size.width > 0, size.height > 0, !isFullScreen, !fullScreenTransition else { return }
        if !restored {
            scheduleRestore(window)
            return
        }
        guard !window.inLiveResize, !applyingFrame else { return }
        if followingSidebar {
            followSidebar(window, video: size)
            scheduleSettle()
            return
        }
        let measured = Self.chrome(of: window, video: size)
        if let chrome, abs(measured.width - chrome.width) < 1, abs(measured.height - chrome.height) < 1 { return }
        // 窓の大きさは変わらず映像の部分だけ変わった（仕切りの移動など）。落ち着いたら映像の幅を元に戻す
        scheduleSettle()
    }

    // MARK: - メニュー

    /// 大きさを初期化する：映像の部分を標準の大きさにし、窓の中心は動かさない（はみ出すなら引き戻す）
    func resetSize() {
        guard let window, !isFullScreen, let chrome else { return }
        let width = ViewerWindowLayout.standardVideoSize.width
        let size = Self.frameSize(videoWidth: width, chrome: chrome)
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        let resolved = ViewerWindowPositioning.resolvedOrigin(savedOrigin: origin, targetScreen: window.screen, windowSize: size) ?? origin
        keptVideoWidth = width
        setFrame(NSRect(origin: resolved, size: size), on: window)
        logger.info("大きさを初期化した: 映像の幅 \(width, privacy: .public)")
        save(userInitiated: true)
    }

    var canResetSize: Bool { !isFullScreen }

    /// 窓をしまっている（最小化している）か。ディスプレイのスリープを止めるかの判断に使う
    var isMiniaturized: Bool { window?.isMiniaturized ?? false }

    // MARK: - 復元と保存

    /// 窓が画面に出てから復元する。SwiftUI は最初に窓を中身の最小の大きさで並べ、その後で位置と大きさを当てるので、
    /// 最初の知らせで復元すると最小の大きさを「開いた大きさ」として引き継いでしまう（最初の確かめで 540×232 になった）
    private func scheduleRestore(_ window: NSWindow) {
        guard restoreTask == nil else { return }
        restoreTask = Task { [weak self, weak window] in
            for _ in 0..<ViewerWindowTiming.restoreWaitAttempts {
                guard let window, !window.isVisible else { break }
                try? await Task.sleep(for: ViewerWindowTiming.restoreWaitInterval)
            }
            // 画面に出た後の並べ直しを 1 回待つ
            try? await Task.sleep(for: ViewerWindowTiming.restoreWaitInterval)
            guard let self, let window, !self.restored, self.videoSize.width > 0 else { return }
            self.chrome = Self.chrome(of: window, video: self.videoSize)
            self.restore(window)
        }
    }

    private func restore(_ window: NSWindow) {
        restored = true
        observeSidebar(in: window)
        // SwiftUI の自動保存を止める（保存の時機を選べず、画面の構成が変わっている間の位置も書くため）。
        // 窓に付けたときに止めると、SwiftUI が自動保存の位置を当てる前なので、前の版からの位置を引き継げない
        // （最初の確かめで、大きさだけ引き継いで外部画面の中央に出た）
        let autosaveName = window.frameAutosaveName
        window.setFrameAutosaveName("")
        // 止めても記録は残り、窓が記録の画面へ入ったときに SwiftUI がその大きさを当て直す
        // （外部画面で起動して内蔵画面へ移すと、記録の 1739×1158 が当たり、16:9 に合わせた幅が保存された）。
        // 初めての起動の位置の引き継ぎは、ここまでに SwiftUI が当て終えている
        if !autosaveName.isEmpty {
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(autosaveName)")
        }
        guard let chrome else {
            reveal(window)
            return
        }
        let frame: NSRect
        if let placement = AppSettings.viewerWindowPlacement {
            let width = max(placement.videoWidth, ViewerWindowLayout.minimumVideoWidth)
            let size = Self.frameSize(videoWidth: width, chrome: chrome)
            let target = placement.displayUUID.flatMap(NSScreen.screen(forUUID:))
            let base = (target ?? ViewerWindowPositioning.primaryScreen())?.frame ?? .zero
            let saved = CGPoint(x: base.minX + placement.left, y: base.minY + placement.top - size.height)
            let origin = ViewerWindowPositioning.resolvedOrigin(savedOrigin: saved, targetScreen: target, windowSize: size) ?? saved
            keptVideoWidth = width
            frame = NSRect(origin: origin, size: size)
            logger.info("位置を戻した: 保存先の画面 \(target == nil ? "なし（プライマリ基準）" : "あり", privacy: .public)・映像の幅 \(width, privacy: .public)・救済 \(origin == saved ? "なし" : "あり", privacy: .public)")
        } else {
            // 保存が無い（初めて・前の版の自動保存から）：開いた窓の左上と映像の幅を引き継ぎ、16:9 に合わせる
            let width = max(videoSize.width, ViewerWindowLayout.minimumVideoWidth)
            let size = Self.frameSize(videoWidth: width, chrome: chrome)
            keptVideoWidth = width
            frame = NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height)
            logger.info("保存が無いので開いた位置を引き継いだ: 映像の幅 \(width, privacy: .public)")
        }
        setFrame(frame, on: window)
        // 次のランループで macOS に書き換えられていたら当て直す（swiftui-appkit-pitfalls #31）
        Task { [weak self, weak window] in
            guard let self, let window else { return }
            if window.frame != frame, !self.isFullScreen {
                self.logger.info("復元した位置がずれたので当て直した")
                self.setFrame(frame, on: window)
            }
            self.reveal(window)
        }
    }

    /// 復元するまで窓を透明にする。復元できなかったときに備えて、時間がたったら見せる
    private func hideUntilRestored(_ window: NSWindow) {
        window.alphaValue = 0
        revealTask?.cancel()
        revealTask = Task { [weak self, weak window] in
            try? await Task.sleep(for: ViewerWindowTiming.revealFallback)
            guard !Task.isCancelled, let self, let window, window.alphaValue == 0 else { return }
            self.logger.info("復元できないまま時間がたったので窓を見せた")
            self.reveal(window)
        }
    }

    private func reveal(_ window: NSWindow) {
        revealTask?.cancel()
        revealTask = nil
        window.alphaValue = 1
    }

    /// 位置と大きさを保存する。`userInitiated` でなければ保存先の画面に触らず、保存先と違う画面にいるときは位置も捨てる
    private func save(userInitiated: Bool) {
        guard let window, restored, !isFullScreen, !fullScreenTransition, !reconfiguring,
              let screen = window.screen, let uuid = screen.displayUUID else { return }
        let saved = AppSettings.viewerWindowPlacement
        if !userInitiated, let saved, saved.displayUUID != uuid {
            logger.info("保存しない: 保存先と違う画面にいる")
            return
        }
        let placement = ViewerWindowPlacement(
            displayUUID: userInitiated ? uuid : (saved?.displayUUID ?? uuid),
            left: window.frame.minX - screen.frame.minX, top: window.frame.maxY - screen.frame.minY,
            videoWidth: keptVideoWidth ?? videoSize.width)
        guard placement != saved else { return }
        AppSettings.viewerWindowPlacement = placement
    }

    /// 画面の構成が落ち着いたら、保存した位置へ置き直す（保存先が無ければプライマリを基準に）
    private func reposition() {
        reconfiguring = false
        guard let window, restored, !isFullScreen, let placement = AppSettings.viewerWindowPlacement else { return }
        let size = window.frame.size
        let target = placement.displayUUID.flatMap(NSScreen.screen(forUUID:))
        let base = (target ?? ViewerWindowPositioning.primaryScreen())?.frame ?? .zero
        let saved = CGPoint(x: base.minX + placement.left, y: base.minY + placement.top - size.height)
        guard let origin = ViewerWindowPositioning.resolvedOrigin(savedOrigin: saved, targetScreen: target, windowSize: size),
              origin != window.frame.origin else { return }
        logger.info("画面の構成が変わったので置き直した: 保存先の画面 \(target == nil ? "なし" : "あり", privacy: .public)")
        setFrame(NSRect(origin: origin, size: size), on: window)
    }

    // MARK: - 16:9

    /// リサイズで合わせる辺
    private enum ResizeAxis { case width, height }

    /// 人がリサイズしている間に動かさない辺（つかんだ角・辺の反対側）
    private struct ResizeAnchor {
        let frame: NSRect
        let keepsLeft: Bool
        let keepsTop: Bool
    }

    /// リサイズを始めた：マウスの位置から、つかんだ角・辺を見て、反対側の辺を覚える
    private func liveResizeWillStart() {
        resizeAxis = nil
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        resizeAnchor = ResizeAnchor(frame: window.frame, keepsLeft: mouse.x >= window.frame.midX, keepsTop: mouse.y <= window.frame.midY)
    }

    /// リサイズの途中：覚えた辺が動いていたら戻す。
    /// 返した大きさがマウスの位置と食い違うと、AppKit は差を両側へ半分ずつ振り分けて、つかんでいない辺まで動かす
    /// （縮める方へ角を引っ張ると、上端が 44 下がった）
    private func windowDidResize() {
        guard let window, window.inLiveResize, let anchor = resizeAnchor, !isFullScreen else { return }
        let frame = window.frame
        let origin = CGPoint(x: anchor.keepsLeft ? anchor.frame.minX : anchor.frame.maxX - frame.width,
                             y: anchor.keepsTop ? anchor.frame.maxY - frame.height : anchor.frame.minY)
        guard abs(origin.x - frame.minX) >= 0.5 || abs(origin.y - frame.minY) >= 0.5 else { return }
        applyingFrame = true
        window.setFrameOrigin(origin)
        applyingFrame = false
    }

    /// 人がリサイズしている間の大きさ。映像の部分を 16:9 にする。
    /// 合わせる辺はリサイズの始めに 1 度だけ決める：幅が動けば（角・左右の辺）幅に、高さだけが動けば（上下の辺）高さに。
    /// 最初は毎回「大きく動いたほうの辺」を選んでいて、角を引っ張ると幅と高さが交互に選ばれてガタガタした
    fileprivate func constrainedSize(for window: NSWindow, proposed: NSSize) -> NSSize {
        guard !isFullScreen, !fullScreenTransition, let chrome else { return proposed }
        let current = window.frame.size
        if isResizeAfterScreenChange() {
            // 画面をまたいで離した後、macOS がその画面で前に使った大きさを当て直す（リサイズの始めと終わりの知らせも付く）。
            // 人の操作ではないので、保っている映像の幅のままにする
            logger.info("画面が替わった後の大きさの当て直しを止めた: 提案 \(proposed.width, privacy: .public)×\(proposed.height, privacy: .public)")
            return Self.frameSize(videoWidth: keptVideoWidth ?? (current.width - chrome.width), chrome: chrome)
        }
        if resizeAxis == nil || !window.inLiveResize {
            if abs(proposed.width - current.width) >= 1 {
                resizeAxis = .width
            } else if abs(proposed.height - current.height) >= 1 {
                resizeAxis = .height
            } else {
                return current
            }
        }
        let width = resizeAxis == .height
            ? (proposed.height - chrome.height) * ViewerWindowLayout.videoAspectRatio
            : proposed.width - chrome.width
        return Self.frameSize(videoWidth: max(width, ViewerWindowLayout.minimumVideoWidth), chrome: chrome)
    }

    /// 別の画面へ移った直後で、マウスのボタンを押していない（人が辺や角をつかんでいない）大きさの変更か
    private func isResizeAfterScreenChange() -> Bool {
        guard let changed = screenChangedAt, NSEvent.pressedMouseButtons & 1 == 0 else { return false }
        return ContinuousClock.now - changed < ViewerWindowTiming.screenChangeResizeGuard
    }

    /// SwiftUI の NavigationSplitView の中の AppKit のサイドバーを見つけて、開閉を見張る。
    /// SwiftUI の表示状態（columnVisibility）は開閉のアニメーションが**終わってから**変わるので、それを見て窓を動かすと
    /// 開閉の後になる（記録で、隠す途中の映像の比が 2.18 まで外れた）。`isCollapsed` は開閉の始めに変わる。
    /// ツールバーのボタン・メニュー（⌃⌘S）のどちらから開閉しても同じ時点で捉えられる
    private func observeSidebar(in window: NSWindow) {
        guard sidebarObservation == nil,
              let splitView = Self.firstSplitView(in: window.contentView),
              let controller = splitView.delegate as? NSSplitViewController,
              let item = controller.splitViewItems.first else {
            logger.info("サイドバーの見張りを付けられない（NSSplitViewController が見つからない）")
            return
        }
        sidebarObservation = item.observe(\.isCollapsed, options: [.old, .new]) { [weak self] _, change in
            guard let old = change.oldValue, let new = change.newValue, old != new else { return }
            MainActor.assumeIsolated { self?.sidebarWillChange(showing: !new) }
        }
    }

    private static func firstSplitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView { return split }
        for subview in view.subviews {
            if let found = firstSplitView(in: subview) { return found }
        }
        return nil
    }

    /// サイドバーの開閉が始まった。開閉の間は、サイドバーが動くたびに窓の幅をその場で直して映像の幅を保つ（`followSidebar`）。
    /// 右上を保つので、映像は画面の上で動かない。
    /// 最初は開閉が終わってから窓を合わせていて、出すときは映像がいったん縮み、隠すときは左右に黒い帯が出た。
    /// 次に窓の幅を開閉と同時にアニメーションで変えたが、2 つのアニメーションの速さが揃わず、途中の映像の比が 1.46〜2.09 まで外れた
    private func sidebarWillChange(showing: Bool) {
        guard restored, !isFullScreen, !fullScreenTransition else { return }
        followingSidebar = true
        scheduleSettle()
    }

    /// 開閉の途中：今のサイドバーの幅（窓の幅 − 映像の幅）に、保つ映像の幅を足した幅へ窓を直す
    private func followSidebar(_ window: NSWindow, video size: CGSize) {
        guard let width = keptVideoWidth else { return }
        let sidebar = window.frame.width - size.width
        let target = (sidebar + width).rounded()
        guard abs(target - window.frame.width) >= 1 else { return }
        setFrame(NSRect(x: window.frame.maxX - target, y: window.frame.minY, width: target, height: window.frame.height), on: window)
    }

    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: ViewerWindowTiming.layoutSettleDelay)
            guard !Task.isCancelled, let self else { return }
            self.followingSidebar = false
            self.fitAfterLayoutChange()
        }
    }

    /// サイドバーの出し入れ・仕切りの移動の後、映像の幅を保って窓の幅と高さを合わせる（右上を保つので、映像は画面の上で動かない）
    private func fitAfterLayoutChange() {
        guard let window, !isFullScreen, !window.inLiveResize, videoSize.width > 0 else { return }
        let measured = Self.chrome(of: window, video: videoSize)
        chrome = measured
        let width = keptVideoWidth ?? videoSize.width
        let size = Self.frameSize(videoWidth: width, chrome: measured)
        guard abs(size.width - window.frame.width) >= 1 || abs(size.height - window.frame.height) >= 1 else { return }
        let frame = NSRect(x: window.frame.maxX - size.width, y: window.frame.maxY - size.height, width: size.width, height: size.height)
        setFrame(frame, on: window)
        save(userInitiated: true)
    }

    private static func chrome(of window: NSWindow, video: CGSize) -> CGSize {
        CGSize(width: max(window.frame.width - video.width, 0), height: max(window.frame.height - video.height, 0))
    }

    private static func frameSize(videoWidth: CGFloat, chrome: CGSize) -> NSSize {
        NSSize(width: (chrome.width + videoWidth).rounded(),
               height: (chrome.height + videoWidth / ViewerWindowLayout.videoAspectRatio).rounded())
    }

    private func setFrame(_ frame: NSRect, on window: NSWindow) {
        applyingFrame = true
        window.setFrame(frame, display: true, animate: false)
        applyingFrame = false
    }

    // MARK: - 常に最前面

    private func applyLevel() {
        window?.level = isAlwaysOnTop && !isFullScreen ? .floating : .normal
    }

    // MARK: - 通知

    private func observe(_ window: NSWindow) {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0); workspace.removeObserver($0) }
        observers = [
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowDidMove() }
            },
            center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenChangedAt = .now }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowWillClose() }
            },
            // 閉じた窓を SwiftUI は壊さずに隠しておき、開き直すと同じ窓を出す（窓に載った知らせは二度目は来ない）。
            // 閉じた後に窓がまた見えるようになったことで、開き直したと見る
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowMayHaveReopened() }
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowMayHaveReopened() }
            },
            center.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.liveResizeWillStart() }
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowDidResize() }
            },
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowDidEndLiveResize() }
            },
            center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fullScreenWillChange(entering: true) }
            },
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fullScreenDidChange(entered: true) }
            },
            center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fullScreenWillChange(entering: false) }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fullScreenDidChange(entered: false) }
            },
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanging(reason: "画面の構成の変化") }
            },
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanging(reason: "スリープ") }
            },
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanging(reason: "スリープからの復帰") }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanging(reason: "画面の復帰") }
            },
        ]
    }

    private func windowDidMove() {
        guard let window, !applyingFrame, !window.inLiveResize else { return }
        if let proxy = delegateProxy, window.delegate !== proxy { installDelegateProxy(on: window) }
        // 人が動かした（画面の構成が変わっている間・全画面の間は save が捨てる）
        save(userInitiated: true)
    }

    private func windowMayHaveReopened() {
        guard closed, let window, window.isVisible else { return }
        attach(window)
    }

    private func windowWillClose() {
        guard !closed else { return }
        closed = true
        onClose?()
    }

    private func windowDidEndLiveResize() {
        resizeAnchor = nil
        guard let window, let chrome, !isFullScreen else { return }
        keptVideoWidth = window.frame.width - chrome.width
        save(userInitiated: true)
    }

    private func fullScreenWillChange(entering: Bool) {
        fullScreenTransition = true
        if entering {
            isFullScreen = true
            applyLevel()
        }
    }

    private func fullScreenDidChange(entered: Bool) {
        fullScreenTransition = false
        if !entered {
            isFullScreen = false
            applyLevel()
        }
    }

    private func screensChanging(reason: String) {
        reconfiguring = true
        logger.info("画面の構成が変わる: \(reason, privacy: .public)。落ち着いてから置き直す")
        repositionTask?.cancel()
        repositionTask = Task { [weak self] in
            try? await Task.sleep(for: ViewerWindowTiming.repositionDebounce)
            guard !Task.isCancelled else { return }
            self?.reposition()
        }
    }

    // MARK: - 窓の delegate

    /// SwiftUI が付けた delegate を残したまま、リサイズの大きさだけを決める（`windowWillResize` は delegate にしか来ない）
    private func installDelegateProxy(on window: NSWindow) {
        let proxy = WindowDelegateProxy(original: window.delegate) { [weak self] window, proposed in
            MainActor.assumeIsolated { self?.constrainedSize(for: window, proposed: proposed) ?? proposed }
        }
        delegateProxy = proxy
        window.delegate = proxy
    }
}

/// 元の delegate へ転送しつつ、`windowWillResize(_:to:)` だけを差し込む
private final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    private weak var original: NSWindowDelegate?
    private let constrain: (NSWindow, NSSize) -> NSSize

    init(original: NSWindowDelegate?, constrain: @escaping (NSWindow, NSSize) -> NSSize) {
        self.original = original
        self.constrain = constrain
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let proposed = original?.windowWillResize?(sender, to: frameSize) ?? frameSize
        return constrain(sender, proposed)
    }
}

/// SwiftUI の画面から、それを載せている NSWindow を受け取る
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WindowReportingView, context: Context) {}
}

final class WindowReportingView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow?(window) }
    }
}
