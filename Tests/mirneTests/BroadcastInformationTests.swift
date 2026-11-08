import Foundation
import Testing

/// 試験用の SI。手で組み立てる（実放送の内容はリポジトリに入れない）
enum SISample {
    /// 「番組」（JIS X 0208。ARIB の初期状態は G0 が漢字）
    static let title: [UInt8] = [0x48, 0x56, 0x41, 0x48]
    /// 「次」
    static let next: [UInt8] = [0x3C, 0x21]
    static let transportStreamID: UInt16 = 0x1234
    static let originalNetworkID: UInt16 = 0x5678

    /// MPEG-2 の CRC32
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        return crc
    }

    /// 長さと CRC を埋めてセクションにする（`body` は section_length の後ろから CRC の前まで）
    static func section(tableID: UInt8, body: [UInt8]) -> [UInt8] {
        let length = body.count + 4
        var bytes = [tableID, 0xF0 | UInt8(length >> 8), UInt8(length & 0xFF)] + body
        let crc = crc32(bytes)
        bytes += [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)]
        return bytes
    }

    /// 日本時間の年月日時分秒を、MJD＋BCD の 5 バイトに
    static func time(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day))!
        let mjd = Int(date.timeIntervalSince1970 / 86400) + 40587
        func bcd(_ value: Int) -> UInt8 { UInt8((value / 10) << 4 | value % 10) }
        return [UInt8(mjd >> 8), UInt8(mjd & 0xFF), bcd(hour), bcd(minute), bcd(second)]
    }

    /// 日本時間の Date
    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    struct Event {
        var eventID: UInt16
        var start: [UInt8]
        /// 長さ（時・分）
        var hours: Int
        var minutes: Int
        var title: [UInt8]?
        /// コンテント記述子の本体（2 バイトずつ）。nil なら付けない
        var content: [UInt8]? = nil
    }

    /// EIT のセクション
    static func eit(tableID: UInt8, serviceID: UInt16, version: UInt8, sectionNumber: UInt8, events: [Event]) -> [UInt8] {
        var body: [UInt8] = [UInt8(serviceID >> 8), UInt8(serviceID & 0xFF), 0xC1 | version << 1, sectionNumber, sectionNumber,
                             UInt8(transportStreamID >> 8), UInt8(transportStreamID & 0xFF),
                             UInt8(originalNetworkID >> 8), UInt8(originalNetworkID & 0xFF), sectionNumber, tableID]
        for event in events {
            var descriptors: [UInt8] = []
            if let title = event.title {
                // 短形式イベント記述子：言語「jpn」・番組名・概要（空）
                let content: [UInt8] = [0x6A, 0x70, 0x6E, UInt8(title.count)] + title + [0]
                descriptors = [0x4D, UInt8(content.count)] + content
            }
            if let content = event.content {
                descriptors += [0x54, UInt8(content.count)] + content
            }
            func bcd(_ value: Int) -> UInt8 { UInt8((value / 10) << 4 | value % 10) }
            body += [UInt8(event.eventID >> 8), UInt8(event.eventID & 0xFF)] + event.start
                + [bcd(event.hours), bcd(event.minutes), 0x00]
                + [0x80 | UInt8(descriptors.count >> 8), UInt8(descriptors.count & 0xFF)] + descriptors
        }
        return section(tableID: tableID, body: body)
    }

    /// TOT（地域の時差の記述子は付けない）
    static func tot(_ time: [UInt8]) -> [UInt8] {
        section(tableID: 0x73, body: time + [0xF0, 0x00])
    }

    /// セクションを TS パケットに分ける
    static func packets(pid: UInt16, section: [UInt8], continuity: inout UInt8) -> Data {
        var data = Data()
        var remaining = [0] + section   // pointer_field
        var first = true
        while !remaining.isEmpty {
            let payload = Array(remaining.prefix(184))
            remaining.removeFirst(payload.count)
            var packet: [UInt8] = [0x47, (first ? 0x40 : 0) | UInt8(pid >> 8), UInt8(pid & 0xFF), 0x10 | continuity]
            packet += payload + Array(repeating: 0xFF, count: 184 - payload.count)
            continuity = (continuity + 1) & 0x0F
            data.append(contentsOf: packet)
            first = false
        }
        return data
    }
}

