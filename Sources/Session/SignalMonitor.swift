import Foundation
import Observation

/// 受信状態を取る間隔。
public enum SignalTiming {
    /// coaxd に尋ねる間隔。アンテナの向きを直しながら見られる速さで、coaxd の負担にならない程度
    public static let interval: Duration = .seconds(1)
}

/// ある時点で読んだ受信の数値。
public struct SignalReading: Sendable, Equatable {
    public var locked: Bool?
    /// C/N（dB）
    public var cnr: Double?
    /// 信号の強さ（dBm）
    public var strength: Double?
    /// coaxd がこのストリームで送ったバイト数（選局してからの累計）
    public var bytes: Int?
    /// 読み出しが追いつかず coaxd が捨てた数
    public var dropped: Int?
    /// 受信した TS の continuity_counter の不連続（coaxd が数えた。選局してからの累計）
    public var inputDiscontinuities: Int?
    /// 訂正しきれなかったパケット（電波が弱い）
    public var errors: Int?
    /// 外部フィルタの後で数えた不連続
    public var outputDiscontinuities: Int?
    /// 読んだ時刻
    public var at: ContinuousClock.Instant

    public init(status: CoaxTunerStatus, output: LiveTSPipeline.OutputStatistics?, at: ContinuousClock.Instant) {
        locked = status.locked
        cnr = status.cnr
        strength = status.strength
        bytes = status.stream?.bytes
        dropped = status.dropped
        inputDiscontinuities = status.stream?.discontinuities
        // coaxd は errors が 0 のとき項目ごと省く（omitempty）。ストリームの統計があって errors が無ければ 0
        errors = status.stream.map { $0.errors ?? 0 }
        outputDiscontinuities = output?.discontinuities
        self.at = at
    }
}

/// 画面に出す受信状態。
public struct SignalStatus: Sendable, Equatable {
    public var locked: Bool?
    public var cnr: Double?
    public var strength: Double?
    /// 直前に読んだときからのビットレート（Mbps）。初めて読んだとき・選局し直した直後は nil
    public var bitrateMbps: Double?
    public var dropped: Int?
    public var inputDiscontinuities: Int?
    public var errors: Int?
    public var outputDiscontinuities: Int?

    /// 今と直前の読みから作る。バイト数が減っていたら、選局し直してストリームが替わったとみなしてビットレートを出さない
    public init(current: SignalReading, previous: SignalReading?) {
        locked = current.locked
        cnr = current.cnr
        strength = current.strength
        dropped = current.dropped
        inputDiscontinuities = current.inputDiscontinuities
        errors = current.errors
        outputDiscontinuities = current.outputDiscontinuities
        if let previous, let now = current.bytes, let before = previous.bytes, now >= before {
            let elapsed = (current.at - previous.at).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            bitrateMbps = seconds > 0 ? Double(now - before) * 8 / seconds / 1_000_000 : nil
        }
    }
}

/// 受信状態を一定の間隔で coaxd に尋ねる。
///
/// 画面に受信状態を出している間だけ `run()` を回す（出していない間に coaxd へ尋ね続けない）。
@MainActor @Observable
public final class SignalMonitor {
    /// 今の受信状態。受信していない・尋ねられなければ nil
    public private(set) var status: SignalStatus?

    @ObservationIgnored private let reception: Reception
    @ObservationIgnored private var previous: SignalReading?

    public init(reception: Reception) {
        self.reception = reception
    }

    /// 取り消されるまで尋ね続ける
    public func run() async {
        while !Task.isCancelled {
            await sample()
            try? await Task.sleep(for: SignalTiming.interval)
        }
        previous = nil
    }

    /// 1 回尋ねる
    public func sample() async {
        guard let tunerStatus = try? await reception.tuner.readSignal() else {
            status = nil
            previous = nil
            return
        }
        let reading = SignalReading(status: tunerStatus, output: reception.outputStatistics, at: .now)
        status = SignalStatus(current: reading, previous: previous)
        previous = reading
    }
}
