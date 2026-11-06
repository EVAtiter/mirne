import Foundation
import Testing

/// PCR だけを載せた TS パケット（アダプテーションフィールドのみ）
private func pcrPacket(pid: UInt16 = 0x0100, base: Int64, discontinuity: Bool = false) -> Data {
    var packet = [UInt8](repeating: 0xFF, count: TSPacket.size)
    packet[0] = TSPacket.syncByte
    packet[1] = UInt8(pid >> 8) & 0x1F
    packet[2] = UInt8(pid & 0xFF)
    packet[3] = 0x20  // アダプテーションフィールドのみ・スクランブルなし
    packet[4] = 183
    packet[5] = 0x10 | (discontinuity ? 0x80 : 0)
    packet[6] = UInt8((base >> 25) & 0xFF)
    packet[7] = UInt8((base >> 17) & 0xFF)
    packet[8] = UInt8((base >> 9) & 0xFF)
    packet[9] = UInt8((base >> 1) & 0xFF)
    packet[10] = UInt8((base & 1) << 7) | 0x7E
    packet[11] = 0
    return Data(packet)
}

@Suite("PCR の読み取り")
struct PCRReadingTests {
    @Test("最初に PCR を見つけた PID の値を読み、不連続の印を数える")
    func readsFirstPCRPID() {
        var counter = TSPacketCounter()
        counter.feed(pcrPacket(pid: 0x0101, base: 1_234_567))
        counter.feed(pcrPacket(pid: 0x0102, base: 9_999_999))
        #expect(counter.pcrPID == 0x0101)
        #expect(counter.lastPCR == 1_234_567)
        counter.feed(pcrPacket(pid: 0x0101, base: (1 << 33) - 1, discontinuity: true))
        #expect(counter.lastPCR == (1 << 33) - 1)
        #expect(counter.pcrDiscontinuities == 1)
    }
}

@Suite("放送からの遅れ")
struct BroadcastLagMonitorTests {
    let start = ContinuousClock.now
    let second: Int64 = 90_000

    @Test("PCR と実時間が同じ速さなら遅れは 0")
    func noLagWhenInStep() {
        var monitor = BroadcastLagMonitor()
        for index in 0...10 {
            monitor.observe(pcr: Int64(index) * second, discontinuities: 0, at: start + .seconds(index))
        }
        #expect(monitor.lag == .zero)
    }

    @Test("読むのが遅れると、実時間と PCR の進みの差だけ遅れる")
    func lagGrowsWhenReaderIsSlow() {
        var monitor = BroadcastLagMonitor()
        monitor.observe(pcr: 0, discontinuities: 0, at: start)
        // 10 秒たって 6 秒ぶんしか読めていない
        let lag = monitor.observe(pcr: 6 * second, discontinuities: 0, at: start + .seconds(10))
        #expect(lag == .seconds(4))
        #expect(lag > BroadcastLagMonitor.catchUpThreshold)
    }

    @Test("PCR の不連続では、遅れを保ったまま基準を取り直す")
    func keepsLagAcrossDiscontinuity() {
        var monitor = BroadcastLagMonitor()
        monitor.observe(pcr: 100 * second, discontinuities: 0, at: start)
        monitor.observe(pcr: 102 * second, discontinuities: 0, at: start + .seconds(4))  // 2 秒遅れ
        // 印付きで 0 へ戻る
        #expect(monitor.observe(pcr: 0, discontinuities: 1, at: start + .seconds(5)) == .seconds(2))
        #expect(monitor.observe(pcr: 1 * second, discontinuities: 1, at: start + .seconds(6)) == .seconds(2))
        // 印なしで大きく戻る
        monitor.observe(pcr: 50 * second, discontinuities: 1, at: start + .seconds(7))
        #expect(monitor.lag == .seconds(2))
    }

    @Test("溜まっていたぶんを読んで追いつけば、遅れは減る")
    func lagShrinksWhenCatchingUp() {
        var monitor = BroadcastLagMonitor()
        monitor.observe(pcr: 0, discontinuities: 0, at: start)
        monitor.observe(pcr: 1 * second, discontinuities: 0, at: start + .seconds(3))  // 2 秒遅れ
        let lag = monitor.observe(pcr: 3 * second + second / 2, discontinuities: 0, at: start + .milliseconds(3_500))
        #expect(lag == .zero)
    }

    @Test("33 ビットの一周をまたいでも続けて測れる")
    func handlesWrap() {
        var monitor = BroadcastLagMonitor()
        let wrap: Int64 = 1 << 33
        monitor.observe(pcr: wrap - second, discontinuities: 0, at: start)
        let lag = monitor.observe(pcr: second, discontinuities: 0, at: start + .seconds(5))
        #expect(lag == .seconds(3))
    }
}

/// いつまでも何も返さず、閉じられたら終わる受信
private final class SilentInput: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Data?, Never>?
    private var closed = false

    var bytes: ByteChunks {
        ByteChunks { [self] in
            await withCheckedContinuation { continuation in
                let finished = lock.withLock {
                    if closed { return true }
                    waiting = continuation
                    return false
                }
                if finished { continuation.resume(returning: nil) }
            }
        }
    }

    func close() {
        let continuation = lock.withLock {
            closed = true
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume(returning: nil)
    }
}

