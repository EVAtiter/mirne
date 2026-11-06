import Darwin
import Foundation
import IOKit.pwr_mgt
import os

/// 起動の決まり
enum StartupTiming {
    /// 起動から映像までを測るとき、この時間たっても映像が出なければ測るのをやめる
    static let measureLimit: Duration = .seconds(15)
    /// 最初のフレームを描いたかを見る間隔
    static let measureInterval: Duration = .milliseconds(20)
}

/// ディスプレイのスリープの抑止の決まり
enum DisplaySleepTiming {
    /// 抑止するかを見直す間隔。受信の始まり・終わり・最小化への追従はこの間隔まで遅れてよい
    /// （ディスプレイが眠るまでの時間は分の単位なので、数秒の遅れは見えない）
    static let checkInterval: Duration = .seconds(2)
}

/// 視聴中にディスプレイが眠らないようにする（`IOPMAssertion`）。
/// 作った印は `update(blocking:)` で外すまで残るので、終了の前にも外す（プロセスが終われば OS も外す）
@MainActor
final class DisplaySleepBlocker {
    /// 印の名前（`pmset -g assertions` に出る）。日本語にすると `pmset` が空として出すので英字にする
    static let reason = "mirne is playing live TV"

    private var assertion: IOPMAssertionID?
    private let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "player")

    var isBlocking: Bool { assertion != nil }

    func update(blocking: Bool) {
        if blocking, assertion == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn), Self.reason as CFString, &id)
            if result == kIOReturnSuccess {
                assertion = id
                logger.info("ディスプレイのスリープを止めた")
            } else {
                logger.error("ディスプレイのスリープを止められない: \(result, privacy: .public)")
            }
        } else if !blocking, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
            logger.info("ディスプレイのスリープの抑止をやめた")
        }
    }
}

/// このプロセスが起動した時刻（起動から映像までを測る起点。`sysctl` の `p_starttime`）
enum ProcessLaunch {
    static func startDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let time = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
    }
}
