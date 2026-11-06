import AppKit
import MetalKit
import Observation
import os
import SwiftUI

/// 再生系を試すための仕組み（検証用。ふだんの視聴は ViewerView）。
///
/// TS ファイルを PCR の速さで読み出して、PlayerEngine と VideoRenderer で再生する。
/// 環境変数で自動の計測もできる:
///   MIRNE_LAB_FILE      再生するファイル
///   MIRNE_LAB_SECONDS   この秒数で統計を書き出して終了する
///   MIRNE_LAB_REPORT    この秒数ごとに途中の統計を書き出す（長時間の試験用）
///   MIRNE_LAB_LOOP      1 なら、ファイルを最後まで流したら先頭から流し直す（8 時間の計測用）。
///                       つなぎ目では PCR が先頭へ戻るので、時計の張り直しが 1 回ずつ増える
///   MIRNE_LAB_FLOAT     1 なら、ウィンドウを最前面に置く（長時間の計測で、ほかの窓に隠れて描画が間引かれないように）
///   MIRNE_LAB_VOLUME    音量（0〜1）。ファイルの再生にも効く
///   MIRNE_LAB_SNAPSHOT  指定した秒（カンマ区切り）に描いたフレームを、MIRNE_LAB_OUTPUT のフォルダーへ PNG で書き出す。
///                       そのとき出している字幕を、そのフレームに重ねた画像（captions-秒.png。960×540）も書き出す
///   MIRNE_LAB_DEINTERLACE  weave・bob・adaptive（既定 adaptive）
///   MIRNE_LAB_SWITCH    「秒:サービスID」をカンマ区切りで。その秒に同じ TS の中のサービスへ切り替える
///   MIRNE_LAB_AUDIO     「秒:番号」をカンマ区切りで。その秒に音声 ES（PMT の順に 1 から）を切り替える
///   MIRNE_LAB_DUALMONO  「秒:main|sub|both」をカンマ区切りで。その秒に二重音声の主・副・主+副を切り替え、
///                       出力へ渡した音声のどこから効いたかを測る（素材は dual-mono.ts。`DualMonoProbe`）
/// ファイルの代わりにチューナーから受信する（Reception → LivePlayback の道筋を通す）:
///   MIRNE_LAB_FREQ      選局する周波数（Hz）
///   MIRNE_LAB_RETUNE    「秒:周波数」をカンマ区切りで。その秒に選局し直す
///   MIRNE_LAB_FILTER    外部フィルタ（/bin/sh -c で実行）。MIRNE_LAB_PCSC=1 で PC/SC のソケットも渡す
///   MIRNE_LAB_SERVICE   再生するサービス（番組番号）
///   MIRNE_LAB_MUTE      その秒にミュートし、2 秒後に戻す
@MainActor
@Observable
final class PlaybackLab {
    /// 統計を書き換える間隔
    static let statisticsInterval: Duration = .milliseconds(500)

    let engine: PlayerEngine
    let renderer: VideoRenderer?
    /// 字幕の重ね描き（検証画面では常に出す）
    let captions: CaptionOverlayModel
    private(set) var fileName = ""
    private(set) var statusText = "ファイルを開いてください（検証用）"
    var deinterlace = DeinterlaceMode.adaptive {
        didSet { renderer?.deinterlace = deinterlace }
    }

