import Foundation
import os
import SQLite3

/// 番組表の保存の決まり。
public enum EPGRetention {
    /// 終わってからこれだけたった番組を消す。番組表で、その日のすでに終わった番組も見られるように 1 日残す
    public static let keepAfterEnd: TimeInterval = 24 * 3600
}

/// 番組表が届いた範囲（番組表に取得時刻を出すのに使う）。
public struct EPGCoverage: Sendable, Equatable {
    /// 最後に番組表を受け取った時刻（Mac の時刻）
    public var lastReceived: Date
    /// 持っている番組の最後の終了時刻
    public var latestEnd: Date?
    public var eventCount: Int
}

/// 番組表の保存先が使えない。
public struct EPGStoreError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { "番組表を保存できません: \(message)" }
}

/// 番組表（EIT[schedule]）を SQLite に保存する。
///
/// 番組はネットワーク・TS・サービス・イベントの ID の組で一意に決まる。届いたセクションの版が変わったら、
/// そのセクションに載っていた番組を消してから入れ直す（時間が動いた番組は別のセクションへ移ることがある）。
/// 書き込みは自分の直列のキューで行い、呼び出し側（受信の道筋・画面）を待たせない。読み出しは同じキューで待って返す。
public final class EPGStore: @unchecked Sendable {
    /// 番組表の場所（`~/Library/Application Support/mirne/epg.sqlite`）
    public static func defaultFileURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return support.appendingPathComponent("mirne", isDirectory: true).appendingPathComponent("epg.sqlite")
    }

    /// 表の作りの版。変えたら作り直す
    static let schemaVersion: Int32 = 1

    private let queue = DispatchQueue(label: "com.slack-kingdom.mirne.epg")
    private var database: OpaquePointer?
    private static let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "epg")

    public init(fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(fileURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "開けません"
            sqlite3_close(database)
            throw EPGStoreError(message: message)
        }
        try createSchema()
    }

    deinit {
        sqlite3_close(database)
    }

    /// EIT[schedule] のセクションを保存する（版が変わるたびに呼ぶ）。終わった番組もここで消す
    public func save(_ sections: [EITSection], receivedAt: Date) {
        let schedule = sections.filter(\.isSchedule)
        guard !schedule.isEmpty else { return }
        queue.async { [self] in
            do {
                try transaction {
                    for section in schedule {
                        try execute("DELETE FROM events WHERE network_id = ? AND transport_stream_id = ? AND service_id = ? AND table_id = ? AND section_number = ?",
                                    [.integer(section.originalNetworkID), .integer(section.transportStreamID), .integer(section.serviceID),
                                     .integer(section.tableID), .integer(section.sectionNumber)])
                        for event in section.events {
                            try execute("""
                                INSERT OR REPLACE INTO events
                                (network_id, transport_stream_id, service_id, event_id, table_id, section_number, start, duration, title, text, lossless, received)
                                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                                """,
                                [.integer(event.originalNetworkID), .integer(event.transportStreamID), .integer(event.serviceID), .integer(event.eventID),
                                 .integer(section.tableID), .integer(section.sectionNumber),
                                 event.start.map { .double($0.timeIntervalSince1970) } ?? .null,
                                 event.duration.map { .integer($0) } ?? .null,
                                 .text(event.title), .text(event.text), .integer(event.lossless ? 1 : 0),
                                 .double(receivedAt.timeIntervalSince1970)])
                        }
                        try execute("INSERT OR REPLACE INTO services (network_id, transport_stream_id, service_id, last_received) VALUES (?, ?, ?, ?)",
                                    [.integer(section.originalNetworkID), .integer(section.transportStreamID), .integer(section.serviceID),
                                     .double(receivedAt.timeIntervalSince1970)])
                    }
                    try execute("DELETE FROM events WHERE start IS NOT NULL AND duration IS NOT NULL AND start + duration < ?",
                                [.double(receivedAt.timeIntervalSince1970 - EPGRetention.keepAfterEnd)])
                }
            } catch {
                Self.logger.error("番組表を保存できない: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// サービスの、時間帯 `range` にかかる番組（開始時刻の順）
    public func events(networkID: Int, transportStreamID: Int, serviceID: Int, overlapping range: Range<Date>) -> [BroadcastEvent] {
        queue.sync {
            var events: [BroadcastEvent] = []
            try? query("""
                SELECT event_id, table_id, start, duration, title, text, lossless FROM events
                WHERE network_id = ? AND transport_stream_id = ? AND service_id = ?
                  AND start < ? AND start + COALESCE(duration, 0) > ?
                ORDER BY start
                """,
                [.integer(networkID), .integer(transportStreamID), .integer(serviceID),
                 .double(range.upperBound.timeIntervalSince1970), .double(range.lowerBound.timeIntervalSince1970)]) { row in
                events.append(BroadcastEvent(
                    tableID: UInt8(sqlite3_column_int(row, 1)), serviceID: UInt16(serviceID), eventID: UInt16(sqlite3_column_int(row, 0)),
                    transportStreamID: UInt16(transportStreamID), originalNetworkID: UInt16(networkID),
                    start: Date(timeIntervalSince1970: sqlite3_column_double(row, 2)),
                    duration: sqlite3_column_type(row, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(row, 3)),
                    title: Self.text(row, 4), text: Self.text(row, 5),
                    lossless: sqlite3_column_int(row, 6) != 0))
            }
            return events
        }
    }

    /// サービスの番組表が届いた範囲。一度も届いていなければ nil
    public func coverage(networkID: Int, transportStreamID: Int, serviceID: Int) -> EPGCoverage? {
        queue.sync {
            var coverage: EPGCoverage?
            try? query("""
                SELECT s.last_received, MAX(e.start + e.duration), COUNT(e.event_id) FROM services s
                LEFT JOIN events e ON e.network_id = s.network_id AND e.transport_stream_id = s.transport_stream_id AND e.service_id = s.service_id
                WHERE s.network_id = ? AND s.transport_stream_id = ? AND s.service_id = ?
                GROUP BY s.service_id
                """, [.integer(networkID), .integer(transportStreamID), .integer(serviceID)]) { row in
                coverage = EPGCoverage(
                    lastReceived: Date(timeIntervalSince1970: sqlite3_column_double(row, 0)),
                    latestEnd: sqlite3_column_type(row, 1) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(row, 1)),
                    eventCount: Int(sqlite3_column_int(row, 2)))
            }
            return coverage
        }
    }

    /// 番組表を持っているサービス（ネットワーク・TS・サービスの ID）
    public func storedServices() -> [(networkID: Int, transportStreamID: Int, serviceID: Int)] {
        queue.sync {
            var services: [(Int, Int, Int)] = []
            try? query("SELECT network_id, transport_stream_id, service_id FROM services ORDER BY network_id, transport_stream_id, service_id", []) { row in
                services.append((Int(sqlite3_column_int(row, 0)), Int(sqlite3_column_int(row, 1)), Int(sqlite3_column_int(row, 2))))
            }
            return services.map { (networkID: $0.0, transportStreamID: $0.1, serviceID: $0.2) }
        }
    }

    /// 書き込みが終わるまで待つ（試験と終了時）
    public func flush() {
        queue.sync {}
    }

    // MARK: - 下請け

    private enum Value {
        case int(Int)
        case double(Double)
        case text(String)
        case null

        static func integer<T: BinaryInteger>(_ value: T) -> Value { .int(Int(value)) }
    }

    private func createSchema() throws {
        try queue.sync {
            var version: Int32 = 0
            try query("PRAGMA user_version", []) { version = sqlite3_column_int($0, 0) }
            if version != Self.schemaVersion {
                // 作りが違えば捨てて作り直す（番組表は放送からまた集められる）
                try execute("DROP TABLE IF EXISTS events", [])
                try execute("DROP TABLE IF EXISTS services", [])
            }
            try execute("PRAGMA journal_mode = WAL", [])
            try execute("""
                CREATE TABLE IF NOT EXISTS events (
                    network_id INTEGER NOT NULL, transport_stream_id INTEGER NOT NULL, service_id INTEGER NOT NULL, event_id INTEGER NOT NULL,
                    table_id INTEGER NOT NULL, section_number INTEGER NOT NULL,
                    start REAL, duration INTEGER, title TEXT NOT NULL, text TEXT NOT NULL, lossless INTEGER NOT NULL, received REAL NOT NULL,
                    PRIMARY KEY (network_id, transport_stream_id, service_id, event_id))
                """, [])
            try execute("CREATE INDEX IF NOT EXISTS events_by_section ON events (network_id, transport_stream_id, service_id, table_id, section_number)", [])
            try execute("CREATE INDEX IF NOT EXISTS events_by_start ON events (network_id, transport_stream_id, service_id, start)", [])
            try execute("""
                CREATE TABLE IF NOT EXISTS services (
                    network_id INTEGER NOT NULL, transport_stream_id INTEGER NOT NULL, service_id INTEGER NOT NULL, last_received REAL NOT NULL,
                    PRIMARY KEY (network_id, transport_stream_id, service_id))
                """, [])
            try execute("PRAGMA user_version = \(Self.schemaVersion)", [])
        }
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN", [])
        do {
            try body()
            try execute("COMMIT", [])
        } catch {
            try? execute("ROLLBACK", [])
            throw error
        }
    }

    private func execute(_ sql: String, _ values: [Value]) throws {
        try query(sql, values) { _ in }
    }

    /// 文を実行し、行ごとに `row` を呼ぶ
    private func query(_ sql: String, _ values: [Value], row: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw EPGStoreError(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        // SQLITE_TRANSIENT: 文字列を SQLite に写させる
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let .int(number): sqlite3_bind_int64(statement, position, Int64(number))
            case let .double(number): sqlite3_bind_double(statement, position, number)
            case let .text(string): sqlite3_bind_text(statement, position, string, -1, transient)
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(statement)
            case SQLITE_DONE: return
            default: throw EPGStoreError(message: String(cString: sqlite3_errmsg(database)))
            }
        }
    }
}
