import AppKit
import os

/// 保存する番組表のウィンドウの位置と大きさ。
///
/// 位置は画面の UUID と、その画面の `frame` の左下からの「窓の左上」の位置（視聴ウィンドウと同じ基準）。
/// 大きさは窓の幅と高さ
struct GuideWindowPlacement: Codable, Equatable {
    var displayUUID: String?
    var left: Double
    var top: Double
    var width: Double
    var height: Double
}

/// 番組表のウィンドウの大きさの決まり
enum GuideWindowLayout {
    /// これより小さい大きさは戻さない（保存が壊れていても、使える大きさで開く）
    static let minimumSize = CGSize(width: 480, height: 320)
}

/// 番組表のウィンドウ（別ウィンドウで開いたとき）の位置と大きさの保存と復元。
///
/// 決まりは視聴ウィンドウ（`ViewerWindowController`）と同じ:
/// - 保存するのは人が窓を動かした・大きさを変えたときだけ（画面の構成が変わっている間・自分で動かしたとき・全画面の間は保存しない）
/// - 画面の構成の変化・スリープからの復帰では、最後の通知から少し待って 1 回だけ置き直す
/// - 画面外の救済は「十分見えているか」で判定する（`ViewerWindowPositioning`）
///
/// SwiftUI の自動保存（"NSWindow Frame guide"）は、窓を開き直したときに当たらないことがあった（視聴ウィンドウのある画面に、
/// 画面の幅に合わせた大きさで出た）ので止める。保存が無いときは、自動保存で開いた位置と大きさを引き継ぐ。
/// 窓は復元するまで透明にしておく
@MainActor
final class GuideWindowController: NSObject {
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var restored = false
    private var restoreTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private var repositionTask: Task<Void, Never>?
    /// 窓を閉じたか（開き直したら復元し直す）
    private var closed = false
    /// 自分で窓を動かしている間（そのときの移動は保存しない）
    private var applyingFrame = false
    /// 画面の構成が変わっている間・スリープの前後
    private var reconfiguring = false
    private var isFullScreen = false
    private let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "guide-window")
    /// 窓を開いて、位置と大きさを戻し終えて見せた（初めて開いたときも、開き直したときも。番組表を「今」の位置へ送る）
    var onShow: (() -> Void)?
    /// 開いた窓をまだ見せていない（見せたら `onShow` を 1 回呼ぶ）
    private var pendingShow = false
    /// 保存した位置と大きさの写し（窓を動かしている間、移動の知らせのたびに設定から JSON を読み直さない）
    private var placementCache: GuideWindowPlacement??

    /// 保存した位置と大きさ（設定を読むのは最初の 1 回だけ。書くときは写しと設定の両方へ）
    private var storedPlacement: GuideWindowPlacement? {
        get {
            if let placementCache { return placementCache }
            let loaded = AppSettings.guideWindowPlacement
            placementCache = .some(loaded)
            return loaded
        }
        set {
            placementCache = .some(newValue)
            AppSettings.guideWindowPlacement = newValue
        }
    }

    /// 番組表のウィンドウが決まった（開き直したときも呼ばれる）
    func attach(_ window: NSWindow) {
        guard window !== self.window || closed else { return }
        if window !== self.window {
            self.window = window
            observe(window)
        }
        pendingShow = true
        closed = false
        restored = false
        restoreTask?.cancel()
        restoreTask = nil
        hideUntilRestored(window)
        scheduleRestore(window)
    }

    // MARK: - 復元と保存

    /// 窓が画面に出て、SwiftUI が位置と大きさを当て終えてから復元する（視聴ウィンドウと同じ時機）
    private func scheduleRestore(_ window: NSWindow) {
        restoreTask = Task { [weak self, weak window] in
            for _ in 0..<ViewerWindowTiming.restoreWaitAttempts {
                guard let window, !window.isVisible else { break }
                try? await Task.sleep(for: ViewerWindowTiming.restoreWaitInterval)
            }
            try? await Task.sleep(for: ViewerWindowTiming.restoreWaitInterval)
            guard !Task.isCancelled, let self, let window, !self.restored else { return }
            self.restore(window)
        }
    }

    private func restore(_ window: NSWindow) {
        restored = true
        let autosaveName = window.frameAutosaveName
        let autosaveKey = "NSWindow Frame \(autosaveName)"
        let autosavedFrame = autosaveName.isEmpty ? nil : UserDefaults.standard.string(forKey: autosaveKey)
        window.setFrameAutosaveName("")
        if !autosaveName.isEmpty {
            UserDefaults.standard.removeObject(forKey: autosaveKey)
        }
        guard let placement = storedPlacement else {
            // 保存が無い（初めて・前の版の自動保存から）：自動保存の記録があれば自分で当てて引き継ぐ。
            // SwiftUI は開き直した窓に記録を当てないことがある（視聴ウィンドウのある画面の幅で開いた）ので、開いた位置は使わない
            // `setFrame(from:)` は記録を今の画面に合わせて置き直した（外部画面の記録が、視聴ウィンドウのある画面の幅で当たった）ので、
            // 位置と大きさを取り出して自分で当てる
            guard let autosaved = autosavedFrame.flatMap(Self.frame(fromAutosave:)) else {
                logger.info("保存が無いので開いた位置を引き継いだ")
                reveal(window)
                save(userInitiated: true)
                return
            }
            let screen = NSScreen.screens.first { $0.frame.intersects(autosaved) }
            let origin = ViewerWindowPositioning.resolvedOrigin(savedOrigin: autosaved.origin, targetScreen: screen, windowSize: autosaved.size) ?? autosaved.origin
            logger.info("前の版の自動保存の位置と大きさを引き継いだ")
            apply(NSRect(origin: origin, size: autosaved.size), to: window) { [weak self] in self?.save(userInitiated: true) }
            return
        }
        let size = CGSize(width: max(placement.width, GuideWindowLayout.minimumSize.width),
                          height: max(placement.height, GuideWindowLayout.minimumSize.height))
        let target = placement.displayUUID.flatMap(NSScreen.screen(forUUID:))
        let base = (target ?? ViewerWindowPositioning.primaryScreen())?.frame ?? .zero
        let saved = CGPoint(x: base.minX + placement.left, y: base.minY + placement.top - size.height)
        let origin = ViewerWindowPositioning.resolvedOrigin(savedOrigin: saved, targetScreen: target, windowSize: size) ?? saved
        logger.info("位置を戻した: 保存先の画面 \(target == nil ? "なし（プライマリ基準）" : "あり", privacy: .public)・救済 \(origin == saved ? "なし" : "あり", privacy: .public)")
        apply(NSRect(origin: origin, size: size), to: window)
    }

    /// 位置と大きさを当て、次のランループで macOS に書き換えられていたら当て直してから見せる（SwiftUI の窓は、当てた直後に macOS が位置を書き換えることがある）
    private func apply(_ frame: NSRect, to window: NSWindow, then completion: (() -> Void)? = nil) {
        setFrame(frame, on: window)
        Task { [weak self, weak window] in
            guard let self, let window else { return }
            if window.frame != frame, !self.isFullScreen {
                self.logger.info("復元した位置がずれたので当て直した")
                self.setFrame(frame, on: window)
            }
            self.reveal(window)
            completion?()
        }
    }

    /// 自動保存の記録（「x y 幅 高さ 画面の x y 幅 高さ」）から、窓の位置と大きさ（画面の座標）
    static func frame(fromAutosave string: String) -> NSRect? {
        let numbers = string.split(separator: " ").compactMap { Double($0) }
        guard numbers.count >= 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
        return NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

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
        // 「今」へ送るのは、窓が画面に出て中身を並べ終えてから。番組表の最初の読み込みのときに送ると、
        // 窓がまだ出ておらず中身も並んでいないことがあり、送りが空振りして 1 日の始まりのまま出た（起動して初めて開いたとき）
        if pendingShow {
            pendingShow = false
            onShow?()
        }
    }

    /// 位置と大きさを保存する。`userInitiated` でなければ保存先の画面に触らず、保存先と違う画面にいるときは位置も捨てる
    private func save(userInitiated: Bool) {
        guard let window, restored, !closed, !isFullScreen, !reconfiguring,
              let screen = window.screen, let uuid = screen.displayUUID else { return }
        let saved = storedPlacement
        if !userInitiated, let saved, saved.displayUUID != uuid { return }
        let placement = GuideWindowPlacement(
            displayUUID: userInitiated ? uuid : (saved?.displayUUID ?? uuid),
            left: window.frame.minX - screen.frame.minX, top: window.frame.maxY - screen.frame.minY,
            width: window.frame.width, height: window.frame.height)
        guard placement != saved else { return }
        storedPlacement = placement
    }

    /// 画面の構成が落ち着いたら、保存した位置へ置き直す
    private func reposition() {
        reconfiguring = false
        guard let window, restored, !closed, !isFullScreen, let placement = storedPlacement else { return }
        let size = window.frame.size
        let target = placement.displayUUID.flatMap(NSScreen.screen(forUUID:))
        let base = (target ?? ViewerWindowPositioning.primaryScreen())?.frame ?? .zero
        let saved = CGPoint(x: base.minX + placement.left, y: base.minY + placement.top - size.height)
        guard let origin = ViewerWindowPositioning.resolvedOrigin(savedOrigin: saved, targetScreen: target, windowSize: size),
              origin != window.frame.origin else { return }
        logger.info("画面の構成が変わったので置き直した")
        setFrame(NSRect(origin: origin, size: size), on: window)
    }

    private func setFrame(_ frame: NSRect, on window: NSWindow) {
        applyingFrame = true
        window.setFrame(frame, display: true, animate: false)
        applyingFrame = false
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
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.save(userInitiated: true) }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.closed = true }
            },
            // 閉じた窓を SwiftUI は壊さずに隠しておき、開き直すと同じ窓を出すことがある（そのときは中身からの知らせが来ない）。
            // 閉じた後に窓がまた見えるようになったことで、開き直したと見る
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowMayHaveReopened() }
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowMayHaveReopened() }
            },
            center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isFullScreen = true }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isFullScreen = false }
            },
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanging() }
            },
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanging() }
            },
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanging() }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanging() }
            },
        ]
    }

    private func windowMayHaveReopened() {
        guard closed, let window, window.isVisible else { return }
        attach(window)
    }

    private func windowDidMove() {
        guard let window, !applyingFrame, !window.inLiveResize else { return }
        // 人が動かした（画面の構成が変わっている間・全画面の間は save が捨てる）
        save(userInitiated: true)
    }

    /// 画面の構成が変わり始めた・スリープの前後。最後の通知から待って 1 回だけ置き直す
    private func screensChanging() {
        reconfiguring = true
        repositionTask?.cancel()
        repositionTask = Task { [weak self] in
            try? await Task.sleep(for: ViewerWindowTiming.repositionDebounce)
            guard !Task.isCancelled else { return }
            self?.reposition()
        }
    }
}
