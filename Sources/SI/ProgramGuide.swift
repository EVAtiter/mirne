import Foundation

/// 番組表の 1 日。テレビの番組表と同じく、朝 4 時から翌朝 4 時までを 1 日とする。
public struct GuideDay: Hashable, Sendable, Identifiable {
    public var start: Date
    public var end: Date
    public var id: Date { start }

    public func contains(_ date: Date) -> Bool { start <= date && date < end }
}

/// 番組表の 1 日の中での番組の位置。分の単位で、1 日の始まりからの距離と長さ（1 日の外にはみ出す分は切る）。
public struct GuidePlacement: Sendable, Equatable, Identifiable {
    public var event: BroadcastEvent
    /// 1 日の始まりから番組の始まりまで（分）
    public var offsetMinutes: Double
    /// 1 日の中での長さ（分）
    public var lengthMinutes: Double
    public var id: UInt16 { event.eventID }
}

/// 番組表の日と位置の計算。時刻は放送と同じ日本時間で区切る。
public enum ProgramGuide {
    /// 1 日の始まりの時刻（時）。深夜番組を前の日に入れるため、0 時ではなく 4 時で区切る
    public static let dayStartHour = 4
    /// 長さが分からない番組を置くときの長さ（分）。番組表で見えるだけの高さにする
    public static let unknownLengthMinutes: Double = 30

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = SITables.japan
        return calendar
    }

    /// `date` を含む番組表の 1 日
    public static func day(containing date: Date) -> GuideDay {
        let calendar = calendar
        let shifted = date.addingTimeInterval(-TimeInterval(dayStartHour * 3600))
        let midnight = calendar.startOfDay(for: shifted)
        let start = midnight.addingTimeInterval(TimeInterval(dayStartHour * 3600))
        return GuideDay(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }

    /// `now` を含む日から、`latest`（持っている番組の最後の終了時刻）を含む日まで。`latest` が無ければ今日だけ
    public static func days(from now: Date, through latest: Date?) -> [GuideDay] {
        var days = [day(containing: now)]
        guard let latest else { return days }
        while let last = days.last, last.end < latest {
            days.append(day(containing: last.end))
        }
        return days
    }

    /// 1 日にかかる番組の位置（開始時刻の順）。開始の分からない番組は置かない
    public static func placements(_ events: [BroadcastEvent], in day: GuideDay) -> [GuidePlacement] {
        events.compactMap { event in
            guard let start = event.start else { return nil }
            let end = event.end ?? start.addingTimeInterval(unknownLengthMinutes * 60)
            guard start < day.end, end > day.start else { return nil }
            let visibleStart = max(start, day.start)
            let visibleEnd = min(end, day.end)
            return GuidePlacement(event: event,
                                  offsetMinutes: visibleStart.timeIntervalSince(day.start) / 60,
                                  lengthMinutes: visibleEnd.timeIntervalSince(visibleStart) / 60)
        }
        .sorted { $0.offsetMinutes < $1.offsetMinutes }
    }

    private static let dayFormat = Date.FormatStyle(locale: Locale(identifier: "ja_JP"), calendar: Calendar(identifier: .gregorian),
                                                    timeZone: SITables.japan)
        .month(.defaultDigits).day(.defaultDigits).weekday(.abbreviated)
    private static let receivedFormat = Date.FormatStyle(locale: Locale(identifier: "ja_JP"), calendar: Calendar(identifier: .gregorian),
                                                         timeZone: SITables.japan)
        .month(.defaultDigits).day(.defaultDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)

    /// 「11/4(水)」
    public static func dayLabel(_ day: GuideDay) -> String {
        day.start.formatted(dayFormat)
    }

    /// 1 日の始まりから `hour` 時間目の時刻の「時」（4〜27 ではなく 4〜23・0〜3）
    public static func hourLabel(_ index: Int) -> String {
        "\((dayStartHour + index) % 24)"
    }

    /// 取得時刻「11/4 20:03」
    public static func receivedLabel(_ date: Date) -> String {
        date.formatted(receivedFormat)
    }
}
