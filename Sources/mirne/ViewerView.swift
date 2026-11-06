import AppKit
import SwiftUI

/// 視聴ウィンドウ。サイドバーにチャンネル一覧、右に映像とオーバーレイ。
struct ViewerView: View {
    @Bindable var model: ViewerModel
    @State private var sidebar = NavigationSplitViewVisibility.all
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebar) {
            ChannelSidebar(model: model)
                .navigationSplitViewColumnWidth(min: ViewerWindowLayout.sidebarMinimumWidth,
                                                ideal: ViewerWindowLayout.sidebarIdealWidth,
                                                max: ViewerWindowLayout.sidebarMaximumWidth)
        } detail: {
            VideoArea(model: model)
                .toolbar {
                    // タイトルの右端から番組表を重ねて出す（「チャンネル」メニューの「番組表を重ねて表示」と同じ）。
                    // Shift を押しながらなら別のウインドウで開く（「チャンネル」メニューの「番組表」と同じ）
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            if NSEvent.modifierFlags.contains(.shift) {
                                openWindow(id: WindowID.guide)
                            } else {
                                model.isGuideSheetPresented = true
                            }
                        } label: {
                            Label("番組表", systemImage: "list.bullet.rectangle")
                                .labelStyle(.titleAndIcon)
                        }
                        .help("番組表を重ねて表示（Shift を押しながらで別のウインドウに表示）")
                        .disabled(model.isScanning)
                    }
                }
        }
        .navigationTitle(model.current.map { $0.service.name } ?? "mirne")
        .sheet(isPresented: .constant(model.isScanning)) {
            ScanSheet(model: model)
        }
        .sheet(isPresented: $model.isGuideSheetPresented) {
            GuideView(model: model) { model.isGuideSheetPresented = false }
                .frame(width: GuideLayout.sheetSize.width, height: GuideLayout.sheetSize.height)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.stop()
        }
        .background(WindowAccessor { model.windowController.attach($0) })
    }
}

/// チャンネル一覧。リモコンキーの順に主のサービスだけ
private struct ChannelSidebar: View {
    let model: ViewerModel

    var body: some View {
        List(selection: selection) {
            ForEach(model.lineup) { entry in
                HStack(spacing: 8) {
                    Text(entry.remoteControlKey.map(String.init) ?? "–")
                        .font(.system(.body, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .trailing)
                    Text(entry.service.name)
                        .lineLimit(1)
                }
                .tag(entry.id)
            }
        }
        .overlay {
            if model.lineup.isEmpty, !model.isScanning {
                ContentUnavailableView {
                    Label("チャンネルがありません", systemImage: "antenna.radiowaves.left.and.right")
                } actions: {
                    Button("チャンネルスキャン…") { model.startScan() }
                }
            }
        }
    }

    /// 選んでいる物理チャンネルの行。サブチャンネルを選んでいるときも、その局の行を選んだままにする。
    /// 行を選んだら選局する（同じ局の行なら何もしない。選局 → 一覧の選択 → 選局 と回らないように）
    private var selection: Binding<String?> {
        Binding {
            guard let current = model.current else { return nil }
            return model.lineup.first { $0.channel.frequency == current.channel.frequency }?.id
        } set: { id in
            guard let id, let entry = model.lineup.first(where: { $0.id == id }),
                  entry.channel.frequency != model.current?.channel.frequency else { return }
            model.select(entry)
        }
    }
}

/// 映像とオーバーレイ
private struct VideoArea: View {
    let model: ViewerModel

