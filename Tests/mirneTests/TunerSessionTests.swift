import Foundation
import Testing

/// 試験用の受信。読むと何も返さない
final class FakeStream: TunerStreamHandle, @unchecked Sendable {
    let tunerID: String?
    let bytes = ByteChunks { nil }
    private(set) var closed = false

    init(tunerID: String?) {
        self.tunerID = tunerID
    }

    func close() {
        closed = true
    }
}

/// 試験用の coaxd の窓口。失敗の順番と、選局にかかる時間を決められる
final class FakeTunerService: TunerService, @unchecked Sendable {
    private let lock = NSLock()
    /// prepare が順に投げる失敗（使い切ったら成功する）
    var prepareFailures: [any Error] = []
    var tuner: CoaxTuner? = CoaxTuner(id: "cech-zd1j:p1-1:0", index: 0, name: "ISDB-T",
                                      deliveries: ["ISDB-T"], leased: false, priority: nil)
    /// open が順に投げる失敗（使い切ったら成功する）
    var openFailures: [any Error] = []
    /// 周波数ごとの、open が戻るまでの時間（取り消しを無視して待つ）
    var openDelays: [Int: TimeInterval] = [:]

    /// status が返す状態
    var tunerStatus: CoaxTunerStatus?
    private(set) var statusRequests: [String] = []

    private(set) var prepareCount = 0
    private(set) var requests: [CoaxStreamRequest] = []
    private(set) var streams: [FakeStream] = []

    func prepare() async throws {
        let failure: (any Error)? = lock.withLock {
            prepareCount += 1
            return prepareFailures.isEmpty ? nil : prepareFailures.removeFirst()
        }
        if let failure { throw failure }
    }

    func findTuner() async throws -> CoaxTuner? {
        lock.withLock { tuner }
    }

    func open(_ request: CoaxStreamRequest) async throws -> any TunerStreamHandle {
        let (failure, delay): ((any Error)?, TimeInterval?) = lock.withLock {
            requests.append(request)
            return (openFailures.isEmpty ? nil : openFailures.removeFirst(), openDelays[request.frequency])
        }
        if let delay {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { continuation.resume() }
            }
        }
        if let failure { throw failure }
        let stream = FakeStream(tunerID: request.tunerID)
        lock.withLock { streams.append(stream) }
        return stream
    }

    func status(of tunerID: String) async throws -> CoaxTunerStatus {
        try lock.withLock {
            statusRequests.append(tunerID)
            guard let tunerStatus else { throw CoaxError.timedOut }
            return tunerStatus
        }
    }
}

private func problem(_ code: String, cnr: Double? = nil) -> CoaxError {
    let status = cnr.map { CoaxTuneStatus(tuner: nil, backend: nil, locked: false, strength: nil, cnr: $0, elapsedMilliseconds: nil) }
    return .http(status: 503, problem: CoaxProblem(code: code, message: code, reason: nil), tuneStatus: status)
}

private let channelA = TuningTarget(frequency: 473_142_857)
private let channelB = TuningTarget(frequency: 479_142_857)

@Suite("選局の失敗の種別")
struct TunerFailureTests {
    @Test("coaxd のエラーコードを、利用者がとる行動で分ける")
    func classifiesProblemCodes() {
        #expect(TunerFailure(problem("no_lock", cnr: 3.5)) == .noSignal(cnr: 3.5))
        #expect(TunerFailure(problem("no_sync")) == .noSignal(cnr: nil))
        #expect(TunerFailure(problem("tuner_busy")) == .busy)
        #expect(TunerFailure(problem("device_gone")) == .notConnected)
        #expect(TunerFailure(problem("unknown_tuner")) == .notConnected)
        if case .cannotOpen = TunerFailure(problem("no_access")) {} else { Issue.record("no_access は cannotOpen") }
        if case .daemon = TunerFailure(CoaxError.daemonUnavailable(path: "x", underlying: "y")) {} else { Issue.record("接続できないのは daemon") }
        if case .other = TunerFailure(problem("internal")) {} else { Issue.record("internal は other") }
    }

