import Foundation
import IOKit
import os

/// CECH-ZD1 J の USB の識別子（coax の `internal/coaxd/usb/board/cechzd1j` と同じ）
public enum TunerUSBIdentity {
    public static let vendorID = 0x054C
    public static let productID = 0x04B2
}

/// チューナーの抜き差しへの追従の決まり
public enum HotplugTiming {
    /// 挿されてから確かめ直すまで待つ時間（USB の数え直しが終わり、coaxd が機器を開けるようになるまで）
    public static let attachSettleDelay: Duration = .seconds(2)
}

/// CECH-ZD1 J の抜き差しを IOKit で見張る。
///
/// 起動したときにつながっている分は知らせない（その後の抜き差しだけ）。知らせはメインスレッドで呼ぶ
@MainActor
public final class TunerHotplugMonitor {
    /// 挿された
    public var onAttach: (() -> Void)?
    /// 抜かれた
    public var onDetach: (() -> Void)?

    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private static let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "tuner")

    public init() {}

    /// 見張りを始める。何度呼んでも 1 回だけ
    public func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        // メニューの追跡中・ウィンドウのリサイズ中でも受け取る
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let attached: IOServiceMatchingCallback = { context, iterator in
            guard let context, TunerHotplugMonitor.drain(iterator) > 0 else { return }
            let monitor = Unmanaged<TunerHotplugMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.report(attached: true) }
        }
        let detached: IOServiceMatchingCallback = { context, iterator in
            guard let context, TunerHotplugMonitor.drain(iterator) > 0 else { return }
            let monitor = Unmanaged<TunerHotplugMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.report(attached: false) }
        }
        for (type, callback) in [(kIOFirstMatchNotification, attached), (kIOTerminatedNotification, detached)] {
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(port, type, Self.matching(), callback, context, &iterator)
            guard result == KERN_SUCCESS else {
                Self.logger.error("チューナーの抜き差しを見張れない: \(result, privacy: .public)")
                continue
            }
            // 今つながっている分を読み捨てて、次の知らせを受けられるようにする（読まないと知らせが来ない）
            _ = Self.drain(iterator)
            iterators.append(iterator)
        }
    }

    private func report(attached: Bool) {
        Self.logger.notice("チューナーが\(attached ? "挿された" : "抜かれた", privacy: .public)")
        if attached { onAttach?() } else { onDetach?() }
    }

    /// CECH-ZD1 J の USB 機器に当てはまる条件（呼ぶたびに新しく作る。`IOServiceAddMatchingNotification` が 1 つ消費する）
    private static func matching() -> CFDictionary {
        let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        matching["idVendor"] = TunerUSBIdentity.vendorID
        matching["idProduct"] = TunerUSBIdentity.productID
        return matching
    }

    /// 知らせの中の機器を読み捨てて、数を返す
    nonisolated private static func drain(_ iterator: io_iterator_t) -> Int {
        var count = 0
        while true {
            let object = IOIteratorNext(iterator)
            guard object != 0 else { return count }
            IOObjectRelease(object)
            count += 1
        }
    }
}
