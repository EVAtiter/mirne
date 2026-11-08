import Foundation
import SQLite3
import Testing

@Suite("EPGStore（番組表の保存）")
struct EPGStoreTests {
    private let now = SISample.date(2026, 11, 4, 21, 30)
    private let networkID = Int(SISample.originalNetworkID)
    private let transportStreamID = Int(SISample.transportStreamID)

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mirne-epg-\(UUID().uuidString)").appendingPathComponent("epg.sqlite")
    }

    private func section(sectionNumber: UInt8, events: [SISample.Event], serviceID: UInt16 = 1024) -> EITSection {
        SITables.parseEIT(SISample.eit(tableID: 0x50, serviceID: serviceID, version: 0, sectionNumber: sectionNumber, events: events))!
    }

    private func events(_ store: EPGStore, serviceID: Int = 1024) -> [UInt16] {
        store.events(networkID: networkID, transportStreamID: transportStreamID, serviceID: serviceID,
                     overlapping: SISample.date(2026, 11, 3, 0, 0)..<SISample.date(2026, 11, 13, 0, 0)).map(\.eventID)
    }

    @Test("保存した番組を、開き直しても時間帯で取り出せる")
    func persistsAcrossReopen() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        do {
            let store = try EPGStore(fileURL: file)
            store.save([section(sectionNumber: 8, events: [
                .init(eventID: 11, start: SISample.time(2026, 11, 4, 22, 0), hours: 1, minutes: 0, title: SISample.title),
                .init(eventID: 12, start: SISample.time(2026, 11, 4, 23, 0), hours: 0, minutes: 30, title: SISample.next),
            ])], receivedAt: now)
            store.flush()
        }
        let reopened = try EPGStore(fileURL: file)
        let found = reopened.events(networkID: networkID, transportStreamID: transportStreamID, serviceID: 1024,
                                    overlapping: SISample.date(2026, 11, 4, 22, 30)..<SISample.date(2026, 11, 4, 23, 10))
        #expect(found.map(\.eventID) == [11, 12])
        #expect(found.first?.title == "番組")
        #expect(found.first?.end == SISample.date(2026, 11, 4, 23, 0))
        let coverage = reopened.coverage(networkID: networkID, transportStreamID: transportStreamID, serviceID: 1024)
        #expect(coverage?.lastReceived == now)
        #expect(coverage?.latestEnd == SISample.date(2026, 11, 4, 23, 30))
        #expect(coverage?.eventCount == 2)
        #expect(reopened.storedServices().map(\.serviceID) == [1024])
    }

    @Test("コンテント記述子の最初のジャンルを読み、拡張（大分類 0xE）は飛ばす")
    func parsesGenre() {
        let parsed = section(sectionNumber: 0, events: [
            // 拡張 0xE0 の後にスポーツ・野球（0x10）
            .init(eventID: 1, start: SISample.time(2026, 11, 4, 22, 0), hours: 1, minutes: 0, title: SISample.title, content: [0xE0, 0x01, 0x10, 0xFF]),
            .init(eventID: 2, start: SISample.time(2026, 11, 4, 23, 0), hours: 1, minutes: 0, title: SISample.next),
        ])
        #expect(parsed.events.map(\.genre) == [ProgramGenre(major: 0x1, minor: 0x0), nil])
    }

    @Test("ジャンルを保存して取り出せる")
    func persistsGenre() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try EPGStore(fileURL: file)
        store.save([section(sectionNumber: 0, events: [
            .init(eventID: 1, start: SISample.time(2026, 11, 4, 22, 0), hours: 1, minutes: 0, title: SISample.title, content: [0x31, 0xFF]),
            .init(eventID: 2, start: SISample.time(2026, 11, 4, 23, 0), hours: 1, minutes: 0, title: SISample.next),
        ])], receivedAt: now)
        let found = store.events(networkID: networkID, transportStreamID: transportStreamID, serviceID: 1024,
                                 overlapping: SISample.date(2026, 11, 4, 0, 0)..<SISample.date(2026, 11, 5, 0, 0))
        #expect(found.map(\.genre) == [ProgramGenre(major: 0x3, minor: 0x1), nil])
    }

    @Test("ジャンルの列が無い前の版の番組表は、集めた番組を残して列を足す")
    func migratesFromVersionWithoutGenre() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 前の版（1）の作りを手で作り、番組を 1 つ入れておく
        var database: OpaquePointer?
        #expect(sqlite3_open(file.path, &database) == SQLITE_OK)
        let start = SISample.date(2026, 11, 4, 22, 0).timeIntervalSince1970
        let statements = [
            """
            CREATE TABLE events (
                network_id INTEGER NOT NULL, transport_stream_id INTEGER NOT NULL, service_id INTEGER NOT NULL, event_id INTEGER NOT NULL,
                table_id INTEGER NOT NULL, section_number INTEGER NOT NULL,
                start REAL, duration INTEGER, title TEXT NOT NULL, text TEXT NOT NULL, lossless INTEGER NOT NULL, received REAL NOT NULL,
                PRIMARY KEY (network_id, transport_stream_id, service_id, event_id))
            """,
            "CREATE TABLE services (network_id INTEGER NOT NULL, transport_stream_id INTEGER NOT NULL, service_id INTEGER NOT NULL, last_received REAL NOT NULL, PRIMARY KEY (network_id, transport_stream_id, service_id))",
            "INSERT INTO events VALUES (\(networkID), \(transportStreamID), 1024, 7, 80, 0, \(start), 3600, '前の版', '', 1, \(now.timeIntervalSince1970))",
            "PRAGMA user_version = 1",
        ]
        for sql in statements { #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK) }
        sqlite3_close(database)

        let store = try EPGStore(fileURL: file)
        let found = store.events(networkID: networkID, transportStreamID: transportStreamID, serviceID: 1024,
                                 overlapping: SISample.date(2026, 11, 4, 0, 0)..<SISample.date(2026, 11, 5, 0, 0))
        #expect(found.map(\.eventID) == [7])
        #expect(found.first?.genre == nil)
        // 足した列に書ける
        store.save([section(sectionNumber: 1, events: [
            .init(eventID: 8, start: SISample.time(2026, 11, 4, 23, 0), hours: 1, minutes: 0, title: SISample.next, content: [0x60, 0xFF]),
        ])], receivedAt: now)
        #expect(events(store) == [7, 8])
        #expect(store.events(networkID: networkID, transportStreamID: transportStreamID, serviceID: 1024,
                             overlapping: SISample.date(2026, 11, 4, 23, 0)..<SISample.date(2026, 11, 5, 0, 0)).last?.genre == ProgramGenre(major: 0x6, minor: 0x0))
    }

    @Test("同じセクションの新しい版で、載らなくなった番組を消す。別のセクションへ移った番組は残す")
    func replacesSection() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try EPGStore(fileURL: file)
        let moving = SISample.Event(eventID: 21, start: SISample.time(2026, 11, 4, 23, 50), hours: 0, minutes: 30, title: SISample.title)
        store.save([section(sectionNumber: 8, events: [
            .init(eventID: 20, start: SISample.time(2026, 11, 4, 22, 0), hours: 1, minutes: 0, title: SISample.title), moving,
        ])], receivedAt: now)
        // 番組 21 が次のセクションへ移り、番組 20 は無くなった
        var moved = moving
        moved.start = SISample.time(2026, 11, 5, 0, 10)
        store.save([section(sectionNumber: 16, events: [moved])], receivedAt: now)
        store.save([section(sectionNumber: 8, events: [])], receivedAt: now)
        store.flush()
        #expect(events(store) == [21])
    }

    @Test("終わってから 1 日を過ぎた番組を消す")
    func prunesOldEvents() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try EPGStore(fileURL: file)
        store.save([section(sectionNumber: 0, events: [
            .init(eventID: 30, start: SISample.time(2026, 11, 3, 19, 0), hours: 1, minutes: 0, title: SISample.title),
            .init(eventID: 31, start: SISample.time(2026, 11, 3, 22, 0), hours: 1, minutes: 0, title: SISample.title),
        ])], receivedAt: now)
        store.flush()
        // 30 は 11/03 20:00 に終わっていて、21:30 の時点で 1 日を過ぎている
        #expect(events(store) == [31])
    }

    @Test("サービスごとに分けて持つ")
    func separatesServices() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try EPGStore(fileURL: file)
        store.save([
            section(sectionNumber: 8, events: [.init(eventID: 40, start: SISample.time(2026, 11, 4, 22, 0), hours: 1, minutes: 0, title: SISample.title)]),
            section(sectionNumber: 8, events: [.init(eventID: 40, start: SISample.time(2026, 11, 4, 22, 30), hours: 1, minutes: 0, title: SISample.next)], serviceID: 1025),
        ], receivedAt: now)
        store.flush()
        #expect(events(store) == [40])
        #expect(store.events(networkID: networkID, transportStreamID: transportStreamID, serviceID: 1025,
                             overlapping: SISample.date(2026, 11, 4, 0, 0)..<SISample.date(2026, 11, 5, 0, 0)).first?.title == "次")
        #expect(store.storedServices().map(\.serviceID) == [1024, 1025])
    }
}

@Suite("BroadcastInformation の番組表の受け渡し")
@MainActor
struct BroadcastInformationScheduleHandoffTests {
    @Test("番組表のセクションだけを、届いた時刻と一緒に渡す")
    func handsScheduleSections() {
        let information = BroadcastInformation()
        var handed: [(Int, Date)] = []
        information.onSchedule = { sections, at in handed.append((sections.count, at)) }
        let generation = information.begin()
        let now = SISample.date(2026, 11, 4, 21, 30)
        let event = SISample.Event(eventID: 1, start: SISample.time(2026, 11, 4, 22, 0), hours: 1, minutes: 0, title: SISample.title)
        information.apply([
            .eventSection(SITables.parseEIT(SISample.eit(tableID: 0x4E, serviceID: 1024, version: 0, sectionNumber: 0, events: [event]))!),
            .eventSection(SITables.parseEIT(SISample.eit(tableID: 0x50, serviceID: 1024, version: 0, sectionNumber: 8, events: [event]))!),
        ], receivedAt: now, generation: generation)
        #expect(handed.count == 1)
        #expect(handed.first?.0 == 1)
        #expect(handed.first?.1 == now)
    }
}