    @Test("やり直すのは coaxd の不調だけ")
    func retriesOnlyDaemonTrouble() {
        #expect(TunerFailure.daemon(detail: "").isWorthRetrying)
        #expect(!TunerFailure.noSignal(cnr: nil).isWorthRetrying)
        #expect(!TunerFailure.busy.isWorthRetrying)
        #expect(!TunerFailure.notConnected.isWorthRetrying)
    }
}

@Suite("TunerSession の状態機械")
@MainActor
struct TunerSessionTests {
    private func makeSession(_ service: FakeTunerService) -> TunerSession {
        TunerSession(service: service, retryDelay: .milliseconds(1))
    }

    @Test("見つけたチューナーを視聴の優先度で選局し、読み手へ渡す")
    func tunesAndHandsOver() async {
        let service = FakeTunerService()
        let session = makeSession(service)
        var handed: [any TunerStreamHandle] = []
        session.onStream = { handed.append($0) }

        session.tune(channelA)
        #expect(session.state == .tuning(channelA, attempt: 1))
        await session.settle()

        #expect(session.state == .receiving(channelA, tunerID: "cech-zd1j:p1-1:0"))
        #expect(service.requests.first?.tunerID == "cech-zd1j:p1-1:0")
        #expect(service.requests.first?.priority == TunerPriority.viewing)
        #expect(handed.count == 1)
    }

    @Test("チューナーが無ければ選局せずに「接続されていません」")
    func reportsMissingTuner() async {
        let service = FakeTunerService()
        service.tuner = nil
        let session = makeSession(service)
        session.tune(channelA)
        await session.settle()
        #expect(session.state == .failed(channelA, .notConnected))
        #expect(service.requests.isEmpty)
    }

    @Test("coaxd の不調はやり直して受信に入る")
    func retriesDaemonTrouble() async {
        let service = FakeTunerService()
        service.prepareFailures = [CoaxError.daemonDidNotStart(said: ""), CoaxError.timedOut]
        let session = makeSession(service)
        session.tune(channelA)
        await session.settle()
        #expect(session.state == .receiving(channelA, tunerID: "cech-zd1j:p1-1:0"))
        #expect(service.prepareCount == 3)
    }

    @Test("3 回続けて失敗したら諦める")
    func givesUpAfterThreeAttempts() async {
        let service = FakeTunerService()
        service.prepareFailures = Array(repeating: CoaxError.timedOut, count: 5)
        let session = makeSession(service)
        session.tune(channelA)
        await session.settle()
        guard case .failed(channelA, .daemon) = session.state else {
            Issue.record("daemon で諦めるはず: \(session.state)")
            return
        }
        #expect(service.prepareCount == TunerRetryPolicy.attempts)
    }

    @Test("受信できないときはやり直さない")
    func doesNotRetryNoSignal() async {
        let service = FakeTunerService()
        service.openFailures = [problem("no_lock", cnr: 2.0)]
        let session = makeSession(service)
        session.tune(channelA)
        await session.settle()
        #expect(session.state == .failed(channelA, .noSignal(cnr: 2.0)))
        #expect(service.requests.count == 1)
    }

    @Test("閉じた直後の「使用中」は自分の解放待ちなので、待ってやり直す")
    func waitsForOwnRelease() async {
        let service = FakeTunerService()
        let session = makeSession(service)
        session.tune(channelA)
        await session.settle()
        service.openFailures = [problem("tuner_busy"), problem("tuner_busy")]
        session.tune(channelB)
        await session.settle()
        #expect(session.state == .receiving(channelB, tunerID: "cech-zd1j:p1-1:0"))
        #expect(service.requests.count == 4)
    }

    @Test("選局の途中で次の局を選んだときの「使用中」も、待ってやり直す")
    func waitsForAbandonedTuning() async throws {
        let service = FakeTunerService()
        service.openDelays = [channelA.frequency: 0.3]
        let session = makeSession(service)
        session.tune(channelA)
        try await Task.sleep(for: .milliseconds(50))
        service.openFailures = [problem("tuner_busy"), problem("tuner_busy")]
        session.tune(channelB)
        await session.settle()
        #expect(session.state == .receiving(channelB, tunerID: "cech-zd1j:p1-1:0"))
    }

