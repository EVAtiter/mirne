import Foundation
import Testing

@Suite("ProgramGuide（番組表の日と位置）")
struct ProgramGuideTests {
    private func event(_ id: UInt16, start: Date?, minutes: Int?) -> BroadcastEvent {
        BroadcastEvent(tableID: 0x50, serviceID: 1024, eventID: id, start: start, duration: minutes.map { $0 * 60 },
                       title: "番組", text: "", lossless: true)
    }

    @Test("1 日は朝 4 時から翌朝 4 時まで（日本時間）")
    func dayStartsAtFour() {
        let evening = ProgramGuide.day(containing: SISample.date(2026, 11, 4, 21, 0))
        #expect(evening.start == SISample.date(2026, 11, 4, 4, 0))
        #expect(evening.end == SISample.date(2026, 11, 5, 4, 0))
        // 深夜 2 時は前の日
        #expect(ProgramGuide.day(containing: SISample.date(2026, 11, 5, 2, 0)) == evening)
        #expect(ProgramGuide.day(containing: SISample.date(2026, 11, 5, 4, 0)).start == SISample.date(2026, 11, 5, 4, 0))
        #expect(ProgramGuide.dayLabel(evening) == "11/4(水)")
    }

    @Test("今日から、持っている番組の最後の日まで")
    func daysThroughLatest() {
        let now = SISample.date(2026, 11, 4, 21, 0)
        #expect(ProgramGuide.days(from: now, through: nil).count == 1)
        let days = ProgramGuide.days(from: now, through: SISample.date(2026, 11, 12, 0, 35))
        #expect(days.count == 8)
        #expect(days.last?.start == SISample.date(2026, 11, 11, 4, 0))
    }

    @Test("番組を 1 日の始まりからの分で置き、日をまたぐ分は切る。開始の分からない番組は置かない")
    func placements() {
        let day = ProgramGuide.day(containing: SISample.date(2026, 11, 4, 12, 0))
        let placed = ProgramGuide.placements([
            event(3, start: SISample.date(2026, 11, 5, 3, 30), minutes: 60),
            event(1, start: SISample.date(2026, 11, 4, 3, 0), minutes: 90),
            event(2, start: SISample.date(2026, 11, 4, 21, 0), minutes: nil),
            event(4, start: nil, minutes: nil),
            event(5, start: SISample.date(2026, 11, 5, 5, 0), minutes: 30),
        ], in: day)
        #expect(placed.map(\.event.eventID) == [1, 2, 3])
        #expect(placed[0].offsetMinutes == 0)
        #expect(placed[0].lengthMinutes == 30)
        #expect(placed[1].offsetMinutes == 17 * 60)
        #expect(placed[1].lengthMinutes == ProgramGuide.unknownLengthMinutes)
        #expect(placed[2].offsetMinutes == 23 * 60 + 30)
        #expect(placed[2].lengthMinutes == 30)
    }

    @Test("時刻の列は 4 時から 3 時まで。日をまたいで続けても同じ")
    func hourLabels() {
        #expect(ProgramGuide.hourLabel(0) == "4")
        #expect(ProgramGuide.hourLabel(19) == "23")
        #expect(ProgramGuide.hourLabel(20) == "0")
        #expect(ProgramGuide.hourLabel(23) == "3")
        #expect(ProgramGuide.hourLabel(24) == "4")
        #expect(ProgramGuide.hourLabel(24 * 7 + 20) == "0")
    }

    @Test("続いた日の全体に置くと、4 時をまたぐ番組は切らずに 1 つで置く")
    func placementsAcrossDays() throws {
        let now = SISample.date(2026, 11, 4, 21, 0)
        let days = ProgramGuide.days(from: now, through: SISample.date(2026, 11, 6, 1, 0))
        let span = try #require(ProgramGuide.span(of: days))
        #expect(span.start == SISample.date(2026, 11, 4, 4, 0))
        #expect(span.end == SISample.date(2026, 11, 6, 4, 0))
        #expect(ProgramGuide.span(of: []) == nil)
        let placed = ProgramGuide.placements([event(1, start: SISample.date(2026, 11, 5, 3, 30), minutes: 60)], in: span)
        let crossing = try #require(placed.first)
        #expect(crossing.offsetMinutes == 23 * 60 + 30)
        #expect(crossing.lengthMinutes == 60)
    }

    @Test("1 時間ごとの区切りに、かかるすべての区切りへ振り分ける。終わりがちょうど区切りなら、その先には入れない")
    func hourBuckets() {
        let placements = [
            GuidePlacement(event: event(1, start: nil, minutes: nil), offsetMinutes: 0, lengthMinutes: 60),
            GuidePlacement(event: event(2, start: nil, minutes: nil), offsetMinutes: 60, lengthMinutes: 150),
            GuidePlacement(event: event(3, start: nil, minutes: nil), offsetMinutes: 210, lengthMinutes: 120),
        ]
        let buckets = ProgramGuide.hourBuckets(placements, hours: 5)
        #expect(buckets.map { $0.map(\.event.eventID) } == [[1], [2], [2], [2, 3], [3]])
        #expect(ProgramGuide.hourBuckets(placements, hours: 0).isEmpty)
    }

    @Test("時刻の列の日付は 2 行に分ける")
    func rulerDayLabel() {
        let label = ProgramGuide.rulerDayLabel(ProgramGuide.day(containing: SISample.date(2026, 11, 4, 21, 0)))
        #expect(label.date == "11/4")
        #expect(label.weekday == "(水)")
    }
}
