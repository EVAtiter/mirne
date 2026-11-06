import Foundation

/// 利用者によるチャンネル一覧の編集。局（物理チャンネル）の単位で、並び・隠す・名前の上書きを持つ。
///
/// スキャンの結果（`ChannelList`）とは別に保存し、表示するときに当てる。局はネットワーク ID と TS ID で見分けるので、
/// スキャンし直しても編集は残る（周波数で見分けると、中継局が変わったときに外れる）
public struct ChannelEdits: Codable, Sendable, Equatable {
    /// 利用者が並べた局の順（`PhysicalChannel.stationKey`）。ここに無い局（スキャンで新しく見つかったなど）は後ろに既定の順で続く
    public var order: [String]
    /// 隠した局
    public var hidden: Set<String>
    /// 局の行に出す名前の上書き（主のサービスの名前を替える）
    public var names: [String: String]

    public init(order: [String] = [], hidden: Set<String> = [], names: [String: String] = [:]) {
        self.order = order
        self.hidden = hidden
        self.names = names
    }

    /// 何も編集していないか
    public var isEmpty: Bool { order.isEmpty && hidden.isEmpty && names.isEmpty }
}

extension PhysicalChannel {
    /// 局を見分ける鍵（ネットワーク ID と TS ID）。編集の保存に使う
    public var stationKey: String { "\(originalNetworkID)-\(transportStreamID)" }
}

extension ChannelList {
    /// 編集を当てた局の一覧（主のサービス・隠した局も含む）。並びは利用者の順、続いて既定の順。設定の表に使う
    public func stations(with edits: ChannelEdits) -> [Entry] {
        let entries = lineup.map { renamed($0, with: edits) }
        let rank = Dictionary(edits.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.enumerated().sorted { left, right in
            let l = rank[left.element.channel.stationKey], r = rank[right.element.channel.stationKey]
            switch (l, r) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return left.offset < right.offset
            }
        }.map(\.element)
    }

    /// 編集を当てた一覧（サイドバー・↑↓・数字キー）。隠した局を除く
    public func lineup(with edits: ChannelEdits) -> [Entry] {
        stations(with: edits).filter { !edits.hidden.contains($0.channel.stationKey) }
    }

    /// 編集を当てた、同じ物理チャンネルのサービス（主の名前だけ上書きする）
    public func subServices(of channel: PhysicalChannel, with edits: ChannelEdits) -> [Entry] {
        subServices(of: channel).map { renamed($0, with: edits) }
    }

    /// 編集を当てた、出すサービスすべて（前回の局を探すのに使う。隠した局も含む）
    public func allServices(with edits: ChannelEdits) -> [Entry] {
        allServices.map { renamed($0, with: edits) }
    }

    /// 主のサービスなら、局の名前の上書きを当てる
    private func renamed(_ entry: Entry, with edits: ChannelEdits) -> Entry {
        guard entry.branch == 1, let name = edits.names[entry.channel.stationKey], !name.isEmpty else { return entry }
        var service = entry.service
        service.name = name
        return Entry(channel: entry.channel, service: service, branch: entry.branch)
    }
}
