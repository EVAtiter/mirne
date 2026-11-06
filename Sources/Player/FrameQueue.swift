import CoreMedia
import Foundation

/// 復号済みのフレームを表示時刻の順に並べて持つ。
///
/// VideoToolbox は MPEG-2 を復号順に返す（B ピクチャが前に来ない）ので、ここで表示順に並べ替える
/// （実測: 30 秒の素材で 298 箇所が表示順と逆）。
public final class FrameQueue: @unchecked Sendable {
    /// 持っておく上限。これを超えたら古いものから捨てる（描画が止まったときにメモリが増え続けないように）
    static let capacity = 30
    /// 一度も表示していないフレームを、次のフレームの時刻を過ぎてもこれだけ（フィールドの数）までは捨てずに出す。
    /// そのぶん映像がその 1 回だけ遅れる（1 フィールド = 約 16.7 ms。A/V のずれの基準 ±40 ms に収まる）
    static let unshownGraceFields: Int64 = 1

    private let lock = NSLock()
    private var frames: [DecodedFrame] = []
    /// 直前に表示へ渡したフレーム（これを捨てても「表示しなかった」には数えない）
    private var presentedPTS: Int64?
    /// 一度も表示されないまま、時刻を過ぎて捨てたフレーム
    public private(set) var lateDrops = 0
    /// 上限を超えて捨てたフレーム
    public private(set) var overflowDrops = 0

    public init() {}

    public func push(_ frame: DecodedFrame) {
        lock.lock()
        defer { lock.unlock() }
        let index = frames.firstIndex { $0.pts > frame.pts } ?? frames.endIndex
        frames.insert(frame, at: index)
        if frames.count > Self.capacity {
            frames.removeFirst()
            overflowDrops += 1
        }
    }

    /// 時刻 `time`（90 kHz）に表示すべきフレーム。それより前のフレームは捨てる。
    ///
    /// ただし、直前のフレームを一度も表示していず、遅れが `unshownGraceFields` フィールド以内なら、そちらを先に出す。
    /// 1 フレーム（33.37 ms）は 60 Hz の 2 回ぶん（33.3 ms）とほぼ同じなので、描画の間隔や描いてから出るまでの
    /// 見込みが少し揺れただけで、一度も出さずに捨てるフレームが出ていた（30 分の再生で 482 枚・約 0.9%）
    public func frame(at time: Int64) -> DecodedFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard var index = frames.lastIndex(where: { $0.pts <= time }) else { return nil }
        if index > 0 {
            let skipped = frames[index - 1]
            let grace = MPEG2FrameRate.frameDuration90k(code: skipped.sequence.frameRateCode) / 2 * Self.unshownGraceFields
            if skipped.pts != presentedPTS, time - frames[index].pts < grace {
                index -= 1
            }
        }
        if index > 0 {
            lateDrops += frames[0..<index].filter { $0.pts != presentedPTS }.count
            frames.removeFirst(index)
        }
        presentedPTS = frames.first?.pts
        return frames.first
    }

    /// 時刻 `pts` より後の、最初のフレーム（取り除かない。動き適応のデインターレースで次のフレームを見る）
    public func frame(after pts: Int64) -> DecodedFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frames.first { $0.pts > pts }
    }

    /// 一番早いフレームの時刻
    public var earliestPTS: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return frames.first?.pts
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        presentedPTS = nil
        frames.removeAll()
    }
}
