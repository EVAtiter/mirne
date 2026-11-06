import Foundation
import Observation
import os

/// 選局する先（物理チャンネル）。チャンネル一覧から作る。
public struct TuningTarget: Sendable, Equatable {
    /// 周波数（Hz）
    public var frequency: Int
    /// 伝送方式（`ISDBT`）
    public var system: String

    public init(frequency: Int, system: String = "ISDBT") {
        self.frequency = frequency
        self.system = system
    }
}

/// 受信中の TS。読み手が `bytes` を読み、閉じるのは `TunerSession` が行う。
public protocol TunerStreamHandle: AnyObject, Sendable {
    /// 割り当てられたチューナー
    var tunerID: String? { get }
    /// TS の本文
    var bytes: ByteChunks { get }
    /// 接続を閉じてチューナーを解放する
    func close()
}

extension CoaxStream: TunerStreamHandle {}

/// `TunerSession` が使う coaxd の窓口。単体試験では偽物に替える。
public protocol TunerService: Sendable {
    /// coaxd を用意する（動いていなければ起動する）
    func prepare() async throws
    /// CECH-ZD1 J のチューナー。つながっていなければ nil
    func findTuner() async throws -> CoaxTuner?
    /// 選局して受信を始める
    func open(_ request: CoaxStreamRequest) async throws -> any TunerStreamHandle
    /// 受信中のチューナーの状態（C/N・ロック・ストリームの統計）
    func status(of tunerID: String) async throws -> CoaxTunerStatus
}

/// 本物の coaxd を使う窓口。
public struct CoaxTunerService: TunerService {
    let launcher: CoaxdLauncher

    public init(launcher: CoaxdLauncher) {
        self.launcher = launcher
    }

    public func prepare() async throws {
        try await launcher.ensureRunning()
    }

    public func findTuner() async throws -> CoaxTuner? {
        try await launcher.client.findTuner()
    }

    public func open(_ request: CoaxStreamRequest) async throws -> any TunerStreamHandle {
        try await launcher.client.openStream(request)
    }

    public func status(of tunerID: String) async throws -> CoaxTunerStatus {
        try await launcher.client.tunerStatus(id: tunerID)
    }
}

/// 選局のやり直し方。
public enum TunerRetryPolicy {
    /// 続けてやり直す回数の上限。これを超えたら諦めて表示する
    public static let attempts = 3
    /// やり直す前に待つ時間（落ちた coaxd が起動し直せるまで）
    public static let delay: Duration = .milliseconds(500)
    /// 受信がこれより短く終わったら「続けて途切れた」と数える。
    /// これより長く続いた受信が終わったときは、数え直す（番組を見ている途中の一度きりの途切れ）
    public static let stableReceiving: Duration = .seconds(30)
    /// 自分でストリームを閉じてから、coaxd がチューナーを解放し終えるまでの猶予。
    /// この間の「使用中」は自分のことなので、待ってやり直す（局を続けて切り替えると、閉じた直後の選局が使用中になった）
    public static let ownReleaseGrace: Duration = .seconds(2)
    /// 自分の解放を待つ間の、やり直しの間隔
    public static let ownReleasePoll: Duration = .milliseconds(100)
}

/// `X-Coax-Priority` の値。
public enum TunerPriority {
    /// 視聴。スキャン（負の値）からはチューナーを奪える
    public static let viewing = 0
    /// チャンネルスキャン。視聴が始まればチューナーを譲る
    public static let scan = -1
    /// 番組表の巡回。視聴にもスキャンにもチューナーを譲る
    public static let guidePatrol = -2
}

/// 1 台のチューナーで 1 つの物理チャンネルを受信する状態機械。
///
/// 選局・受信・失敗・やり直しを受け持ち、受信した TS は `onStream` で読み手（TS パイプライン）へ渡す。
/// 選局を続けて切り替えたときは、最後の選局だけを生かし、途中の結果は閉じて捨てる。
@MainActor @Observable
public final class TunerSession {
    public enum State: Equatable, Sendable {
        /// 何もしていない
        case idle
        /// 選局中。`attempt` は何回目か（1 から）
        case tuning(TuningTarget, attempt: Int)
        /// 受信中
        case receiving(TuningTarget, tunerID: String?)
        /// 諦めた。利用者の操作を待つ
        case failed(TuningTarget?, TunerFailure)
    }

    public private(set) var state: State = .idle
    /// 受信中のストリーム
    public private(set) var stream: (any TunerStreamHandle)?

    /// 受信が始まるたびに呼ぶ（読み手をつなぐ）
    @ObservationIgnored public var onStream: ((any TunerStreamHandle) -> Void)?

    @ObservationIgnored private let service: any TunerService
    @ObservationIgnored private let retryDelay: Duration
    /// coaxd へ送る優先度
    @ObservationIgnored private let priority: Int
    /// 選局のたびに進める。古い選局の結果を見分ける
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var receivingSince: ContinuousClock.Instant?
    /// 最後に自分でチューナーを手放した時刻（ストリームを閉じた・選局の途中でやめた）
    @ObservationIgnored private var lastReleased: ContinuousClock.Instant?
    /// 受信が続けて短く終わった回数
    @ObservationIgnored private var quickEnds = 0

