import Foundation

/// チャンネル一覧の保存場所。JSON をアトミックに書く（書き込みの途中で落ちても壊れない）。
public struct ChannelStore: Sendable {
    /// 保存するファイル
    public let fileURL: URL

    /// 既定の場所（`~/Library/Application Support/mirne/channels.json`）
    public static func defaultFileURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return support.appendingPathComponent("mirne", isDirectory: true).appendingPathComponent("channels.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 保存してある一覧。まだスキャンしていなければ nil
    public func load() throws -> ChannelList? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try Self.decoder.decode(ChannelList.self, from: data)
    }

    /// 保存する。一時ファイルに書いてから置き換えるので、途中で落ちても前の一覧が残る
    public func save(_ list: ChannelList) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(list).write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.dateFormatter().string(from: date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.dateFormatter().date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "日時を読めない: \(text)"))
            }
            return date
        }
        return decoder
    }()

    /// 日時は小数秒まで書く（`.iso8601` は秒で切り捨てるので、読み戻すと別の値になる）
    private static func dateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