@Suite("SIReader（EIT・TOT）")
struct SIReaderTests {
    @Test("EIT のセクションを、版が変わったときだけ返す")
    func returnsSectionOnlyWhenVersionChanges() {
        let reader = SIReader()
        var continuity: UInt8 = 0
        let present = SISample.Event(eventID: 1, start: SISample.time(2026, 11, 4, 21, 0), hours: 1, minutes: 0, title: SISample.title)
        let version0 = SISample.packets(pid: 0x12, section: SISample.eit(tableID: 0x4E, serviceID: 1024, version: 0, sectionNumber: 0, events: [present]), continuity: &continuity)
        let version1 = SISample.packets(pid: 0x12, section: SISample.eit(tableID: 0x4E, serviceID: 1024, version: 1, sectionNumber: 0, events: [present]), continuity: &continuity)

        let first = reader.feed(version0)
        #expect(first.count == 1)
        guard case let .eventSection(section) = first.first else {
            Issue.record("EIT のセクションのはず")
            return
        }
        #expect(section.isPresentFollowing)
        #expect(section.serviceID == 1024)
        #expect(section.transportStreamID == SISample.transportStreamID)
        #expect(section.events.first?.title == "番組")
        #expect(section.events.first?.start == SISample.date(2026, 11, 4, 21, 0))
        #expect(section.events.first?.end == SISample.date(2026, 11, 4, 22, 0))

        // 同じ版は繰り返し届いても返さない
        #expect(reader.feed(version0).isEmpty)
        #expect(reader.feed(version1).count == 1)
    }

    @Test("TOT の時刻を返す")
    func readsTOT() {
        let reader = SIReader()
        var continuity: UInt8 = 0
        let items = reader.feed(SISample.packets(pid: 0x14, section: SISample.tot(SISample.time(2026, 11, 4, 21, 30, 15)), continuity: &continuity))
        #expect(items == [.time(SISample.date(2026, 11, 4, 21, 30, 15))])
    }

    @Test("CRC が合わないセクションは読まない")
    func rejectsBadCRC() {
        let reader = SIReader()
        var continuity: UInt8 = 0
        var section = SISample.tot(SISample.time(2026, 11, 4, 21, 30))
        section[section.count - 1] ^= 0xFF
        #expect(reader.feed(SISample.packets(pid: 0x14, section: section, continuity: &continuity)).isEmpty)
    }
}

@Suite("BroadcastInformation")
@MainActor
struct BroadcastInformationTests {
    private func section(tableID: UInt8 = 0x4E, serviceID: UInt16 = 1024, sectionNumber: UInt8, events: [SISample.Event]) -> SIReader.Item {
        let bytes = SISample.eit(tableID: tableID, serviceID: serviceID, version: 0, sectionNumber: sectionNumber, events: events)
        return .eventSection(SITables.parseEIT(bytes)!)
    }

    private let now = SISample.date(2026, 11, 4, 21, 30)

    @Test("EIT[p/f] のセクション 0 を現在、1 を次の番組にする")
    func presentAndFollowing() {
        let information = BroadcastInformation()
        let generation = information.begin()
        information.apply([
            section(sectionNumber: 0, events: [.init(eventID: 1, start: SISample.time(2026, 11, 4, 21, 0), hours: 1, minutes: 0, title: SISample.title)]),
            section(sectionNumber: 1, events: [.init(eventID: 2, start: SISample.time(2026, 11, 4, 22, 0), hours: 0, minutes: 54, title: SISample.next)]),
        ], receivedAt: now, generation: generation)
        #expect(information.presentFollowing[1024]?.present?.title == "番組")
        #expect(information.presentFollowing[1024]?.following?.title == "次")
        #expect(information.presentFollowing[1024]?.following?.end == SISample.date(2026, 11, 4, 22, 54))

        // 番組が替わって次の番組が空のセクションになったら、次は無し
        information.apply([section(sectionNumber: 1, events: [])], receivedAt: now, generation: generation)
        #expect(information.presentFollowing[1024]?.present?.title == "番組")
        #expect(information.presentFollowing[1024]?.following == nil)
    }

    @Test("TOT から放送の時刻と Mac の時計との差を出す")
    func broadcastClock() {
        let information = BroadcastInformation()
        let generation = information.begin()
        let received = SISample.date(2026, 11, 4, 21, 29, 58)
        information.apply([.time(now)], receivedAt: received, generation: generation)
        #expect(information.clock?.offset == 2)
        #expect(information.clock?.broadcastTime(at: received.addingTimeInterval(10)) == now.addingTimeInterval(10))
    }

    @Test("選局し直したら空にし、前の TS から遅れて届いた分は捨てる")
    func discardsStaleGeneration() {
        let information = BroadcastInformation()
        let old = information.begin()
        information.apply([.time(now)], receivedAt: now, generation: old)
        let current = information.begin()
        #expect(information.clock == nil)
        information.apply([section(sectionNumber: 0, events: [.init(eventID: 1, start: SISample.time(2026, 11, 4, 21, 0), hours: 1, minutes: 0, title: SISample.title)])],
                          receivedAt: now, generation: old)
        #expect(information.presentFollowing.isEmpty)
        information.apply([.time(now)], receivedAt: now, generation: current)
        #expect(information.clock != nil)
    }

