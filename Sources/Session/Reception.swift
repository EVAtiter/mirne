import Foundation
import Observation
import os

/// 外部フィルタの設定（設定画面は SettingsView）。
public struct FilterSettings: Sendable, Equatable, Codable {
    /// 受信した TS を通すコマンド。nil ならフィルタを使わない
    public var command: ExternalFilterCommand?
    /// `coax pcsc` を用意し、ソケットのパスを `PCSCLITE_CSOCK_NAME` で渡す
    public var usesPCSC: Bool

    public init(command: ExternalFilterCommand? = nil, usesPCSC: Bool = false) {
        self.command = command
        self.usesPCSC = usesPCSC
    }
}

/// 短く表示する知らせ。同じ文でも出すたびに別のものとして扱う
public struct ReceptionNotice: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let text: String

    init(_ text: String) {
        id = UUID()
        self.text = text
    }
}

/// 受信全体（選局 → 外部フィルタ → 再生へ渡す TS）をまとめる。
///
/// `TunerSession` が受信を始めるたびに `LiveTSPipeline` を作り、その出力を `onOutput` で再生へ渡す。
/// パイプラインが止まる・終わると選局し直し（`TunerSession.streamEnded`）、放送から遅れたら
/// 同じ局を選局し直して追いつく。
@MainActor @Observable
public final class Reception {
    public let tuner: TunerSession
    public var filterSettings: FilterSettings
    /// 外部フィルタを通した TS のスクランブルの判断
    public private(set) var descramble: DescrambleJudge.Verdict = .undecided
    /// 最後の知らせ（追いついた、など）
    public private(set) var notice: ReceptionNotice?

    /// 今の受信で再生へ渡した TS を数えたもの。受信していなければ nil
    public var outputStatistics: LiveTSPipeline.OutputStatistics? { pipeline?.outputStatistics }

    /// 受信が始まるたびに、再生へ渡す TS を渡す。読み手が終わり（nil か失敗）まで読む
    @ObservationIgnored public var onOutput: ((ByteChunks) -> Void)?

    @ObservationIgnored private let coax: URL?
    @ObservationIgnored private var pipeline: LiveTSPipeline?
    @ObservationIgnored private var pcsc: CoaxPCSCSocket?

    private static let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "ts")

    /// - Parameter coax: `coax pcsc` に使う `coax` の実行ファイル（既定は同梱品）
    public init(tuner: TunerSession, filterSettings: FilterSettings = FilterSettings(),
                coax: URL? = CoaxPCSCSocket.locateCoax()) {
        self.tuner = tuner
        self.filterSettings = filterSettings
        self.coax = coax
        tuner.onStream = { [weak self] stream in
            self?.receive(stream)
        }
    }

    /// 選局する
    public func tune(_ target: TuningTarget) {
        tuner.tune(target)
    }

    /// 受信をやめ、外部フィルタと `coax pcsc` の接続を手放す
    public func stop() {
        tuner.stop()
        retire(pipeline)
        pipeline = nil
        pcsc?.release()
        pcsc = nil
        descramble = .undecided
    }

    // MARK: - 下請け

    private func receive(_ stream: any TunerStreamHandle) {
        retire(pipeline)
        pipeline = nil
        descramble = .undecided
        let settings = filterSettings
        let report: @Sendable (LiveTSPipeline.Event) -> Void = { [weak self] event in
            Task { @MainActor in self?.handle(event, from: stream) }
        }
        Task {
            do {
                let filter = try await startFilter(settings)
                guard stream === tuner.stream else {
                    // 待っている間に選局し直した
                    await filter?.terminate()
                    return
                }
                let pipeline = LiveTSPipeline(input: stream.bytes, closeInput: { stream.close() }, filter: filter,
                                              onEvent: report)
                self.pipeline = pipeline
                onOutput?(watched(pipeline.output, from: stream))
            } catch let failure as TunerFailure {
                guard stream === tuner.stream else { return }
                tuner.giveUp(failure)
            } catch {
                guard stream === tuner.stream else { return }
                tuner.giveUp(.filter(detail: (error as? LocalizedError)?.errorDescription ?? "\(error)"))
            }
        }
    }

    /// 設定に従って外部フィルタを起動する（無ければ nil）
    private func startFilter(_ settings: FilterSettings) async throws -> ExternalFilter? {
        guard let command = settings.command else { return nil }
        var environment: [String: String] = [:]
        if settings.usesPCSC {
            if pcsc == nil {
                guard let coax else { throw TunerFailure.filter(detail: "coax が見つかりません（PC/SC のソケットを用意できません）") }
                do {
                    pcsc = try await CoaxPCSCSocket.ensure(coax: coax)
                } catch {
                    throw TunerFailure.filter(detail: "PC/SC のソケットを用意できません: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                }
            }
            environment["PCSCLITE_CSOCK_NAME"] = pcsc?.path
        }
        return try ExternalFilter.start(command, extraEnvironment: environment)
    }

    /// 再生が読み終えたら（終わりか失敗）、それが今の受信なら選局し直してもらう
    private func watched(_ output: ByteChunks, from stream: any TunerStreamHandle) -> ByteChunks {
        let ended: @Sendable ((any Error)?) -> Void = { [weak self] error in
            Task { @MainActor in self?.outputEnded(from: stream, error: error) }
        }
        return ByteChunks {
            do {
                let data = try await output.produce()
                if data == nil { ended(nil) }
                return data
            } catch {
                ended(error)
                throw error
            }
        }
    }

    private func outputEnded(from stream: any TunerStreamHandle, error: (any Error)?) {
        guard stream === tuner.stream else { return }
        retire(pipeline)
        pipeline = nil
        tuner.streamEnded(stream, error: error)
    }

    private func handle(_ event: LiveTSPipeline.Event, from stream: any TunerStreamHandle) {
        guard stream === tuner.stream else { return }
        switch event {
        case let .descramble(verdict):
            descramble = verdict
        case let .fellBehind(lag):
            Self.logger.notice("放送から \(lag.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))), privacy: .public) 遅れた")
            notice = ReceptionNotice("放送に追いつくため、選局し直しました")
            tuner.retune()
        }
    }

    /// パイプラインを止める（フィルタの終了を待つのは裏で行う）
    private func retire(_ pipeline: LiveTSPipeline?) {
        guard let pipeline else { return }
        Task.detached { await pipeline.stop() }
    }
}
