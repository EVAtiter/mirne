import Foundation
import Observation
import os

/// 放送の時刻（TOT・TDT）と、それを受け取った Mac の時刻。
public struct BroadcastClock: Sendable, Equatable {
    /// 放送が送ってきた時刻（1 秒単位）
    public var broadcastTime: Date
    /// それを受け取った Mac の時刻
    public var receivedAt: Date

    /// 放送の時刻 − Mac の時刻（秒）。正なら Mac の時計が遅れている。
    /// 放送の時刻は 1 秒単位で、受け取るまでの遅れも含むので、±1 秒ほどの幅がある
    public var offset: TimeInterval { broadcastTime.timeIntervalSince(receivedAt) }

    /// Mac の時刻 `date` のときの放送の時刻
    public func broadcastTime(at date: Date) -> Date {
        date.addingTimeInterval(offset)
    }
}

/// 受信中の TS から読んだ番組情報。
///
/// 現在・次の番組は自 TS の EIT[p/f]、番組表は自 TS の EIT[schedule] から作る。他 TS の EIT（地上波ではまず来ない）は使わない。
/// セクションは版が変わるたびに丸ごと置き換える（番組の時間が動くと、別のセクションへ移ることがあるため）。
/// 選局し直したら `begin()` で空にし、前の TS から遅れて届いた分は `generation` で見分けて捨てる。
@MainActor @Observable
public final class BroadcastInformation {
    private static let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "epg")
    /// サービスの現在・次の番組
    public struct PresentFollowing: Sendable, Equatable {
        public var present: BroadcastEvent?
        public var following: BroadcastEvent?
    }

    /// サービス（番組番号）ごとの現在・次の番組
    public private(set) var presentFollowing: [UInt16: PresentFollowing] = [:]
    /// 放送の時刻。TOT か TDT が届くまで nil
    public private(set) var clock: BroadcastClock?
    /// 番組表のセクション（EPGStore へ保存する）
    @ObservationIgnored private var scheduleSections: [ScheduleKey: EITSection] = [:]
    /// 番組表が変わった回数（画面が読み直す合図）
    public private(set) var scheduleRevision = 0
    /// 選局し直した回数
    public private(set) var generation = 0
    /// 番組表のセクションが届いたら呼ぶ（`EPGStore` へ保存する）。引数は届いたセクションと Mac の時刻
    @ObservationIgnored public var onSchedule: (([EITSection], Date) -> Void)?

    private struct ScheduleKey: Hashable {
        var tableID: UInt8
        var serviceID: UInt16
        var sectionNumber: UInt8
    }

    public init() {}

    /// 新しい TS を読み始める。今までの番組情報は捨て、返した値を `apply` に渡す
    public func begin() -> Int {
        generation += 1
        presentFollowing = [:]
        clock = nil
        scheduleSections = [:]
        scheduleRevision += 1
        return generation
    }

    /// `SIReader` が返したものを取り込む。`receivedAt` はそれを読んだ Mac の時刻
    public func apply(_ items: [SIReader.Item], receivedAt: Date, generation: Int) {
        guard generation == self.generation else { return }
        var scheduleSections: [EITSection] = []
        for item in items {
            switch item {
            case let .time(time):
                clock = BroadcastClock(broadcastTime: time, receivedAt: receivedAt)
            case let .eventSection(section) where section.isPresentFollowing:
                var entry = presentFollowing[section.serviceID] ?? PresentFollowing()
                switch section.sectionNumber {
                case 0:
                    let present = section.events.first
                    // 番組の境目の記録（実放送の確認で、境目を越えた回数を数える）。選局し直した直後の 1 回目は境目ではない
                    if let previous = entry.present, let present, previous.eventID != present.eventID {
                        Self.logger.notice("番組が替わった: サービス \(section.serviceID, privacy: .public)・番組 \(previous.eventID, privacy: .public) → \(present.eventID, privacy: .public)")
                    }
                    entry.present = present
                case 1: entry.following = section.events.first
                default: continue
                }
                presentFollowing[section.serviceID] = entry
            case let .eventSection(section) where section.isSchedule:
                let key = ScheduleKey(tableID: section.tableID, serviceID: section.serviceID, sectionNumber: section.sectionNumber)
                self.scheduleSections[key] = section
                scheduleSections.append(section)
            case .eventSection:
                // 他 TS の EIT は使わない
                continue
            }
        }
        if !scheduleSections.isEmpty {
            pruneSchedule(before: clock?.broadcastTime(at: receivedAt) ?? receivedAt)
            scheduleRevision += 1
            onSchedule?(scheduleSections, receivedAt)
        }
    }

    /// サービスの番組表（開始時刻の順）。同じ番組が 2 つのセクションに一時的に載っていても 1 つにする
    public func schedule(of serviceID: UInt16) -> [BroadcastEvent] {
        var events: [UInt16: BroadcastEvent] = [:]
        for (key, section) in scheduleSections where key.serviceID == serviceID {
            for event in section.events {
                events[event.eventID] = event
            }
        }
        return events.values.sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
    }

    /// 番組表を持っているサービス
    public var scheduledServices: [UInt16] {
        Set(scheduleSections.keys.map(\.serviceID)).sorted()
    }

    /// 終わった番組だけのセクションを捨てる（メモリが増え続けないように）
    private func pruneSchedule(before date: Date) {
        scheduleSections = scheduleSections.filter { _, section in
            section.events.isEmpty || section.events.contains { ($0.end ?? .distantFuture) > date }
        }
    }
}