    var body: some View {
        ZStack {
            Color.black
            if let renderer = model.renderer {
                MetalVideoView(renderer: renderer)
            } else {
                Text("Metal を使えません").foregroundStyle(.secondary)
            }
            CaptionOverlayView(model: model.captions)
            if let guide = model.guide {
                GuidePanel(model: model, guide: guide)
            }
            if model.showsSignal {
                SignalPanel(monitor: model.signal)
                    .padding(.top, SignalPanelLayout.topInset)
                    .padding(.leading, SignalPanelLayout.leadingInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if model.isOverlayVisible {
                ChannelOverlay(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.isOverlayVisible)
        // 映像の部分の大きさを窓の扱いへ知らせる（16:9 を保つ・サイドバーの出し入れで窓を合わせる）
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.windowController.videoAreaDidChange($0) }
        .onContinuousHover { phase in
            if case .active = phase { model.showOverlay() }
        }
        .onChange(of: model.reception.notice) {
            model.showOverlay()
        }
    }
}

/// 映像の上に出し続ける案内（選局中・失敗・初回の準備）
private struct GuidePanel: View {
    let model: ViewerModel
    let guide: Guide
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 8) {
            Text(guide.title).font(.title3.weight(.semibold))
            if let detail = guide.detail {
                Text(detail).font(.callout).multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            if let action = guide.action {
                Button(title(of: action)) { perform(action) }
                    .padding(.top, 4)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .padding(24)
    }

    private func title(of action: GuideAction) -> String {
        switch action {
        case .recheckTuner: "もう一度確かめる"
        case .scan: "チャンネルスキャン…"
        case .openSettings: "設定を開く…"
        }
    }

    private func perform(_ action: GuideAction) {
        switch action {
        case .recheckTuner: model.checkTuner()
        case .scan: model.startScan()
        case .openSettings: openSettings()
        }
    }
}

/// マウスを動かしたときに出す局名・番組・放送時刻・音量
private struct ChannelOverlay: View {
    let model: ViewerModel

    var body: some View {
        VStack {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let current = model.current {
                    if let key = current.remoteControlKey {
                        Text(current.branch > 1 ? "\(key)-\(current.branch)" : "\(key)")
                            .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    }
                    Text(current.service.name).font(.title2.weight(.semibold))
                }
                Spacer()
                if let notice = model.reception.notice {
                    Text(notice.text).font(.callout)
                }
                if let clock = model.broadcastClock {
                    BroadcastClockText(clock: clock)
                }
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 16) {
                ProgramPanel(status: model.program)
                Spacer()
                if model.captions.isAvailable {
                    Label(model.captions.isEnabled ? "字幕" : "字幕（非表示）",
                          systemImage: model.captions.isEnabled ? "captions.bubble.fill" : "captions.bubble")
                        .font(.callout)
                }
                if let audioText {
                    Label(audioText, systemImage: "waveform")
                        .font(.callout)
                }
                Label(volumeText, systemImage: model.playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.callout.monospacedDigit())
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.8), radius: 3)
        .padding(16)
    }

    /// 音声の状態。ES が複数あれば何本目か、二重音声なら選んでいるもの。復号するまでは出さない
    private var audioText: String? {
        let audio = model.playback.audio
        guard let layout = audio.layout else { return nil }
        var text = AudioLabel.layout(layout)
        if layout == .dualMono {
            text += "（\(DualMonoLabel.text(model.playback.dualMonoChannel))）"
        }
        if audio.tracks.count > 1, let index = audio.selectedIndex {
            text = "\(AudioLabel.track(index))/\(audio.tracks.count)・" + text
        }
        return text
    }

    private var volumeText: String {
        model.playback.isMuted ? "ミュート" : "\(Int((model.playback.volume * 100).rounded()))%"
    }
}

/// 受信状態のパネルの置き場所
private enum SignalPanelLayout {
    /// 上端からの距離。オーバーレイの局名の行に重ならないように、その下に置く
    static let topInset: CGFloat = 64
    static let leadingInset: CGFloat = 16
}

/// 受信状態。出している間だけ 1 秒ごとに coaxd に尋ねる。数は選局してからの累計
private struct SignalPanel: View {
    let monitor: SignalMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("受信状態").font(.callout.weight(.semibold))
            if let status = monitor.status {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    row("ロック", status.locked.map { $0 ? "あり" : "なし" })
                    row("C/N", status.cnr.map { String(format: "%.1f dB", $0) })
                    row("信号の強さ", status.strength.map { String(format: "%.1f dBm", $0) })
                    row("ビットレート", status.bitrateMbps.map { String(format: "%.2f Mbps", $0) })
                    row("訂正できない誤り", status.errors.map(String.init))
                    row("不連続（受信）", status.inputDiscontinuities.map(String.init))
                    row("不連続（フィルタの後）", status.outputDiscontinuities.map(String.init))
                    row("coaxd が捨てた", status.dropped.map(String.init))
                }
                .font(.caption.monospacedDigit())
            } else {
                Text("受信していません").font(.caption)
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .task { await monitor.run() }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.white.opacity(0.75))
            Text(value ?? "-").gridColumnAlignment(.trailing)
        }
    }
}

/// 放送の時刻。Mac の時計と目立ってずれていれば、その差も出す（いつもの差はヘルプで見られる）
private struct BroadcastClockText: View {
    let clock: BroadcastClock

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .trailing, spacing: 2) {
                Text(ProgramDisplay.clock(clock.broadcastTime(at: context.date)))
                    .font(.title3.weight(.semibold).monospacedDigit())
                if abs(clock.offset) >= ProgramDisplay.noticeableClockOffset {
                    Text("Mac の時計との差 \(ProgramDisplay.offset(clock.offset))")
                        .font(.caption)
                }
            }
        }
        .help("放送の時刻。Mac の時計との差 \(ProgramDisplay.offset(clock.offset))")
    }
}

/// 現在・次の番組
private struct ProgramPanel: View {
    let status: ProgramDisplay.Status

    var body: some View {
        switch status {
        case .unavailable:
            EmptyView()
        case .loading:
            Text("番組情報を取得中…").font(.callout)
        case let .available(present, following):
            VStack(alignment: .leading, spacing: 6) {
                if let present {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ProgramDisplay.timeRange(present)).font(.callout.monospacedDigit())
                        Text(present.title).font(.title3.weight(.semibold)).lineLimit(2)
                        if !present.text.isEmpty {
                            Text(present.text).font(.callout).lineLimit(2)
                        }
                    }
                }
                if let following {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("次").font(.callout.weight(.semibold))
                        Text(ProgramDisplay.timeRange(following)).font(.callout.monospacedDigit())
                        Text(following.title).font(.callout).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: ProgramPanelLayout.maximumWidth, alignment: .leading)
        }
    }
}

/// 番組の欄の大きさ
private enum ProgramPanelLayout {
    /// 番組名と概要の折り返し幅。広い画面でも 1 行が長くなりすぎないように
    static let maximumWidth: CGFloat = 560
}

/// スキャンの進み具合
private struct ScanSheet: View {
    let model: ViewerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("チャンネルスキャン").font(.headline)
            if let progress = model.scanProgress {
                ProgressView(value: progress.fraction)
                Text("\(progress.channel) ch まで調べました（\(progress.completed) / \(progress.total)）・受信できたチャンネル \(progress.found)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text("チューナーを準備しています").font(.callout).foregroundStyle(.secondary)
            }
            Text("すべてのチャンネルを順に調べるので、10 分ほどかかります。その間は視聴できません。")
                .font(.callout)
            HStack {
                Spacer()
                Button("取り消す") { model.cancelScan() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