/// 決まった切れ端を返し、その後は黙る受信
private func followed(_ queue: Queue, by input: SilentInput) -> ByteChunks {
    ByteChunks {
        if let piece = queue.pop() { return piece }
        return try await input.bytes.produce()
    }
}

/// 決まった切れ端を返して終わる受信
private func chunks(_ pieces: [Data]) -> ByteChunks {
    let queue = Queue(pieces)
    return ByteChunks { queue.pop() }
}

private final class Queue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Data]
    init(_ items: [Data]) { self.items = items }
    func pop() -> Data? { lock.withLock { items.isEmpty ? nil : items.removeFirst() } }
}

private func readAll(_ output: ByteChunks) async throws -> Data {
    var all = Data()
    for try await data in output { all.append(data) }
    return all
}

@Suite("ライブの TS パイプライン")
struct LiveTSPipelineTests {
    let payload = (0..<50).reduce(Data()) { data, index in data + pcrPacket(base: Int64(index) * 3_000) }

    @Test("フィルタが無ければそのまま渡し、こちらから止めたら終わりを返す")
    func passesThroughAndStops() async throws {
        let input = SilentInput()
        let first = payload
        let source = Queue([first])
        let pipeline = LiveTSPipeline(input: followed(source, by: input),
                                      closeInput: { input.close() }, filter: nil) { _ in }
        var iterator = pipeline.output.makeAsyncIterator()
        #expect(try await iterator.next() == first)
        await pipeline.stop()
        #expect(try await iterator.next() == nil)
    }

    @Test("止めていないのに受信が終わったら失敗を投げる")
    func reportsUnexpectedEnd() async {
        let pipeline = LiveTSPipeline(input: chunks([payload]), closeInput: {}, filter: nil) { _ in }
        await #expect(throws: LiveTSPipelineError.endedUnexpectedly(detail: "")) {
            _ = try await readAll(pipeline.output)
        }
    }

    @Test("出力が来なければ止まったとみなし、受信を閉じる")
    func detectsStall() async {
        let input = SilentInput()
        let pipeline = LiveTSPipeline(input: input.bytes, closeInput: { input.close() }, filter: nil,
                                      stallTimeout: .milliseconds(300)) { _ in }
        let started = ContinuousClock.now
        await #expect(throws: LiveTSPipelineError.stalled) {
            _ = try await readAll(pipeline.output)
        }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("外部フィルタを通しても中身は変わらず、止めるとフィルタが終わる")
    func passesThroughFilter() async throws {
        let filter = try ExternalFilter.start(ExternalFilterCommand(executable: "/bin/cat"))
        let input = SilentInput()
        let source = Queue([payload])
        let pipeline = LiveTSPipeline(input: followed(source, by: input),
                                      closeInput: { input.close() }, filter: filter) { _ in }
        var received = Data()
        var iterator = pipeline.output.makeAsyncIterator()
        while received.count < payload.count, let data = try await iterator.next() {
            received.append(data)
        }
        #expect(received == payload)
        await pipeline.stop()
        #expect(filter.status != nil)
    }

    @Test("フィルタを止めると、シェルから起動した子プロセスも残らない")
    func terminatesProcessGroup() async throws {
        let marker = "61.25"
        let filter = try ExternalFilter.start(ExternalFilterCommand(executable: "/bin/sh",
                                                                    arguments: ["-c", "sleep \(marker) & wait"]))
        try await Task.sleep(for: .milliseconds(200))
        #expect(processCount(matching: "^sleep \(marker)") == 1)
        await filter.terminate()
        #expect(filter.status != nil)
        #expect(processCount(matching: "^sleep \(marker)") == 0)
    }

    @Test("スクランブルされたままなら知らせる")
    func reportsScrambled() async throws {
        var scrambled = pcrPacket(base: 0)
        scrambled[3] = 0x90  // スクランブルあり・ペイロードのみ
        let events = EventLog()
        let input = SilentInput()
        // 1 秒の区間を 3 つまたぐように、少しずつ返す
        let pieces = Queue(Array(repeating: scrambled, count: 40))
        let pipeline = LiveTSPipeline(input: ByteChunks {
            if let piece = pieces.pop() {
                try? await Task.sleep(for: .milliseconds(100))
                return piece
            }
            return try await input.bytes.produce()
        }, closeInput: { input.close() }, filter: nil) { events.append($0) }
        var iterator = pipeline.output.makeAsyncIterator()
        for _ in 0..<40 { _ = try await iterator.next() }
        await pipeline.stop()
        #expect(events.items.contains(.descramble(.scrambled)))
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LiveTSPipeline.Event] = []
    func append(_ event: LiveTSPipeline.Event) { lock.withLock { stored.append(event) } }
    var items: [LiveTSPipeline.Event] { lock.withLock { stored } }
}

/// コマンドラインに `pattern` を含むプロセスの数
private func processCount(matching pattern: String) -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", pattern]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return output.split(separator: "\n").count
}
