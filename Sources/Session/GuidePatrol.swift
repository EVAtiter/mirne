import Foundation
import os

/// 番組表の巡回の決まり
public enum GuidePatrolTiming {
    /// 1 局を受信する時間（実測で、2 分半で主のサービスの 8 日分が集まった）
    public static let dwell: Duration = .seconds(150)
    /// 番組表を最後に受け取ってからこの時間たった局を回り直す
    public static let refreshAfter: TimeInterval = 6 * 60 * 60
    /// 持っている番組がこの先まで届いていれば、番組表が揃っているとみなす。2 分半受信すると 8 日分集まるので、
    /// 揃っていればこれを超える。視聴中や途中でやめた巡回で数日分しか無い局は、新しくても回る
    public static let completeHorizon: TimeInterval = 6 * 24 * 60 * 60
    /// 回る局が無いとき、次に見直すまでの間隔
    public static let idleRecheck: Duration = .seconds(10 * 60)
    /// 選局に失敗した局を飛ばしてから、次の局へ移るまでの間
    public static let failurePause: Duration = .seconds(5)
    /// チューナーが使用中（ほかの視聴が使っている・視聴が手放したばかり）で選局できなかったとき、次に試すまでの間。
    /// 使用中はその局のせいではないので、その局を「回った」にはしない
    public static let busyPause: Duration = .seconds(30)
    /// 視聴ウィンドウを閉じてから巡回を始めるまで（終了のときに閉じた窓で巡回を始めない・すぐ開き直したときに選局を繰り返さない）
    public static let startDelay: Duration = .seconds(5)
    /// 番組表を重ねて出してから巡回を始めるまで（視聴のストリームを coaxd が解放し終えるまで。
    /// `TunerRetryPolicy.ownReleaseGrace` と同じ事情だが、巡回は別のセッションなので自分の解放として待てない）
    public static let guideSheetStartDelay: Duration = .seconds(2)
}

/// 視聴していない間に、局を順に受信して番組表を集める。
///
/// 番組情報は暗号化されていないので、外部フィルタは通さずに受信した TS から SI だけを読む。
/// coaxd へは低い優先度（`TunerPriority.guidePatrol`）で要求するので、ほかのアプリの視聴が始まればチューナーを譲る。
/// 番組表を最後に受け取ってから `refreshAfter` たっておらず、先まで揃っている局（視聴中に集まった局を含む）と、
/// この巡回で `refreshAfter` の間に最後まで回った局（番組表が揃わない局で回り続けないように）は飛ばす
@MainActor
public final class GuidePatrol {
    /// いま受信している局（回っていなければ nil）
    public private(set) var current: PhysicalChannel?
    public var isRunning: Bool { work != nil }
    /// 番組表を保存するたびに呼ぶ（開いている番組表を読み直す合図）
    public var onSave: (() -> Void)?