    private var playback: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    /// チューナーから受信するとき（MIRNE_LAB_FREQ）だけ使う
    private var reception: Reception?
    private var live: LivePlayback?
    private var started = ContinuousClock.now
    private let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "player")

    init() {
        let engine = PlayerEngine()
        self.engine = engine
        renderer = VideoRenderer(frames: engine.frames)
        renderer?.clock = { engine.presentationTime() }
        renderer?.mediaTimeAtHost = { engine.mediaTime(atHost: $0) }
        renderer?.clockEpoch = { engine.clockEpoch }
        captions = CaptionOverlayModel(engine: engine, renderer: renderer, isEnabled: true)
        startAutomaticRunIfRequested()
    }

    func open(_ url: URL) {
        stop()
        // 描画側は FrameQueue を握っているので、エンジンは作り直さず空にして使い回す
        let engine = self.engine
        renderer?.resetStatistics()
        captions.resetStatistics()
        renderer?.deinterlace = deinterlace
        fileName = url.lastPathComponent
        started = .now
        let source = TSFileSource(url: url)
        let loops = ProcessInfo.processInfo.environment["MIRNE_LAB_LOOP"] == "1"
        playback = Task.detached {
            do {
                repeat {
                    try await source.run { engine.feed($0) }
                } while loops && !Task.isCancelled
            } catch is CancellationError {
            } catch {
                await MainActor.run { self.statusText = "読み出しに失敗しました: \(error.localizedDescription)" }
            }
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.statisticsInterval)
                self?.refreshStatus()
            }
        }
    }

    func stop() {
        playback?.cancel()
        monitor?.cancel()
        reception?.stop()
        if live == nil { engine.stop() }
    }

    /// チューナーから受信して再生する（受信から再生までの道筋の検証）
    func openLive(frequency: Int, filter: String?, pcsc: Bool, serviceID: UInt16?) {
        stop()
        renderer?.resetStatistics()
        renderer?.deinterlace = deinterlace
        started = .now
        guard let coaxd = CoaxdLauncher.locate() else {
            statusText = "coaxd が見つかりません"
            return
        }
        let reception = self.reception ?? Reception(tuner: TunerSession(service: CoaxTunerService(launcher: CoaxdLauncher(executable: coaxd))))
        let live = self.live ?? LivePlayback(engine: engine)
        self.reception = reception
        self.live = live
        reception.filterSettings = FilterSettings(command: filter.map { ExternalFilterCommand(executable: "/bin/sh", arguments: ["-c", $0]) },
                                                  usesPCSC: pcsc)
        reception.onOutput = { [weak live] output in live?.play(output, serviceID: serviceID) }
        retune(frequency)
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.statisticsInterval)
                self?.refreshStatus()
            }
        }
    }

    /// 選局し直す（受信中のとき）
    func retune(_ frequency: Int) {
        fileName = "\(frequency) Hz"
        reception?.tune(TuningTarget(frequency: frequency))
    }

    /// 画面に出す統計
    private func refreshStatus() {
        statusText = summary()
    }

    func summary() -> String {
        let playback = engine.statistics
        let render = renderer?.statistics ?? VideoRenderStatistics()
        let decoder = engine.decoder
        let elapsed = ContinuousClock.now - started
        var lines: [String] = []
        lines.append("\(fileName)  経過 \(String(format: "%.1f", elapsed.seconds)) 秒・\(render.lastSize)・\(String(describing: deinterlace))")
        let window = NSApp.windows.first { $0.isVisible }
        let occlusion = window.map { $0.occlusionState.contains(.visible) ? "見えている" : "隠れている" } ?? "-"
        lines.append("画面: \(window?.screen?.localizedName ?? "-")（最大 \(window?.screen?.maximumFramesPerSecond ?? 0) fps）・描画の大きさ \(renderer.map { "\(Int($0.view.drawableSize.width))×\(Int($0.view.drawableSize.height))" } ?? "-")")
        lines.append("draw \(String(format: "%.1f", Double(render.calls) / max(elapsed.seconds, 0.001))) 回/秒・フレームを描いた \(render.drawn)（ウィンドウは\(occlusion)）・空振り \(render.starved)・選んだフィールドの遅れの最大 \(String(format: "%.1f", render.maximumLateness)) ms・drawable 待ち最大 \(String(format: "%.1f", render.maximumDrawableWait)) ms・draw 最大 \(String(format: "%.1f", render.maximumDrawTime)) ms")
        if let sync = renderer?.avSync.summary {
            lines.append(String(format: "A/V のずれ（画面に出た時刻 − PTS。正は映像が遅れ）: 中央 %.1f ms・5〜95%% %.1f〜%.1f ms・最小 %.1f・最大 %.1f（%d 回）・描いてから出るまで %.1f ms",
                                sync.p50, sync.p5, sync.p95, sync.minimum, sync.maximum, sync.count, renderer?.presentationDelayMilliseconds ?? 0))
        }
        if deinterlace == .adaptive {
            lines.append("動き適応で描いた \(render.adaptiveFields)・前後が無く bob にした \(render.adaptiveFallbacks)")
        }
        lines.append("映像 PES \(playback.videoPES)・遅れて捨てた \(engine.frames.lateDrops)・溢れて捨てた \(engine.frames.overflowDrops)・先頭の B \(decoder.skippedLeadingB)・欠けたまま \(decoder.damagedPictures)・復号の失敗 \(decoder.decodeErrors)")
        lines.append("音声の組み立て: \(engine.audioFramingSummary)")
        let late = captions.lateness.sorted()
        func percentile(_ p: Double) -> String {
            late.isEmpty ? "-" : String(format: "%.0f", late[min(late.count - 1, Int(Double(late.count - 1) * p))])
        }
        lines.append("字幕: データグループ \(playback.captionGroups)・読めない \(playback.captionUnreadable)・本文 \(playback.captionStatements)・"
                     + "出した \(late.count)・出し始めの遅れ（出した時刻 − PTS）中央 \(percentile(0.5)) ms・95% \(percentile(0.95)) ms・最小 \(late.first.map { String(format: "%.0f", $0) } ?? "-") ms・最大 \(late.last.map { String(format: "%.0f", $0) } ?? "-") ms")
        lines.append("音声 \(playback.audioFrames) フレーム・失敗 \(playback.audioFailures)・出力の状態 \(engine.audioRenderer.status.rawValue)\(playback.isDualMono ? "・二重音声（\(engine.dualMonoChannel)）" : "")")
        let audio = engine.audioStatus
        lines.append("音声 ES \(audio.tracks.count) 本・\(audio.selectedIndex.map { "\($0 + 1) 本目" } ?? "-")（PID \(audio.selected.map { String(format: "0x%04X", $0.pid) } ?? "-")）・構成 \(audio.layout.map { String(describing: $0) } ?? "-")")
        lines.append("サービス \(engine.currentServiceID.map(String.init) ?? "-")・切替 \(playback.switches) 回・直近の切替から再生まで \(playback.lastSwitchDelay.map { String(format: "%.0f ms", $0.seconds * 1000) } ?? "-")")
        if let reception {
            let state: String = switch reception.tuner.state {
            case .idle: "停止"
            case let .tuning(_, attempt): "選局中（\(attempt) 回目）"
            case let .receiving(_, tunerID): "受信中（\(tunerID ?? "-")）"
            case let .failed(_, failure): "失敗: \(failure.title)。\(failure.advice)"
            }
            lines.append("チューナー: \(state)・スクランブル \(String(describing: reception.descramble))・知らせ \(reception.notice?.text ?? "-")・音量 \(live.map { String(format: "%.2f%@", $0.volume, $0.isMuted ? "（ミュート）" : "") } ?? "-")")
        }
        lines.append("再生開始 \(playback.starts) 回（最初は受信から \(playback.firstStartDelay.map { String(format: "%.0f ms", $0.seconds * 1000) } ?? "-")）・時計の張り直し \(playback.discontinuities)・PCR との差 \(playback.latency.map { String(format: "%.0f ms", $0) } ?? "-")・音声の先行 \(playback.audioAhead.map { String(format: "%.0f ms", $0) } ?? "-")")
        return lines.joined(separator: "\n")
    }

    // MARK: - 自動の計測

    private func startAutomaticRunIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["MIRNE_LAB_FILE"]
        let frequency = environment["MIRNE_LAB_FREQ"].flatMap { Int($0) }
        guard path != nil || frequency != nil else { return }
        switch environment["MIRNE_LAB_DEINTERLACE"] {
        case "weave": deinterlace = .weave
        case "bob": deinterlace = .bob
        default: break
        }
        let seconds = environment["MIRNE_LAB_SECONDS"].flatMap(Double.init) ?? 20
        let snapshots = (environment["MIRNE_LAB_SNAPSHOT"] ?? "").split(separator: ",").compactMap { Double($0) }
        let output = URL(fileURLWithPath: environment["MIRNE_LAB_OUTPUT"] ?? NSTemporaryDirectory())
        Task {
            // ウィンドウが表示されるのを待ち、前面に出す（隠れたウィンドウは描画を間引かれる）
            try? await Task.sleep(for: .milliseconds(500))
            NSApp.activate()
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            // MIRNE_LAB_SCREEN に画面の名前の一部を渡すと、その画面へウィンドウを移す（画面ごとの描画の比較用）。
            // 画面の名前はアプリの言語で返る（mirne は日本語なので内蔵画面は「内蔵Retinaディスプレイ」。「Built-in」では見つからない）。
            // 見つからなければ、その旨と画面の一覧を出す
            // NSApp.windows の先頭は視聴ウィンドウとは限らない（最初は先頭を動かしていて、内蔵画面へ移せていなかった）ので、
            // 見えている中で一番大きいウィンドウを動かし、移った先の画面を確かめる
            if let wanted = environment["MIRNE_LAB_SCREEN"],
               let window = NSApp.windows.filter({ $0.isVisible }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
               let screen = NSScreen.screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains(wanted) }) {
                let size = window.frame.size
                let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)
                window.setFrame(NSRect(origin: origin, size: size), display: true)
                try? await Task.sleep(for: .milliseconds(300))
                print("ウィンドウを「\(wanted)」へ移した → 今の画面: \(window.screen?.localizedName ?? "-")")
            } else if let wanted = environment["MIRNE_LAB_SCREEN"] {
                print("画面「\(wanted)」が見つからない。画面: \(NSScreen.screens.map(\.localizedName).joined(separator: "・"))")
            }
            if let frequency {
                openLive(frequency: frequency, filter: environment["MIRNE_LAB_FILTER"], pcsc: environment["MIRNE_LAB_PCSC"] == "1",
                         serviceID: environment["MIRNE_LAB_SERVICE"].flatMap { UInt16($0) })
            } else if let path {
                open(URL(fileURLWithPath: path))
            }
            if let volume = environment["MIRNE_LAB_VOLUME"].flatMap(Float.init) {
                if let live { live.volume = volume } else { engine.volume = volume }
            }
            if environment["MIRNE_LAB_FLOAT"] == "1",
               let window = NSApp.windows.filter({ $0.isVisible }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                window.level = .floating
            }
            if let interval = environment["MIRNE_LAB_REPORT"].flatMap(Double.init), interval > 0 {
                // 長時間の試験で、途中の統計を残す（遅れて捨てたフレームがいつ増えたか・A/V のずれの移り変わり）
                Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
                        guard let self else { return }
                        print("--- 途中の統計\n\(self.summary())")
                        fflush(stdout)
                    }
                }
            }
            // 書き出しと切替を時刻の順に行う
            enum Action {
                case snapshot(Double), service(Double, UInt16), retune(Double, Int), mute(Double), audio(Double, Int)
                case dualMono(Double, DualMonoChannel)
            }
            var actions = snapshots.map { Action.snapshot($0) }
            for item in (environment["MIRNE_LAB_RETUNE"] ?? "").split(separator: ",") {
                let parts = item.split(separator: ":")
                if parts.count == 2, let time = Double(parts[0]), let target = Int(parts[1]) {
                    actions.append(.retune(time, target))
                }
            }
            if let time = environment["MIRNE_LAB_MUTE"].flatMap(Double.init) {
                actions.append(.mute(time))
            }
            for item in (environment["MIRNE_LAB_SWITCH"] ?? "").split(separator: ",") {
                let parts = item.split(separator: ":")
                if parts.count == 2, let time = Double(parts[0]), let service = UInt16(parts[1]) {
                    actions.append(.service(time, service))
                }
            }
            for item in (environment["MIRNE_LAB_AUDIO"] ?? "").split(separator: ",") {
                let parts = item.split(separator: ":")
                if parts.count == 2, let time = Double(parts[0]), let number = Int(parts[1]) {
                    actions.append(.audio(time, number))
                }
            }
            var dualMonoProbe: DualMonoProbe?
            for item in (environment["MIRNE_LAB_DUALMONO"] ?? "").split(separator: ",") {
                let parts = item.split(separator: ":")
                let channels: [String: DualMonoChannel] = ["main": .main, "sub": .sub, "both": .both]
                if parts.count == 2, let time = Double(parts[0]), let channel = channels[String(parts[1])] {
                    actions.append(.dualMono(time, channel))
                    if dualMonoProbe == nil {
                        let probe = DualMonoProbe()
                        engine.onAudioEnqueued = { probe.record($0) }
                        dualMonoProbe = probe
                    }
                }
            }
            func time(of action: Action) -> Double {
                switch action {
                case let .snapshot(t), let .mute(t): t
                case let .service(t, _): t
                case let .retune(t, _): t
                case let .audio(t, _): t
                case let .dualMono(t, _): t
                }
            }
            for action in actions.sorted(by: { time(of: $0) < time(of: $1) }) {
                try? await Task.sleep(until: started + .milliseconds(Int(time(of: action) * 1000)))
                switch action {
                case let .snapshot(t):
                    let frameURL = output.appendingPathComponent(String(format: "snapshot-%05.2f.png", t))
                    renderer?.requestSnapshot(to: frameURL)
                    writeCaptionSnapshot(over: frameURL, to: output.appendingPathComponent(String(format: "captions-%05.2f.png", t)))
                case let .retune(t, target):
                    let requested = ContinuousClock.now
                    let startsBefore = engine.statistics.starts
                    retune(target)
                    while engine.statistics.starts == startsBefore, ContinuousClock.now - requested < .seconds(8) {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    print(String(format: "%.1f 秒に %d Hz へ選局し直し: ", t, target)
                          + (engine.statistics.starts > startsBefore ? String(format: "%.0f ms で再生", (ContinuousClock.now - requested).seconds * 1000) : "8 秒たっても再生しない"))
                case let .mute(t):
                    live?.isMuted = true
                    print(String(format: "%.1f 秒にミュート（音声の出力: %@）", t, engine.isMuted ? "ミュート" : "鳴っている"))
                    try? await Task.sleep(for: .seconds(2))
                    live?.isMuted = false
                case let .audio(t, number):
                    let tracks = engine.audioStatus.tracks
                    guard tracks.indices.contains(number - 1) else {
                        print(String(format: "%.1f 秒: 音声 %d は無い（%d 本）", t, number, tracks.count))
                        continue
                    }
                    let framesBefore = engine.statistics.audioFrames
                    let failuresBefore = engine.statistics.audioFailures
                    engine.selectAudio(tracks[number - 1])
                    try? await Task.sleep(for: .seconds(2))
                    let status = engine.audioStatus
                    let statistics = engine.statistics
                    print(String(format: "%.1f 秒に音声 %d へ: ", t, number)
                          + "PID \(status.selected.map { String(format: "0x%04X", $0.pid) } ?? "-")・構成 \(status.layout.map { String(describing: $0) } ?? "-")・"
                          + "2 秒で音声 \(statistics.audioFrames - framesBefore) フレーム・失敗 \(statistics.audioFailures - failuresBefore)・"
                          + "音声の先行 \(statistics.audioAhead.map { String(format: "%.0f ms", $0) } ?? "-")・再生開始 \(statistics.starts) 回")
                case let .dualMono(t, channel):
                    guard let probe = dualMonoProbe else { continue }
                    reportDualMonoSwitch(at: t, to: channel, probe: probe)
                case let .service(t, service):
                    engine.requestService(service)
                    try? await Task.sleep(for: .seconds(2))
                    print(String(format: "%.1f 秒に %d へ切替: ", t, service) + (engine.statistics.lastSwitchDelay.map { String(format: "%.0f ms で再生", $0.seconds * 1000) } ?? "まだ再生していない"))
                }
            }
            try? await Task.sleep(until: started + .milliseconds(Int(seconds * 1000)))
            if let segments = dualMonoProbe?.segments() {
                print("出力へ渡した音声の移り変わり:\n" + segments.map { "  " + $0 }.joined(separator: "\n"))
            }
            let text = summary()
            print(text)
            logger.info("\(text, privacy: .public)")
            stop()
            NSApp.terminate(nil)
        }
    }
}

