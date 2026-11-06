import Foundation

/// 番組情報を画面に出すときの決まり。
///
/// 時刻は放送と同じ日本時間で出す（Mac のタイムゾーンが違っても、番組表の時刻と合うように）。
public enum ProgramDisplay {
    /// 現在・次の番組を出せるか
    public enum Status: Equatable, Sendable {
        /// 受信していない（出すものが無い）
        case unavailable
        /// 受信を始めたが、そのサービスの EIT[p/f] がまだ届いていない
        case loading
        /// 現在・次の番組
        case available(present: BroadcastEvent?, following: BroadcastEvent?)
    }

    /// 放送の時刻と Mac の時計の差を、画面に出し続けるほどのずれとみなす大きさ（秒）。
    /// 放送の時刻は 1 秒単位で、受け取るまでの遅れも含むので、これより小さい差は出さない
    public static let noticeableClockOffset: TimeInterval = 2

    private static let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "ja_JP"),
                                               calendar: Calendar(identifier: .gregorian), timeZone: SITables.japan)

    /// サービスの番組情報と、受信の様子から、出すものを決める
    public static func status(_ entry: BroadcastInformation.PresentFollowing?, isReceiving: Bool) -> Status {
        if let entry, entry.present != nil || entry.following != nil {
            return .available(present: entry.present, following: entry.following)
        }
        return isReceiving ? .loading : .unavailable
    }

    /// 「21:00〜22:00」。開始か長さが不明なら、分かる側だけ
    public static func timeRange(_ event: BroadcastEvent) -> String {
        switch (event.start, event.end) {
        case let (start?, end?): "\(clock(start))〜\(clock(end))"
        case let (start?, nil): "\(clock(start))〜"
        default: "時間未定"
        }
    }

    /// 「21:30」（日本時間）
    public static func clock(_ date: Date) -> String {
        date.formatted(time)
    }

    /// 「+0.2 秒」
    public static func offset(_ seconds: TimeInterval) -> String {
        String(format: "%+.1f 秒", seconds)
    }
}
