import Foundation

/// `coax scan` が書き出す JSON のうち、チャンネル一覧に使うところ（coax の `pkg/report`・`pkg/isdb`）。
struct ScanReport: Decodable {
    let startedAt: Date?
    let results: [Result]

    enum CodingKeys: String, CodingKey {
        case startedAt = "started_at"
        case results
    }

    struct Result: Decodable {
        /// スキャンでの名前（地上波は物理チャンネルの番号）
        let channel: String
        /// `DELIVERY_SYSTEM`・`FREQUENCY` など
        let properties: [String: String]
        /// `found`・`no_lock` など
        let status: String
        let analysis: Analysis?
    }

    struct Analysis: Decodable {
        let transport: Transport?
    }

    struct Transport: Decodable {
        let transportStreamID: Int
        let originalNetworkID: Int
        /// SDT のサービス
        let services: [Service]?
        /// NIT の網
        let networks: [Network]?

        enum CodingKeys: String, CodingKey {
            case transportStreamID = "transport_stream_id"
            case originalNetworkID = "original_network_id"
            case services, networks
        }
    }

    struct Service: Decodable {
        let serviceID: Int
        let serviceType: Int
        let name: String?
        let partialReception: Bool?

        enum CodingKeys: String, CodingKey {
            case serviceID = "service_id"
            case serviceType = "service_type"
            case name
            case partialReception = "partial_reception"
        }
    }

    struct Network: Decodable {
        /// 自分の網（NIT[actual]）か
        let actual: Bool?
        let transports: [NetworkTransport]?
    }

    struct NetworkTransport: Decodable {
        let transportStreamID: Int
        /// 0 は記述子が無かったことを表す
        let remoteControlKeyID: Int?
        let tsName: String?
        let partialReceptionServiceIDs: [Int]?

        enum CodingKeys: String, CodingKey {
            case transportStreamID = "transport_stream_id"
            case remoteControlKeyID = "remote_control_key_id"
            case tsName = "ts_name"
            case partialReceptionServiceIDs = "partial_reception_service_ids"
        }
    }

    static func decode(_ data: Data) throws -> ScanReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "日時を読めない: \(text)"))
        }
        return try decoder.decode(ScanReport.self, from: data)
    }
}

/// スキャン結果の取り込みで起きる失敗。
public enum ChannelImportError: Error, LocalizedError, Equatable {
    /// JSON として読めない
    case unreadable(String)
    /// 受信できたチャンネルが 1 つも無い
    case nothingFound

    public var errorDescription: String? {
        switch self {
        case let .unreadable(detail): "スキャンの結果を読めません: \(detail)"
        case .nothingFound: "受信できるチャンネルが見つかりませんでした。アンテナ線の接続を確かめてください。"
        }
    }
}

extension ChannelList {
    /// `coax scan` の結果からチャンネル一覧を作る。
    ///
    /// 受信できた（`found`）チャンネルだけを取り込む。同じ TS（transport_stream_id）が複数の周波数で
    /// 見つかったとき（中継局など）は、最初に見つけた周波数を使う。
    public static func importing(scanResult data: Data, scannedAt fallbackDate: Date = Date()) throws -> ChannelList {
        let report: ScanReport
        do {
            report = try ScanReport.decode(data)
        } catch {
            throw ChannelImportError.unreadable("\(error)")
        }
        var channels: [PhysicalChannel] = []
        var seen = Set<Int>()
        for result in report.results where result.status == "found" {
            guard let transport = result.analysis?.transport,
                  let frequency = result.properties["FREQUENCY"].flatMap({ Int($0) }),
                  !seen.contains(transport.transportStreamID) else { continue }
            seen.insert(transport.transportStreamID)
            let own = transport.networks?
                .filter { $0.actual ?? false }
                .flatMap { $0.transports ?? [] }
                .first { $0.transportStreamID == transport.transportStreamID }
            let partial = Set(own?.partialReceptionServiceIDs ?? [])
            let services = (transport.services ?? []).map { service in
                ChannelService(serviceID: service.serviceID,
                               name: service.name ?? "サービス \(service.serviceID)",
                               type: service.serviceType,
                               isPartialReception: (service.partialReception ?? false) || partial.contains(service.serviceID))
            }
            channels.append(PhysicalChannel(name: result.channel,
                                            frequency: frequency,
                                            system: result.properties["DELIVERY_SYSTEM"] ?? "ISDBT",
                                            transportStreamID: transport.transportStreamID,
                                            originalNetworkID: transport.originalNetworkID,
                                            remoteControlKey: own?.remoteControlKeyID.flatMap { $0 == 0 ? nil : $0 },
                                            tsName: own?.tsName,
                                            services: services))
        }
        guard !channels.isEmpty else { throw ChannelImportError.nothingFound }
        return ChannelList(scannedAt: report.startedAt ?? fallbackDate, channels: channels)
    }
}
