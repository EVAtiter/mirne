import Foundation

/// TS パケットの寸法。
public enum TSPacket {
    public static let size = 188
    public static let syncByte: UInt8 = 0x47
    /// スタッフィング（ヌルパケット）の PID
    public static let nullPID: UInt16 = 0x1FFF
    /// 同期を取り直すとき、同期バイトが続けて並んでいることを確かめるパケット数
    static let resyncConfirmations = 3
}

/// 届いたバイト列を TS パケットに切り分けて数える。
///
/// 受信の切れ目はパケットの境目と一致しないので、端数を持ち越す。
/// 数えるのは、外部フィルタの前後でスクランブルが解けているかを判断するための値。
public struct TSPacketCounter: Sendable {
    /// パケットとして数えたもの（ヌルパケットを含む）
    public private(set) var packets = 0
    /// ヌルパケット
    public private(set) var nulls = 0
    /// transport_scrambling_control が 0 でないもの（ヌルパケットを除く）
    public private(set) var scrambled = 0
    /// 同期が外れて取り直した回数
    public private(set) var syncLosses = 0
    /// continuity_counter が続いていなかったパケット（受信の欠落）。
    /// 数え方は coax の「ストリーム統計」と同じ: ペイロードの無いパケットはカウンタが進まない、
    /// 同じカウンタの重複は規格上許される、discontinuity_indicator が立っていれば意図した不連続
    public private(set) var discontinuities = 0
    /// PCR を読む PID。最初に PCR を見つけた PID に固定する（放送からの遅れの見張りに使う）
    public private(set) var pcrPID: UInt16?
    /// 最後に読んだ PCR（27 MHz の値を 90 kHz に丸めたもの）
    public private(set) var lastPCR: Int64?
    /// PCR の不連続の印（discontinuity_indicator）を見た回数
    public private(set) var pcrDiscontinuities = 0

    private var residue = [UInt8]()
    /// PID ごとの直前の continuity_counter（-1 はまだ見ていない）
    private var lastCounter = [Int8](repeating: -1, count: 8192)

    public init() {}

    public mutating func feed(_ data: Data) {
        residue.append(contentsOf: data)
        var offset = 0
        let count = residue.count
        while count - offset >= TSPacket.size {
            if residue[offset] != TSPacket.syncByte {
                guard let found = findSync(from: offset) else {
                    // 確かめられるだけの長さが無い。次の受信を待つ
                    break
                }
                syncLosses += 1
                offset = found
                continue
            }
            let pid = (UInt16(residue[offset + 1] & 0x1F) << 8) | UInt16(residue[offset + 2])
            packets += 1
            if pid == TSPacket.nullPID {
                nulls += 1
            } else {
                if residue[offset + 3] & 0xC0 != 0 {
                    scrambled += 1
                }
                checkContinuity(pid: Int(pid), at: offset)
                readPCR(pid: pid, at: offset)
            }
            offset += TSPacket.size
        }
        residue.removeFirst(offset)
    }

    private mutating func checkContinuity(pid: Int, at offset: Int) {
        let control = residue[offset + 3]
        let hasAdaptation = control & 0x20 != 0
        let hasPayload = control & 0x10 != 0
        let counter = Int8(control & 0x0F)
        // アダプテーションフィールドの discontinuity_indicator
        if hasAdaptation, residue[offset + 4] > 0, residue[offset + 5] & 0x80 != 0 {
            lastCounter[pid] = counter
            return
        }
        let last = lastCounter[pid]
        defer { lastCounter[pid] = counter }
        guard last >= 0 else { return }
        if !hasPayload {
            // ペイロードの無いパケットではカウンタは進まない
            if counter != last { discontinuities += 1 }
            return
        }
        if counter == last { return }  // 重複パケット
        if counter != (last + 1) & 0x0F { discontinuities += 1 }
    }

    /// アダプテーションフィールドの PCR を読む（スクランブルされていても読める）
    private mutating func readPCR(pid: UInt16, at offset: Int) {
        // transport_error_indicator の立ったパケットの PCR は信用しない
        guard residue[offset + 1] & 0x80 == 0, residue[offset + 3] & 0x20 != 0, residue[offset + 4] >= 7 else { return }
        let flags = residue[offset + 5]
        guard flags & 0x10 != 0 else { return }
        if pcrPID == nil { pcrPID = pid }
        guard pid == pcrPID else { return }
        lastPCR = (Int64(residue[offset + 6]) << 25) | (Int64(residue[offset + 7]) << 17) | (Int64(residue[offset + 8]) << 9)
            | (Int64(residue[offset + 9]) << 1) | (Int64(residue[offset + 10]) >> 7)
        if flags & 0x80 != 0 { pcrDiscontinuities += 1 }
    }

    /// 同期バイトが 188 バイトおきに続けて並ぶ位置を探す
    private func findSync(from start: Int) -> Int? {
        let needed = TSPacket.size * TSPacket.resyncConfirmations
        var position = start + 1
        while position + needed <= residue.count {
            if (0..<TSPacket.resyncConfirmations).allSatisfy({ residue[position + $0 * TSPacket.size] == TSPacket.syncByte }) {
                return position
            }
            position += 1
        }
        return nil
    }
}

/// 外部フィルタの出力がまだスクランブルされているかの判断。
///
/// 一定時間ごとの区間で数え、スクランブルされたパケットが続けて現れたら「解けていない」とする。
/// 1 区間だけで決めないのは、フィルタの立ち上がり直後に未処理のパケットが混ざることがあるため。
public struct DescrambleJudge: Sendable {
    public enum Verdict: Sendable, Equatable {
        /// まだ判断できない
        case undecided
        /// スクランブルされたパケットが無い
        case clear
        /// スクランブルが解けていない
        case scrambled
    }

    /// 1 区間の長さ
    public static let window: Duration = .seconds(1)
    /// 「解けていない」と決めるまでに続く区間の数
    public static let strikesToDecide = 3

    public private(set) var verdict = Verdict.undecided
    private var windowStart: ContinuousClock.Instant?
    private var packetsAtStart = 0
    private var scrambledAtStart = 0
    private var strikes = 0

    public init() {}

    /// カウンタの現在値を渡す。区間が終わるたびに判断を更新する
    @discardableResult
    public mutating func observe(_ counter: TSPacketCounter, at now: ContinuousClock.Instant = .now) -> Verdict {
        guard let start = windowStart else {
            begin(counter, at: now)
            return verdict
        }
        guard now - start >= Self.window else { return verdict }
        let packets = counter.packets - counter.nulls - packetsAtStart
        let scrambled = counter.scrambled - scrambledAtStart
        if scrambled > 0 {
            strikes += 1
            if strikes >= Self.strikesToDecide { verdict = .scrambled }
        } else if packets > 0 {
            strikes = 0
            verdict = .clear
        }
        begin(counter, at: now)
        return verdict
    }

    private mutating func begin(_ counter: TSPacketCounter, at now: ContinuousClock.Instant) {
        windowStart = now
        packetsAtStart = counter.packets - counter.nulls
        scrambledAtStart = counter.scrambled
    }
}
