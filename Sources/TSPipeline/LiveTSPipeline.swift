import Foundation
import os

/// ライブの TS パイプラインの時間の決まり。
public enum LiveTSPipelineTiming {
    /// 出力を待ってこれだけ来なければ、止まったとみなす（既定 5 秒）
    public static let stallTimeout: Duration = .seconds(5)
    /// 止まっていないかを見る間隔
    static let watchInterval: Duration = .milliseconds(250)
}

/// パイプラインが途中で終わった理由。
public enum LiveTSPipelineError: Error, LocalizedError, Sendable, Equatable {
    /// 出力が一定時間来なかった
    case stalled
    /// こちらから止めていないのに出力が終わった
    case endedUnexpectedly(detail: String)

    public var errorDescription: String? {
        switch self {
        case .stalled: "TS が届かなくなりました"
        case let .endedUnexpectedly(detail): detail.isEmpty ? "TS が途中で終わりました" : "TS が途中で終わりました: \(detail)"
        }
    }
}

/// 受信した TS を外部フィルタへ通し、再生へ渡すパイプライン。
///
/// 再生は `output` を引いたぶんだけ読む。引かれた TS で、スクランブルが解けているかと、
/// 放送からの遅れを見る。出力が止まる・こちらから止めていないのに終わると、`output` が失敗を投げる。
/// フィルタが無ければ受信した TS をそのまま渡す。
public final class LiveTSPipeline: @unchecked Sendable {
    /// 再生へ渡した TS を数えたもの（外部フィルタの後）
    public struct OutputStatistics: Sendable, Equatable {
        public var packets: Int
        /// continuity_counter が続いていなかったパケット
        public var discontinuities: Int
        public var syncLosses: Int
    }

    /// 今までに再生へ渡した TS を数えたもの
    public var outputStatistics: OutputStatistics {
        lock.withLock { OutputStatistics(packets: counter.packets, discontinuities: counter.discontinuities, syncLosses: counter.syncLosses) }
    }

    /// 再生を止めずに知らせること
    public enum Event: Sendable, Equatable {
        /// スクランブルの判断が変わった
        case descramble(DescrambleJudge.Verdict)
        /// 放送からの遅れがしきい値を超えた（1 本のパイプラインで 1 回だけ）
        case fellBehind(Duration)
    }

    private let input: ByteChunks
    private let closeInput: @Sendable () -> Void
    private let filter: ExternalFilter?
    private let stallTimeout: Duration
    private let onEvent: @Sendable (Event) -> Void

    private let lock = NSLock()
    private var stopped = false
    private var stalled = false
    /// 出力を待ち始めた時刻（待っていなければ nil）
    private var waitingSince: ContinuousClock.Instant?
    private var inputFailure: String?
    private var counter = TSPacketCounter()
    private var judge = DescrambleJudge()
    private var lagMonitor = BroadcastLagMonitor()
    private var reportedBehind = false
    private var feeder: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "ts")

    /// - Parameters:
    ///   - input: 受信した TS
    ///   - closeInput: 受信を閉じる（止まったときに、待っている読み出しを終わらせる）
    ///   - filter: 起動済みの外部フィルタ。nil なら受信した TS をそのまま渡す
    public init(input: ByteChunks, closeInput: @escaping @Sendable () -> Void, filter: ExternalFilter?,
                stallTimeout: Duration = LiveTSPipelineTiming.stallTimeout,
                onEvent: @escaping @Sendable (Event) -> Void) {
        self.input = input
        self.closeInput = closeInput
        self.filter = filter
        self.stallTimeout = stallTimeout
        self.onEvent = onEvent
        if let filter {
            feeder = Task.detached { [input, weak self] in
                defer { filter.closeInput() }
                do {
                    for try await data in input {
                        try await filter.write(data)
                    }
                } catch {
                    self?.noteInputFailure(error)
                }
            }
        }
        watchdog = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: LiveTSPipelineTiming.watchInterval)
                guard let self, self.checkStall() else { continue }
                await self.filter?.terminate()
                return
            }
        }
    }

    deinit {
        feeder?.cancel()
        watchdog?.cancel()
    }

    /// 再生へ渡す TS。終わりは nil（こちらから止めたとき）か、`LiveTSPipelineError` などの失敗
    public var output: ByteChunks {
        ByteChunks { [self] in try await self.next() }
    }

    /// 止める。フィルタを終了させ、受信を閉じる。`output` はこの後 nil を返す
    public func stop() async {
        let alreadyStopped = lock.withLock {
            defer { stopped = true }
            return stopped
        }
        guard !alreadyStopped else { return }
        feeder?.cancel()
        watchdog?.cancel()
        closeInput()
        await filter?.terminate()
    }

    // MARK: - 下請け

    private func next() async throws -> Data? {
        let source = filter?.output ?? input
        guard lock.withLock({ () -> Bool in
            if !stopped { waitingSince = .now }
            return !stopped
        }) else { return nil }
        let data: Data?
        do {
            data = try await source.produce()
        } catch {
            if let failure = ending(error) { throw failure }
            return nil
        }
        guard let data else {
            if let failure = ending(nil) { throw failure }
            return nil
        }
        let now = ContinuousClock.now
        let events = lock.withLock { () -> [Event] in
            waitingSince = nil
            var events: [Event] = []
            let before = judge.verdict
            counter.feed(data)
            if judge.observe(counter, at: now) != before {
                events.append(.descramble(judge.verdict))
            }
            if let pcr = counter.lastPCR {
                let lag = lagMonitor.observe(pcr: pcr, discontinuities: counter.pcrDiscontinuities, at: now)
                if !reportedBehind, lag > BroadcastLagMonitor.catchUpThreshold {
                    reportedBehind = true
                    events.append(.fellBehind(lag))
                }
            }
            return events
        }
        events.forEach(onEvent)
        return data
    }

    /// 出力が終わったときに投げるもの。こちらから止めたのなら nil（`output` は終わりを返す）
    private func ending(_ error: (any Error)?) -> (any Error)? {
        let (wasStopped, wasStalled, inputFailure) = lock.withLock {
            waitingSince = nil
            return (stopped, stalled, self.inputFailure)
        }
        if wasStopped { return nil }
        if wasStalled { return LiveTSPipelineError.stalled }
        if let error, !(error is ExternalFilterError) { return error }
        let detail = [inputFailure, filter?.stderrText, (error as? LocalizedError)?.errorDescription]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
        return LiveTSPipelineError.endedUnexpectedly(detail: detail)
    }

    private func noteInputFailure(_ error: any Error) {
        let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        lock.withLock { inputFailure = text }
    }

    /// 止まっていれば印を付けて受信を閉じ、true を返す
    private func checkStall() -> Bool {
        let stalledNow = lock.withLock { () -> Bool in
            guard !stopped, !stalled, let since = waitingSince, ContinuousClock.now - since >= stallTimeout else { return false }
            stalled = true
            return true
        }
        guard stalledNow else { return false }
        Self.logger.error("出力が \(self.stallTimeout.formatted(.units(allowed: [.seconds])), privacy: .public) 来ないので止まったとみなした")
        closeInput()
        return true
    }
}