    @Test("自分が何も閉じていないときの「使用中」はやり直さない")
    func reportsBusyFromOthers() async {
        let service = FakeTunerService()
        service.openFailures = [problem("tuner_busy")]
        let session = makeSession(service)
        session.tune(channelA)
        await session.settle()
        #expect(session.state == .failed(channelA, .busy))
        #expect(service.requests.count == 1)
    }

    @Test("選局し直すと前の受信を閉じる")
    func closesPreviousStream() async {
        let service = FakeTunerService()
        let session = makeSession(service)
        session.tune(channelA)
        await session.settle()
        session.tune(channelB)
        await session.settle()
        #expect(service.streams.count == 2)
        #expect(service.streams[0].closed)
        #expect(!service.streams[1].closed)
        #expect(session.state == .receiving(channelB, tunerID: "cech-zd1j:p1-1:0"))
    }

    @Test("続けて選局したら、遅れて届いた前の結果は閉じて捨てる")
    func discardsStaleResult() async throws {
        let service = FakeTunerService()
        service.openDelays = [channelA.frequency: 0.2]
        let session = makeSession(service)
        session.tune(channelA)
        // A の open が戻る前に B へ切り替える
        try await Task.sleep(for: .milliseconds(50))
        session.tune(channelB)
        await session.settle()
        #expect(session.state == .receiving(channelB, tunerID: "cech-zd1j:p1-1:0"))
        // A の open が戻るのを待つ
        try await Task.sleep(for: .milliseconds(400))
        let streamA = service.streams.first { $0 !== (session.stream as AnyObject) }
        #expect(streamA?.closed == true)
        #expect(session.state == .receiving(channelB, tunerID: "cech-zd1j:p1-1:0"))
    }

    @Test("止めるとチューナーを解放して何もしない状態へ")
    func stopReleases() async {
        let service = FakeTunerService()
        let session = makeSession(service)
        session.tune(channelA)
        await session.settle()
        session.stop()
        #expect(session.state == .idle)
        #expect(service.streams[0].closed)
        #expect(session.stream == nil)
    }

    @Test("受信が途中で終わったら同じ局を選局し直す")
    func retunesAfterInterruption() async throws {
        let service = FakeTunerService()
        let session = makeSession(service)
        session.tune(channelA)
        await session.settle()
        let first = try #require(session.stream)
        session.streamEnded(first, error: CoaxError.connectionClosed)
        await session.settle()
        #expect(service.streams.count == 2)
        #expect(service.streams[0].closed)
        #expect(session.state == .receiving(channelA, tunerID: "cech-zd1j:p1-1:0"))
    }

    @Test("受信が続けて短く途切れたら、やり直しを打ち切る")
    func givesUpOnRepeatedInterruptions() async throws {
        let service = FakeTunerService()
        let session = makeSession(service)
        session.tune(channelA)
        await session.settle()
        for _ in 0..<TunerRetryPolicy.attempts {
            session.streamEnded(try #require(session.stream), error: nil)
            await session.settle()
            #expect(session.state == .receiving(channelA, tunerID: "cech-zd1j:p1-1:0"))
        }
        session.streamEnded(try #require(session.stream), error: nil)
        guard case .failed(channelA, .other) = session.state else {
            Issue.record("打ち切るはず: \(session.state)")
            return
        }
        #expect(session.stream == nil)
    }

    @Test("止めた後に届いた「終わった」の知らせは無視する")
    func ignoresEndAfterStop() async throws {
        let service = FakeTunerService()
        let session = makeSession(service)
        session.tune(channelA)
        await session.settle()
        let first = try #require(session.stream)
        session.stop()
        session.streamEnded(first, error: nil)
        #expect(session.state == .idle)
        #expect(service.requests.count == 1)
    }
}