    @Test("番組表は版ごとにセクションを置き換え、終わった番組だけのセクションは捨てる")
    func scheduleReplacesAndPrunes() {
        let information = BroadcastInformation()
        let generation = information.begin()
        information.apply([.time(now)], receivedAt: now, generation: generation)
        let ended = SISample.Event(eventID: 10, start: SISample.time(2026, 11, 4, 18, 0), hours: 1, minutes: 0, title: SISample.title)
        let later = SISample.Event(eventID: 11, start: SISample.time(2026, 11, 4, 23, 0), hours: 1, minutes: 0, title: SISample.title)
        let tomorrow = SISample.Event(eventID: 12, start: SISample.time(2026, 11, 5, 9, 0), hours: 0, minutes: 30, title: SISample.next)
        information.apply([
            section(tableID: 0x50, sectionNumber: 0, events: [ended]),
            section(tableID: 0x50, sectionNumber: 8, events: [later]),
            section(tableID: 0x50, sectionNumber: 16, events: [tomorrow]),
        ], receivedAt: now, generation: generation)
        #expect(information.schedule(of: 1024).map(\.eventID) == [11, 12])

        // 同じセクションの新しい版で番組が入れ替わった
        let moved = SISample.Event(eventID: 13, start: SISample.time(2026, 11, 4, 23, 30), hours: 0, minutes: 30, title: SISample.next)
        information.apply([section(tableID: 0x50, sectionNumber: 8, events: [moved])], receivedAt: now, generation: generation)
        #expect(information.schedule(of: 1024).map(\.eventID) == [13, 12])
        #expect(information.scheduledServices == [1024])
    }

    @Test("他 TS の EIT は使わない")
    func ignoresOtherTransportStreams() {
        let information = BroadcastInformation()
        let generation = information.begin()
        information.apply([section(tableID: 0x4F, sectionNumber: 0, events: [.init(eventID: 1, start: SISample.time(2026, 11, 4, 21, 0), hours: 1, minutes: 0, title: SISample.title)]),
                           section(tableID: 0x60, sectionNumber: 0, events: [.init(eventID: 2, start: SISample.time(2026, 11, 4, 23, 0), hours: 1, minutes: 0, title: SISample.title)])],
                          receivedAt: now, generation: generation)
        #expect(information.presentFollowing.isEmpty)
        #expect(information.scheduledServices.isEmpty)
    }
}

@Suite("ProgramDisplay（オーバーレイの番組の文字）")
struct ProgramDisplayTests {
    private func event(start: Date?, duration: Int?) -> BroadcastEvent {
        BroadcastEvent(tableID: 0x4E, serviceID: 1024, eventID: 1, start: start, duration: duration, title: "番組", text: "", lossless: true)
    }

    @Test("開始と終了を日本時間の「時:分」で出す")
    func timeRange() {
        #expect(ProgramDisplay.timeRange(event(start: SISample.date(2026, 11, 4, 21, 0), duration: 3600)) == "21:00〜22:00")
        #expect(ProgramDisplay.timeRange(event(start: SISample.date(2026, 11, 4, 23, 45), duration: 1800)) == "23:45〜0:15")
        #expect(ProgramDisplay.timeRange(event(start: SISample.date(2026, 11, 4, 21, 0), duration: nil)) == "21:00〜")
        #expect(ProgramDisplay.timeRange(event(start: nil, duration: nil)) == "時間未定")
    }

    @Test("その局の EIT[p/f] が届くまでは「取得中」、受信していなければ出さない")
    func status() {
        let present = event(start: SISample.date(2026, 11, 4, 21, 0), duration: 3600)
        #expect(ProgramDisplay.status(nil, isReceiving: true) == .loading)
        #expect(ProgramDisplay.status(nil, isReceiving: false) == .unavailable)
        #expect(ProgramDisplay.status(.init(present: nil, following: nil), isReceiving: true) == .loading)
        #expect(ProgramDisplay.status(.init(present: present, following: nil), isReceiving: true) == .available(present: present, following: nil))
    }

    @Test("Mac の時計との差を符号付きで出す")
    func offset() {
        #expect(ProgramDisplay.offset(0.2) == "+0.2 秒")
        #expect(ProgramDisplay.offset(-3) == "-3.0 秒")
    }
}