extension PlaybackLab {
    /// 二重音声の切替を記録した後、出力へ渡した音声を見る長さ
    static let dualMonoObservation: Duration = .milliseconds(1500)

    /// 二重音声を切り替え、出力へ渡した音声のどこから選んだものになったかを書き出す。
    /// 「鳴り始めるまで」は、選んだものに変わった最初のフレームの PTS − 切り替えた時の再生の時計
    /// （出力に渡し済みの音声が鳴り終わるまで。出力の装置の遅れは含まない）
    func reportDualMonoSwitch(at t: Double, to channel: DualMonoChannel, probe: DualMonoProbe) {
        let now = engine.presentationTime()
        let lastBefore = probe.lastPTS
        let failuresBefore = engine.statistics.audioFailures
        engine.dualMonoChannel = channel
        Task {
            try? await Task.sleep(for: Self.dualMonoObservation)
            let expected = DualMonoProbe.expected(channel)
            let frames = probe.frames(after: lastBefore ?? .min)
            let first = frames.firstIndex { $0.left == expected.left && $0.right == expected.right }
            let mismatches = first.map { index in frames[index...].filter { $0.left != expected.left || $0.right != expected.right }.count }
            var text = String(format: "%.1f 秒に二重音声を %@ へ: ", t, String(describing: channel))
            if let first, let now {
                text += String(format: "切り替えた後に渡した %d フレームのうち %d 番目から選んだもの・鳴り始めるまで %.0f ms・その後の食い違い %d・",
                               frames.count, first + 1, Double(frames[first].pts - now) / 90, mismatches ?? 0)
            } else {
                text += "選んだものが出ていない（\(frames.count) フレーム）・"
            }
            text += "失敗 \(engine.statistics.audioFailures - failuresBefore)・二重音声 \(engine.statistics.isDualMono ? "はい" : "いいえ")"
            print(text)
        }
    }

