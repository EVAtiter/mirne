import Foundation

/// 受信が放送からどれだけ遅れているかを見張る。
///
/// 選局してからの PCR の進みと実時間の進みの差を遅れとする。読む側（再生）が遅れると、
/// coaxd から先の背圧で受信全体が放送から遅れていく（計測では 30 秒で 15〜18 秒）。
/// 遅れは「読んだ時点」で測るので、パイプラインの出口（再生が引いた時点）で呼ぶ。
public struct BroadcastLagMonitor: Sendable {
    /// これを超えたら選局し直して追いつく（既定 3 秒）
    public static let catchUpThreshold: Duration = .seconds(3)
    /// PCR がこれより戻ったら不連続とみなす（90 kHz で 1 秒）
    static let backwardJump: Int64 = 90_000
    /// PCR の進みが実時間の進みをこれより上回ったら不連続とみなす。
    /// 溜まっていたぶんを一気に読んで追いつくときも PCR は速く進むが、その量は遅れ（3 秒で選局し直す）を
    /// 超えないので、それより十分に大きくする
    static let forwardJump: Duration = .seconds(5)
    /// PCR の周期（33 ビット）
    static let pcrWrap: Int64 = 1 << 33
    static let pcrClock = 90_000.0

    /// 今の遅れ。0 より小さくはならない
    public private(set) var lag: Duration = .zero

    /// 遅れを 0 とみなした時点（PCR と実時間の組）
    private var base: (pcr: Int64, at: ContinuousClock.Instant)?
    private var previous: (pcr: Int64, at: ContinuousClock.Instant)?
    private var discontinuitiesSeen = 0

    public init() {}

    /// PCR を 1 つ見る。`discontinuities` は不連続の印を見た回数の累計（`TSPacketCounter.pcrDiscontinuities`）
    @discardableResult
    public mutating func observe(pcr raw: Int64, discontinuities: Int, at now: ContinuousClock.Instant) -> Duration {
        guard let last = previous, let start = base else {
            base = (raw, now)
            previous = (raw, now)
            discontinuitiesSeen = discontinuities
            return lag
        }
        let pcr = Self.unwrap(raw, after: last.pcr)
        let pcrDelta = pcr - last.pcr
        let ahead = Self.duration(pcrDelta) - (now - last.at)
        if discontinuities != discontinuitiesSeen || pcrDelta < -Self.backwardJump || ahead > Self.forwardJump {
            // 時計が飛んだ。遅れはそのままにして基準を取り直す
            base = (pcr, now - lag)
            discontinuitiesSeen = discontinuities
        } else {
            let measured = (now - start.at) - Self.duration(pcr - start.pcr)
            if measured < .zero {
                // 基準を取った時点より放送に近づいた。そこを新しい基準にする
                base = (pcr, now)
                lag = .zero
            } else {
                lag = measured
            }
        }
        previous = (pcr, now)
        return lag
    }

    /// 33 ビットで一周する PCR を、直前の値に近い側へ伸ばす
    static func unwrap(_ raw: Int64, after previous: Int64) -> Int64 {
        let cycle = previous - (previous % pcrWrap + pcrWrap) % pcrWrap
        var value = cycle + raw
        if value - previous > pcrWrap / 2 { value -= pcrWrap }
        if previous - value > pcrWrap / 2 { value += pcrWrap }
        return value
    }

    static func duration(_ ticks: Int64) -> Duration {
        .microseconds(Int64((Double(ticks) / pcrClock * 1_000_000).rounded()))
    }
}