    private let service: any TunerService
    private let store: EPGStore
    private var work: Task<Void, Never>?
    /// この巡回で回った時刻（局の鍵ごと）
    private var visited: [String: Date] = [:]
    private static let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "epg")

    public init(service: any TunerService, store: EPGStore) {
        self.service = service
        self.store = store
    }

    /// 巡回を始める。`stations` は回る局（呼ぶたびに今の一覧を返す）
    public func start(stations: @escaping @MainActor () -> [PhysicalChannel]) {
        guard work == nil else { return }
        Self.logger.notice("番組表の巡回を始める")
        work = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let list = stations()
                guard let next = self.nextStation(in: list) else {
                    Self.logger.info("番組表の巡回: 回る局が無い（\(list.count, privacy: .public) 局とも新しい）。\(GuidePatrolTiming.idleRecheck.formatted(.units(allowed: [.minutes])), privacy: .public)後に見直す")
                    try? await Task.sleep(for: GuidePatrolTiming.idleRecheck)
                    continue
                }
                await self.collect(next)
            }
        }
    }

    /// 巡回をやめ、チューナーを手放し終えるまで待つ
    public func stop() async {
        guard let work else { return }
        self.work = nil
        work.cancel()
        await work.value
        Self.logger.notice("番組表の巡回をやめた")
    }

    /// 次に回る局：番組表が古い（または無い）局のうち、いちばん古いもの
    private func nextStation(in stations: [PhysicalChannel]) -> PhysicalChannel? {
        let now = Date()
        let due = stations.compactMap { channel -> (PhysicalChannel, Date)? in
            if let visited = visited[channel.stationKey], now.timeIntervalSince(visited) < GuidePatrolTiming.refreshAfter { return nil }
            let coverage = coverage(of: channel)
            let received = coverage?.lastReceived
            let complete = coverage?.latestEnd.map { $0.timeIntervalSince(now) >= GuidePatrolTiming.completeHorizon } ?? false
            if let received, now.timeIntervalSince(received) < GuidePatrolTiming.refreshAfter, complete { return nil }
            return (channel, received ?? .distantPast)
        }
        return due.min { $0.1 < $1.1 }?.0
    }

    /// 局の主のサービスの番組表が届いた範囲（最後に受け取った時刻・最後の番組の終わり）
    private func coverage(of channel: PhysicalChannel) -> EPGCoverage? {
        guard let main = channel.services.filter(\.isVisible).min(by: { $0.serviceID < $1.serviceID }) else { return nil }
        return store.coverage(networkID: channel.originalNetworkID, transportStreamID: channel.transportStreamID,
                              serviceID: main.serviceID)
    }

    /// 1 局を `dwell` の間受信して、番組表を保存する。途中でやめたら（`stop`）すぐ手放す
    private func collect(_ channel: PhysicalChannel) async {
        current = channel
        defer { current = nil }
        Self.logger.info("番組表の巡回: \(channel.frequency, privacy: .public) Hz を受信する（番組表を最後に受け取ったのは \(self.coverage(of: channel)?.lastReceived.formatted() ?? "まだ", privacy: .public)・最後の番組の終わりは \(self.coverage(of: channel)?.latestEnd?.formatted() ?? "-", privacy: .public)）")
        let tuner = TunerSession(service: service, priority: TunerPriority.guidePatrol)
        tuner.tune(channel.tuningTarget)
        await tuner.settle()
        guard case .receiving = tuner.state, let stream = tuner.stream else {
            var busy = false
            if case let .failed(_, failure) = tuner.state {
                busy = failure == .busy
                Self.logger.notice("番組表の巡回: \(channel.frequency, privacy: .public) Hz を受信できない（\(failure.title, privacy: .public)）。\(busy ? "あとで試し直す" : "次の局へ", privacy: .public)")
            }
            tuner.stop()
            if !Task.isCancelled, !busy { visited[channel.stationKey] = Date() }
            try? await Task.sleep(for: busy ? GuidePatrolTiming.busyPause : GuidePatrolTiming.failurePause)
            return
        }
        let information = BroadcastInformation()
        let store = store
        information.onSchedule = { [weak self] sections, receivedAt in
            store.save(sections, receivedAt: receivedAt)
            self?.onSave?()
        }
        let generation = information.begin()
        let reading = Task.detached {
            let reader = SIReader()
            do {
                for try await data in stream.bytes {
                    if Task.isCancelled { break }
                    let items = reader.feed(data)
                    if !items.isEmpty {
                        let receivedAt = Date()
                        await MainActor.run { information.apply(items, receivedAt: receivedAt, generation: generation) }
                    }
                }
            } catch {
                // 受信が途切れた（視聴に譲った・抜かれた）。この局はここまで
            }
        }
        let started = ContinuousClock.now
        try? await Task.sleep(for: GuidePatrolTiming.dwell)
        tuner.stop()
        reading.cancel()
        await reading.value
        store.flush()
        // 最後まで受信した局だけ「回った」とする（途中で窓を開いて止めた局は、次の巡回でまた回る）
        let completed = !Task.isCancelled
        if completed { visited[channel.stationKey] = Date() }
        let events = information.scheduledServices.reduce(0) { $0 + information.schedule(of: $1).count }
        Self.logger.notice("番組表の巡回: \(channel.frequency, privacy: .public) Hz を \((ContinuousClock.now - started).formatted(.units(allowed: [.seconds])), privacy: .public)受信し、番組 \(events, privacy: .public) 件\(completed ? "" : "（途中でやめた）", privacy: .public)")
    }
}