    /// 検証用の画像の大きさ（字幕の画面の既定と同じ 960×540）
    static let captionSnapshotSize = CGSize(width: 960, height: 540)

    /// いま出している字幕を、書き出したフレームに重ねて PNG にする（字幕の位置と映像の合いを目で確かめる）。
    /// フレームの書き出しは次の描画で行われるので、少し待ってから読む
    func writeCaptionSnapshot(over frameURL: URL, to url: URL) {
        let cues = captions.cues
        let aspect = captions.displayAspectRatio
        let hidden = captions.hiddenByFlash
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            let frame = NSImage(contentsOf: frameURL)
            let view = ZStack {
                Color.black
                if let frame {
                    Image(nsImage: frame).resizable()
                }
                CaptionLayer(cues: cues, displayAspectRatio: aspect, hiddenByFlash: hidden)
            }
            .frame(width: Self.captionSnapshotSize.width, height: Self.captionSnapshotSize.height)
            let renderer = ImageRenderer(content: view)
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            try? data.write(to: url)
            print("字幕の画像 \(url.lastPathComponent)：\(cues.map(\.text.text).joined(separator: " / "))\(hidden.isEmpty ? "" : "（点滅で消えている）")")
        }
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// MTKView を SwiftUI に置く
struct MetalVideoView: NSViewRepresentable {
    let renderer: VideoRenderer

    func makeNSView(context: Context) -> MTKView { renderer.view }
    func updateNSView(_ view: MTKView, context: Context) {}
}
