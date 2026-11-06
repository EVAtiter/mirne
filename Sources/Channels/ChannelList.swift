import Foundation

/// サービスの種別（service_type。ARIB STD-B10）。
public enum ServiceType {
    /// デジタル TV サービス
    public static let television = 0x01
    /// デジタル音声サービス
    public static let audio = 0x02
    /// 臨時映像サービス
    public static let temporaryVideo = 0xA1
    /// データサービス（地上波ではワンセグに使われる）
    public static let data = 0xC0

    /// 一覧に既定で出す種別。臨時・ワンセグ・データ専用・エンジニアリングなどは隠す
    public static func isShownByDefault(_ type: Int) -> Bool {
        type == television || type == audio
    }
}

/// 1 つのサービス。
public struct ChannelService: Codable, Sendable, Equatable, Identifiable {
    /// service_id（番組番号）
    public var serviceID: Int
    public var name: String
    /// service_type
    public var type: Int
    /// ワンセグ（部分受信）か
    public var isPartialReception: Bool
    /// 一覧に出すか。スキャンでは種別から決め、利用者が変えられる
    public var isVisible: Bool

    public var id: Int { serviceID }

    public init(serviceID: Int, name: String, type: Int, isPartialReception: Bool, isVisible: Bool? = nil) {
        self.serviceID = serviceID
        self.name = name
        self.type = type
        self.isPartialReception = isPartialReception
        self.isVisible = isVisible ?? (ServiceType.isShownByDefault(type) && !isPartialReception)
    }
}

/// 1 つの物理チャンネル。
public struct PhysicalChannel: Codable, Sendable, Equatable, Identifiable {
    /// スキャンでの名前（地上波は物理チャンネルの番号）
    public var name: String
    /// 周波数（Hz）
    public var frequency: Int
    /// 伝送方式（`ISDBT`）
    public var system: String
    public var transportStreamID: Int
    public var originalNetworkID: Int
    /// NIT のリモコンキー ID（1〜12）。無ければ nil
    public var remoteControlKey: Int?
    /// NIT の TS 名（局名）
    public var tsName: String?
    public var services: [ChannelService]

    public var id: Int { frequency }

    public var tuningTarget: TuningTarget { TuningTarget(frequency: frequency, system: system) }
}

/// 保存するチャンネル一覧。
public struct ChannelList: Codable, Sendable, Equatable {
    /// 保存形式の版。形を変えたら上げる
    public static let currentFormat = 1

    public var format = ChannelList.currentFormat
    /// スキャンした日時
    public var scannedAt: Date
    public var channels: [PhysicalChannel]

    public init(scannedAt: Date, channels: [PhysicalChannel]) {
        self.scannedAt = scannedAt
        self.channels = channels
    }

    /// 一覧の 1 行（選べるサービス 1 つ）。
    public struct Entry: Sendable, Equatable, Identifiable {
        public let channel: PhysicalChannel
        public let service: ChannelService
        /// 同じ物理チャンネルの中で何番目か（1 から。マルチ編成の枝番）
        public let branch: Int

        public var id: String { "\(channel.frequency)-\(service.serviceID)" }
        public var remoteControlKey: Int? { channel.remoteControlKey }
    }

    /// 一覧。物理チャンネルごとに主のサービス（出すもののうち service_id が最も小さいもの）だけを、
    /// リモコンキーの順に並べる。キーの無い局は最後に周波数の順。
    /// マルチ編成のサブのサービスは、マルチ編成でない時間帯は主と同じ番組なので既定では出さず、
    /// `subServices(of:)` から選ぶ
    public var lineup: [Entry] {
        allServices.filter { $0.branch == 1 }
    }

    /// 同じ物理チャンネルの、出すサービスすべて（主を含む。枝番の順）。「サブチャンネル」の選択に使う
    public func subServices(of channel: PhysicalChannel) -> [Entry] {
        allServices.filter { $0.channel.frequency == channel.frequency }
    }

    /// 出すサービスすべてを、リモコンキー・service_id の順に
    public var allServices: [Entry] {
        let ordered = channels.sorted { left, right in
            switch (left.remoteControlKey, right.remoteControlKey) {
            case let (l?, r?) where l != r: l < r
            case (.some, nil): true
            case (nil, .some): false
            default: left.frequency < right.frequency
            }
        }
        var entries: [Entry] = []
        for channel in ordered {
            let visible = channel.services.filter(\.isVisible).sorted { $0.serviceID < $1.serviceID }
            for (index, service) in visible.enumerated() {
                entries.append(Entry(channel: channel, service: service, branch: index + 1))
            }
        }
        return entries
    }
}
