import AppKit
import SwiftUI

/// リモコンキーとキーボードの対応。1〜9・0（10）・-（11）・^（12）。JIS 配列の数字の行に合わせる
enum RemoteControlKeys {
    static let keys: [(number: Int, key: KeyEquivalent)] = [
        (1, "1"), (2, "2"), (3, "3"), (4, "4"), (5, "5"), (6, "6"),
        (7, "7"), (8, "8"), (9, "9"), (10, "0"), (11, "-"), (12, "^"),
    ]
}

/// メニューとキーボード操作。構成はファイル・表示・コントロール・ウインドウ・ヘルプ（2026-11-22 に、視聴の操作を
/// 「チャンネル」「音声」から「コントロール」へまとめ、窓の操作をウインドウへ、字幕をコントロールへ移した）
/// - 表示：映像に重ねる表示（全画面・受信状態）と、番組表を開く
/// - コントロール：視聴の操作（チャンネル・音声・字幕・音量）
/// - ウインドウ：窓の大きさと並び（標準の大きさに戻す・常に最前面）
/// - ファイル：受信の設定を作り直す操作（チャンネルスキャン）
/// - ヘルプ：ヘルプの本は無いので、項目を外して macOS が付ける検索の欄だけを残す
struct ViewerCommands: Commands {
    let model: ViewerModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        SidebarCommands()
        CommandGroup(after: .newItem) {
            Button("チャンネルスキャン…") { model.startScan() }
                .disabled(model.isScanning)
        }
        CommandGroup(after: .sidebar) {
            Button("全画面表示") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            .keyboardShortcut("f", modifiers: [])
            Toggle("受信状態", isOn: Binding(get: { model.showsSignal }, set: { model.showsSignal = $0 }))
                .keyboardShortcut("i", modifiers: [])
            Divider()
            Button("番組表") { openWindow(id: WindowID.guide) }
                .keyboardShortcut("g", modifiers: [])
                .disabled(model.lineup.isEmpty)
            Button("番組表を重ねて表示") { model.isGuideSheetPresented = true }
                .keyboardShortcut("g", modifiers: .shift)
                .disabled(model.lineup.isEmpty || model.isScanning)
        }
        CommandMenu("コントロール") {
            // ↑ で次、↓ で前（テレビのリモコンのチャンネルの ▲ ▼ と同じ向き。2026-11-22 に逆から直した）
            Button("次のチャンネル") { model.step(1) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("前のチャンネル") { model.step(-1) }
                .keyboardShortcut(.downArrow, modifiers: [])
            Menu("局を選ぶ") {
                ForEach(RemoteControlKeys.keys, id: \.number) { item in
                    Button(title(forKey: item.number)) {
                        model.select(remoteControlKey: item.number)
                    }
                    .keyboardShortcut(item.key, modifiers: [])
                    .disabled(!model.lineup.contains { $0.remoteControlKey == item.number })
                }
            }
            Menu("サブチャンネル") {
                ForEach(model.subServices) { entry in
                    Button("\(entry.branch). \(entry.service.name)") { model.select(entry) }
                }
            }
            .disabled(model.subServices.count < 2)
            Divider()
            Button("音声を切り替える") { model.cycleAudio() }
                .keyboardShortcut("a", modifiers: [])
                .disabled(!model.canCycleAudio)
            Picker("音声", selection: Binding(get: { model.playback.audio.selected }, set: { $0.map(model.selectAudio) })) {
                ForEach(Array(model.playback.audio.tracks.enumerated()), id: \.element) { index, track in
                    Text(AudioLabel.track(index)).tag(Optional(track))
                }
            }
            .disabled(model.playback.audio.tracks.count < 2)
            Picker("二重音声", selection: Binding(get: { model.playback.dualMonoChannel }, set: { model.selectDualMono($0) })) {
                ForEach(DualMonoChannel.allCases, id: \.self) { channel in
                    Text(DualMonoLabel.text(channel)).tag(channel)
                }
            }
            Toggle("字幕", isOn: Binding(get: { model.captions.isEnabled }, set: { _ in model.toggleCaptions() }))
                .keyboardShortcut("c", modifiers: [])
            Divider()
            Button(model.playback.isMuted ? "ミュートを解除" : "ミュート") { model.toggleMute() }
                .keyboardShortcut("m", modifiers: [])
            Button("音量を上げる") { model.changeVolume(by: VolumeStep.increment) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("音量を下げる") { model.changeVolume(by: -VolumeStep.increment) }
                .keyboardShortcut(.downArrow, modifiers: .command)
        }
        CommandGroup(after: .windowSize) {
            Button("標準の大きさに戻す") { model.windowController.resetSize() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!model.windowController.canResetSize)
            Toggle("常に最前面", isOn: Binding(get: { model.windowController.isAlwaysOnTop },
                                             set: { model.windowController.isAlwaysOnTop = $0 }))
                .keyboardShortcut("t", modifiers: [])
                .disabled(model.windowController.isFullScreen)
        }
        CommandGroup(replacing: .help) {}
    }

    private func title(forKey number: Int) -> String {
        let name = model.lineup.first { $0.remoteControlKey == number }?.service.name
        return name.map { "\(number)  \($0)" } ?? "\(number)"
    }
}

/// 音声 ES とチャンネル構成の名前（メニューとオーバーレイで使う）
enum AudioLabel {
    /// 音声 ES は PMT に書かれた順に番号で呼ぶ（ES ごとの説明は PMT に無い）
    static func track(_ index: Int) -> String {
        "音声 \(index + 1)"
    }

    static func layout(_ layout: AudioLayout) -> String {
        switch layout {
        case .mono: "モノラル"
        case .stereo: "ステレオ"
        case .dualMono: "二重音声"
        case .surround51: "5.1ch"
        case let .other(configuration):
            switch configuration {
            case 3, 4, 5: "\(configuration)ch"
            case 7: "7.1ch"
            default: "マルチチャンネル"
            }
        }
    }
}

/// 二重音声の選択肢の名前（メニューとオーバーレイで使う）
enum DualMonoLabel {
    static func text(_ channel: DualMonoChannel) -> String {
        switch channel {
        case .main: "主音声"
        case .sub: "副音声"
        case .both: "主＋副"
        }
    }
}
