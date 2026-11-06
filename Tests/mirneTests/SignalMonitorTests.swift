import Foundation
import Testing

private func tunerStatus(bytes: Int?, cnr: Double = 25.2) -> CoaxTunerStatus {
    let stream = bytes.map {
        CoaxStreamStatistics(format: "ts", bytes: $0, packets: $0 / TSPacket.size, skipped: 0, syncLosses: 0,
                             discontinuities: 2, nulls: 0, errors: 1, scrambled: 0)
    }
    return CoaxTunerStatus(id: "cech-zd1j:p1-1:0", leased: true, priority: 0, locked: true, cnr: cnr, strength: -45,
                           dropped: 0, stream: stream)
}

@Suite("SignalStatus（受信状態の数値）")
struct SignalStatusTests {
    private let start = ContinuousClock.now

    @Test("直前の読みとのバイト数の差からビットレートを出す")
    func bitrate() {
        let before = SignalReading(status: tunerStatus(bytes: 1_000_000), output: nil, at: start)
        let after = SignalReading(status: tunerStatus(bytes: 3_000_000), output: nil, at: start + .seconds(1))
        let status = SignalStatus(current: after, previous: before)
        #expect(status.bitrateMbps == 16)
        #expect(status.cnr == 25.2)
        #expect(status.locked == true)
        #expect(status.errors == 1)
        #expect(status.inputDiscontinuities == 2)
    }

    @Test("coaxd が省いた errors は 0、ストリームの統計が無ければ不明")
    func omittedErrorsAreZero() {
        var status = tunerStatus(bytes: 1_000)
        status = CoaxTunerStatus(id: status.id, leased: true, priority: 0, locked: true, cnr: 20, strength: nil, dropped: 0,
                                 stream: CoaxStreamStatistics(format: "ts", bytes: 1_000, packets: 5, skipped: 0, syncLosses: 0,
                                                              discontinuities: 0, nulls: 0, errors: nil, scrambled: nil))
        #expect(SignalReading(status: status, output: nil, at: start).errors == 0)
        let noStream = CoaxTunerStatus(id: status.id, leased: true, priority: 0, locked: true, cnr: 20, strength: nil, dropped: 0, stream: nil)
        #expect(SignalReading(status: noStream, output: nil, at: start).errors == nil)
    }

    @Test("初めて読んだとき・バイト数が減った（ストリームが替わった）ときはビットレートを出さない")
    func noBitrateWithoutComparableReading() {
        let first = SignalReading(status: tunerStatus(bytes: 5_000_000), output: nil, at: start)
        #expect(SignalStatus(current: first, previous: nil).bitrateMbps == nil)
        let retuned = SignalReading(status: tunerStatus(bytes: 100_000), output: nil, at: start + .seconds(1))
        #expect(SignalStatus(current: retuned, previous: first).bitrateMbps == nil)
    }
}

@Suite("SignalMonitor")
@MainActor
struct SignalMonitorTests {
    @Test("受信中はチューナーの状態を尋ね、受信していなければ nil")
    func samplesOnlyWhileReceiving() async {
        let service = FakeTunerService()
        service.tunerStatus = tunerStatus(bytes: 1_000_000, cnr: 18.5)
        let tuner = TunerSession(service: service, retryDelay: .milliseconds(1))
        let reception = Reception(tuner: tuner, coax: nil)
        let monitor = SignalMonitor(reception: reception)

        await monitor.sample()
        #expect(monitor.status == nil)
        #expect(service.statusRequests.isEmpty)

        reception.tune(TuningTarget(frequency: 473_142_857))
        await tuner.settle()
        await monitor.sample()
        #expect(monitor.status?.cnr == 18.5)
        #expect(service.statusRequests == ["cech-zd1j:p1-1:0"])

        reception.stop()
        await monitor.sample()
        #expect(monitor.status == nil)
    }
}