    private static let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "tuner")

    public init(service: any TunerService, retryDelay: Duration = TunerRetryPolicy.delay, priority: Int = TunerPriority.viewing) {
        self.service = service
        self.retryDelay = retryDelay
        self.priority = priority
    }

    /// 選局する。前の選局・受信はやめる
    public func tune(_ target: TuningTarget) {
        quickEnds = 0
        start(target)
    }

    /// 受信が途中で終わったことを読み手が知らせる。こちらから止めたのでなければ選局し直す
    public func streamEnded(_ ended: any TunerStreamHandle, error: (any Error)?) {
        guard ended === stream, case let .receiving(target, _) = state else { return }
        let lasted = receivingSince.map { ContinuousClock.now - $0 } ?? .zero
        quickEnds = lasted < TunerRetryPolicy.stableReceiving ? quickEnds + 1 : 1
        let reason = error.map { TunerFailure($0).advice } ?? "終わり"
        Self.logger.notice("受信が途中で終わった（\(lasted.formatted(.units(allowed: [.seconds])), privacy: .public)・\(reason, privacy: .public)）")
        guard quickEnds <= TunerRetryPolicy.attempts else {
            stop()
            state = .failed(target, .other(detail: "受信が続けて途切れました（\(reason)）"))
            return
        }
        start(target)
    }

    /// 同じ局を選局し直す（放送に追いつくため）。失敗の回数には数えない
    public func retune() {
        guard case let .receiving(target, _) = state else { return }
        Self.logger.notice("放送に追いつくため選局し直す")
        start(target)
    }

    /// 受信の側で続けられない失敗が起きた。受信をやめて表示する
    public func giveUp(_ failure: TunerFailure) {
        let target: TuningTarget? = switch state {
        case let .tuning(target, _), let .receiving(target, _): target
        case let .failed(target, _): target
        case .idle: nil
        }
        stop()
        state = .failed(target, failure)
    }

    /// 受信をやめてチューナーを解放する
    public func stop() {
        generation += 1
        work?.cancel()
        work = nil
        closeStream()
        state = .idle
    }

    /// 受信中のチューナーの状態を coaxd に尋ねる。受信していなければ nil
    public func readSignal() async throws -> CoaxTunerStatus? {
        guard case let .receiving(_, tunerID?) = state else { return nil }
        return try await service.status(of: tunerID)
    }

    /// 今の選局が終わる（受信に入るか諦める）まで待つ
    public func settle() async {
        await work?.value
    }

    // MARK: - 下請け

    private func start(_ target: TuningTarget) {
        if case .tuning = state {
            // 選局の途中でやめる。その要求が coaxd でチューナーを押さえていることがある
            lastReleased = .now
        }
        generation += 1
        let current = generation
        work?.cancel()
        closeStream()
        state = .tuning(target, attempt: 1)
        work = Task { [weak self] in
            await self?.run(target, generation: current)
        }
    }

    private func run(_ target: TuningTarget, generation current: Int) async {
        var attempt = 1
        while true {
            state = .tuning(target, attempt: attempt)
            do {
                let handle = try await open(target)
                guard current == generation else {
                    // 待っている間に別の選局が始まった
                    handle.close()
                    lastReleased = .now
                    return
                }
                stream = handle
                receivingSince = .now
                state = .receiving(target, tunerID: handle.tunerID)
                Self.logger.info("受信を始めた（\(target.frequency, privacy: .public) Hz・\(attempt, privacy: .public) 回目）")
                onStream?(handle)
                return
            } catch {
                guard current == generation else { return }
                let failure = TunerFailure(error)
                if failure == .busy, let released = lastReleased, ContinuousClock.now - released < TunerRetryPolicy.ownReleaseGrace {
                    // 閉じたばかりの自分のストリームがまだ解放されていない。回数に数えずに待つ
                    try? await Task.sleep(for: TunerRetryPolicy.ownReleasePoll)
                    guard current == generation else { return }
                    continue
                }
                Self.logger.error("選局に失敗した（\(attempt, privacy: .public) 回目）: \(failure.title, privacy: .public) \(failure.advice, privacy: .public)")
                guard failure.isWorthRetrying, attempt < TunerRetryPolicy.attempts else {
                    state = .failed(target, failure)
                    return
                }
                attempt += 1
                try? await Task.sleep(for: retryDelay)
                guard current == generation else { return }
            }
        }
    }

    private func open(_ target: TuningTarget) async throws -> any TunerStreamHandle {
        try await service.prepare()
        guard let tuner = try await service.findTuner() else {
            throw TunerFailure.notConnected
        }
        let request = CoaxStreamRequest(system: target.system, frequency: target.frequency,
                                        tunerID: tuner.id, priority: priority)
        return try await service.open(request)
    }

    private func closeStream() {
        if let stream {
            stream.close()
            lastReleased = .now
        }
        stream = nil
        receivingSince = nil
    }
}
