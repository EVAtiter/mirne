import SwiftUI

/// ウィンドウの ID（`openWindow` で開く）
enum WindowID {
    static let guide = "guide"
}

/// 番組表の画面の寸法。
enum GuideLayout {
    /// 1 分の高さ。1 時間で 180 pt（30 分の番組に番組名が 2〜3 行入る）
    static let pointsPerMinute: CGFloat = 3
    /// 1 時間の行の高さ（番組表は 1 時間ずつの行で並べる）
    static var hourHeight: CGFloat { 60 * pointsPerMinute }
    /// 1 日（朝 4 時から翌朝 4 時）の高さ
    static var dayHeight: CGFloat { 24 * hourHeight }
    /// 局の列の幅
    static let columnWidth: CGFloat = 168
    /// 左の時刻の列の幅
    static let rulerWidth: CGFloat = 32
    /// 番組の欄に時刻と番組名に加えて概要も出す高さ
    static let heightForDescription: CGFloat = 72
    /// 別ウィンドウの初めの大きさ
    static let windowSize = CGSize(width: 1100, height: 760)
    /// シートの大きさ（幅は別ウィンドウと同じ。既定の視聴ウィンドウ（映像 960 とサイドバー）に収まる）
    static let sheetSize = CGSize(width: 1100, height: 640)
    /// 開いたとき・「今」を押したとき、今の時刻の何時間前から見せるか
    static let hoursBeforeNow = 1
    /// 局名の行・時刻の列・左上の角の背景。番組の欄（白・ジャンルの色）と分けて、表の枠として見せる。
    /// 3 つとも同じ不透明の色にする（局名の行は半透明の `.bar`、時刻の列は白で揃っていなかった。時刻の列は番組の欄の上に重なるので、透けない色が要る）
    static var frameBackground: Color { Color(nsColor: .windowBackgroundColor) }
    /// 日の境目（朝 4 時）の線の太さ。1 時間ごとの区切り線（1 pt）と見分けられる太さにする
    static let dayBoundaryThickness: CGFloat = 2
    /// 日の境目の線の色。区切り線（`separatorColor`）より濃くする
    static var dayBoundaryColor: Color { Color(nsColor: .secondaryLabelColor) }
    /// 画面に見えている行の前後に、余分に作っておく行の数（送り始めたときに、作るのが間に合わず空いて見えないように）
    static let overscanRows = 1
    /// 送った量がまだ分からないうちに作る行の数（開いた直後。すぐに見えている行へ置き換わる）
    static let initialRows = 8
}

/// 番組表の読み直しの決まり
enum GuideReloadTiming {
    /// 番組表が保存されたことによる読み直しを、これより詰めて行わない。巡回や視聴の始めは番組表のセクションが 1 秒に何度も届くので、
    /// 届くたびに読み直すと表を作り直し続けて動きが重くなる。集まった番組が表に出るのが、最大でこの分遅れる
    static let minimumInterval: Duration = .seconds(2)
}

/// 番組の欄にマウスを置いたときに出す吹き出し（番組の内容）。
/// システムのツールチップ（`.help`）は文字が小さく書式も選べないので、自前の吹き出しにしている
enum GuidePopover {
    /// マウスを置いてから出すまで。番組の欄の上を通り過ぎるだけでは出ないよう、システムのツールチップより少し長くしてある
    static let hoverDelay: Duration = .seconds(1)
    /// 吹き出しの幅（概要を読みやすい行の長さに折り返す）
    static let width: CGFloat = 340
    static let padding: CGFloat = 14
    /// 時刻・番組名・概要の間
    static let spacing: CGFloat = 6
    /// 矢印を向ける所の幅。番組の欄の横の中央から出すための細い縦の線（0 だと吹き出しが出ない）
    static let anchorWidth: CGFloat = 1
}

/// 番組表の 1 局（列）
struct GuideStation: Identifiable, Equatable, Sendable {
    let entry: ChannelList.Entry
    let coverage: EPGCoverage?
    var id: String { entry.id }
}

/// 番組表に並べるもの。今日の朝 4 時から、持っている番組の最後の日の終わりまでを日をまたいで続けて並べ、1 時間ずつの行に分ける
struct GuideTable: Sendable {
    /// 並べる範囲（最初の日の始まりから最後の日の終わりまで）
    let span: GuideDay
    let days: [GuideDay]
    let stations: [GuideStation]
    /// 1 時間ずつの行（`span` の始まりから）の、局ごとの番組。行をまたぐ番組は、かかるすべての行に入る
    let hours: [[[GuidePlacement]]]

    /// 読み出した番組表から作る（重いので画面の外で行う）
    nonisolated static func build(start: Date, lineup: [ChannelList.Entry], schedules: [EPGStore.ServiceSchedule]) -> GuideTable {
        let days = ProgramGuide.days(from: start, through: schedules.compactMap { $0.coverage?.latestEnd }.max())
        let span = ProgramGuide.span(of: days) ?? ProgramGuide.day(containing: start)
        let hourCount = days.count * 24
        let buckets = schedules.map { schedule in
            ProgramGuide.hourBuckets(ProgramGuide.placements(schedule.events, in: span), hours: hourCount)
        }
        let hours = (0..<hourCount).map { hour in buckets.map { $0[hour] } }
        let stations = zip(lineup, schedules).map { GuideStation(entry: $0, coverage: $1.coverage) }
        return GuideTable(span: span, days: days, stations: stations, hours: hours)
    }
}

/// 番組表。局を横・時間を縦に並べ、番組を押すとその局を選局する。
///
/// 今日の朝 4 時から、持っている番組の最後の日までを日をまたいで続けて並べる（日付の選択は、その日へ送るだけ）。
/// 行は 1 時間ずつで、画面に出ている行だけを作る（8 日分の番組の欄を一度に作らない）。
/// 別ウィンドウとシートの両方から使う。シートのときは `dismiss` を渡し、番組を選んだら閉じる（映像を見るため）。
/// 番組表は視聴した物理チャンネルの分だけ集まるので、まだ集まっていない局は「未取得」と出す。
struct GuideView: View {
    let model: ViewerModel
    var dismiss: (() -> Void)?

    /// 並べている番組表（最初の読み込みが済むまで nil）
    @State private var table: GuideTable?
    /// 並べる範囲の始まり（朝 4 時）。開いている間に日が替わっても、開き直すか「今」を押すまでは動かさない
    /// （始まりを動かすと、見ている位置が 1 日分ずれる）
    @State private var rangeStart: Date?
    /// 表示した後に今の時刻へ送る（読み込みが済んでから）
    @State private var scrollRequest = 0
    /// 「今」へ送るのを、読み込みが済むまで待っている
    @State private var pendingScrollToNow = false
    @State private var position = ScrollPosition(point: .zero)
    /// 局名の行の高さ（左上の角を同じ高さで塗り、時刻の列をその下から出す）
    @State private var headerHeight: CGFloat = 0
    /// 送った量（時刻の列と上の操作だけが読む）
    @State private var scroll = GuideScrollState()
    /// マウスの下の番組と吹き出し
    @State private var hover = GuideHoverState()
    @State private var loading = GuideLoadState()

    var body: some View {
        VStack(spacing: 0) {
            GuideToolbar(days: table?.days ?? [], scroll: scroll,
                         showsCoverageNote: table?.stations.contains { $0.coverage == nil } ?? false,
                         moveDay: moveDay(by:), showDay: showDay(_:), showNow: showNow, dismiss: dismiss)
            Divider()
            if model.lineup.isEmpty {
                ContentUnavailableView("チャンネルがありません", systemImage: "list.bullet.rectangle",
                                       description: Text("チャンネルスキャンをすると、番組表を見られます。"))
            } else {
                grid
            }
        }
        // 番組表の保存・チャンネル一覧の変化を見て読み直す。見るのは下の小さな view だけにし、この画面全体は描き直さない
        .background {
            GuideReloadDriver(model: model, rangeStart: rangeStart) { immediate in await reload(immediate: immediate) }
        }
        .onAppear {
            if rangeStart == nil { rangeStart = ProgramGuide.day(containing: model.guideNow).start }
        }
        .onDisappear { hover.reset() }
        // 別ウィンドウを開いたら（窓を見せた後で）「今」と同じにする。閉じても SwiftUI が隠しておくだけなので、
        // そのままでは開き直したときに前に見ていた位置のまま出る
        .onChange(of: model.guideWindowShowCount) { showNow() }
        .onChange(of: scrollRequest) { scrollToNow() }
    }

    // MARK: - 上の操作

    /// 今日の、今の時刻の少し前へ送る（「今」ボタン・番組表を開き直したとき）。日が替わっていたら、範囲の始まりを今日にしてから送る
    private func showNow() {
        let today = ProgramGuide.day(containing: model.guideNow).start
        if today != rangeStart || table?.span.start != today {
            pendingScrollToNow = true
            rangeStart = today
        } else {
            scrollRequest += 1
        }
    }

    /// 前後の日へ。見ている時刻と横の位置は変えない（日付を替えても同じ時間帯を見られるように）
    private func moveDay(by offset: Int) {
        guard let table else { return }
        let target = scroll.visibleDay + offset
        guard table.days.indices.contains(target) else { return }
        scrollVertically(to: scroll.y + CGFloat(offset) * GuideLayout.dayHeight, in: table)
    }

    /// 選んだ日へ。見ている時刻と横の位置は変えない
    private func showDay(_ index: Int) {
        guard let table, table.days.indices.contains(index) else { return }
        let timeOfDay = scroll.y - CGFloat(scroll.visibleDay) * GuideLayout.dayHeight
        scrollVertically(to: CGFloat(index) * GuideLayout.dayHeight + timeOfDay, in: table)
    }

    private func scrollVertically(to y: CGFloat, in table: GuideTable) {
        let limit = CGFloat(table.days.count - 1) * GuideLayout.dayHeight + (GuideLayout.dayHeight - GuideLayout.hourHeight)
        position.scrollTo(point: CGPoint(x: scroll.x, y: min(max(y, 0), max(limit, 0))))
    }

    /// 今の時刻の `hoursBeforeNow` 時間前の行へ、左端から（今までの「今」と同じ）
    private func scrollToNow() {
        guard let table else { return }
        let now = model.guideNow
        let hour = table.span.contains(now) ? Int(now.timeIntervalSince(table.span.start) / 3600) - GuideLayout.hoursBeforeNow : 0
        position.scrollTo(point: CGPoint(x: 0, y: CGFloat(max(hour, 0)) * GuideLayout.hourHeight))
    }

    // MARK: - グリッド

    @ViewBuilder private var grid: some View {
        if let table {
            // 今の時刻は分の単位で進める（放送の時刻の分の境目に合わせる）。放送の時刻が数秒ごとに届くたびには描き直さない
            let offset = model.guideClockOffset
            let broadcastMinute = (Date().addingTimeInterval(offset).timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
            TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: broadcastMinute - offset), by: 60)) { context in
                tableView(table, now: context.date.addingTimeInterval(offset))
            }
        } else {
            Color.clear
        }
    }

    private func tableView(_ table: GuideTable, now: Date) -> some View {
        let palette = GuideGenrePalette(model.guideGenreColors)
        let style = model.guideGenreStyle
        return ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    GuideRows(table: table, now: now, genreStyle: style, palette: palette, scroll: scroll, hover: hover, select: select)
                } header: {
                    header(table)
                }
            }
        }
        .scrollPosition($position)
        // 送った量だけを時刻の列・上の操作・作る行の範囲へ渡す（この値を読むのはその 3 つだけなので、番組の欄は描き直さない）
        .onScrollGeometryChange(for: GuideScrollGeometry.self) {
            GuideScrollGeometry(offset: CGPoint(x: $0.contentOffset.x + $0.contentInsets.leading, y: $0.contentOffset.y + $0.contentInsets.top),
                                viewportHeight: $0.containerSize.height)
        } action: { _, geometry in
            scroll.update(geometry, dayCount: table.days.count, hourCount: table.hours.count)
        }
        .overlay(alignment: .topLeading) {
            FloatingRuler(scroll: scroll, top: headerHeight) { rulerContent(table, now: now) }
        }
        .overlay(alignment: .topLeading) { corner }
    }

    private func header(_ table: GuideTable) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: GuideLayout.rulerWidth)
            ForEach(table.stations) { station in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let key = station.entry.remoteControlKey {
                            Text("\(key)").font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(station.entry.service.name).font(.headline).lineLimit(1)
                    }
                    Text(station.coverage.map { "取得 \(ProgramGuide.receivedLabel($0.lastReceived))" } ?? "未取得")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(width: GuideLayout.columnWidth, alignment: .leading)
                .overlay(alignment: .leading) { GuideRule(axis: .vertical) }
            }
        }
        .background(GuideLayout.frameBackground)
        .overlay(alignment: .bottom) { GuideRule(axis: .horizontal) }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
    }

    /// 左上の角（時刻の列の上・局名の行の左）。スクロールの外から重ね、横に送った局名が時刻の列の上へ入り込まないようにする。
    /// 局名の行の中に左へ留める並びを入れると、行の高さが決まらず局名が上で切れた
    private var corner: some View {
        Rectangle().fill(GuideLayout.frameBackground)
            .frame(width: GuideLayout.rulerWidth, height: headerHeight)
            .overlay(alignment: .bottom) { GuideRule(axis: .horizontal) }
            .overlay(alignment: .trailing) { GuideRule(axis: .vertical) }
            .allowsHitTesting(false)
    }

    /// 時刻の列の中身（番組の欄の上に重なるので、背景を塗って下の欄を隠す）。日の境目（朝 4 時）には日付を添え、線を太くする
    private func rulerContent(_ table: GuideTable, now: Date) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(table.hours.indices, id: \.self) { index in
                    let dayStart = index % 24 == 0
                    VStack(spacing: 1) {
                        Text(ProgramGuide.hourLabel(index))
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                        if dayStart, table.days.indices.contains(index / 24) {
                            let label = ProgramGuide.rulerDayLabel(table.days[index / 24])
                            Group {
                                Text(label.date)
                                Text(label.weekday)
                            }
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        }
                    }
                    .padding(.top, 2)
                    .frame(width: GuideLayout.rulerWidth, height: GuideLayout.hourHeight, alignment: .top)
                    .overlay(alignment: .top) {
                        if dayStart, index > 0 { GuideDayBoundary() } else { GuideRule(axis: .horizontal) }
                    }
                }
            }
            if let y = GuideHourRow.nowOffset(now, from: table.span.start, within: table.span.end.timeIntervalSince(table.span.start)) {
                GuideNowLine(width: GuideLayout.rulerWidth).offset(y: y)
            }
        }
        .background(GuideLayout.frameBackground)
        .overlay(alignment: .trailing) { GuideRule(axis: .vertical) }
    }

    // MARK: - 読み込みと選局

    /// 番組表を読み直す。読み出しも表の組み立てもメインスレッドの外で行う。
    /// `immediate` でなければ（番組表が保存されただけなら）、前の読み直しから `GuideReloadTiming.minimumInterval` たつまで待つ
    private func reload(immediate: Bool) async {
        guard let start = rangeStart else { return }
        if !immediate, let last = loading.lastStarted {
            let wait = GuideReloadTiming.minimumInterval - (ContinuousClock.now - last)
            if wait > .zero { try? await Task.sleep(for: wait) }
            // 待っている間に次の合図が来た（その合図の読み直しが同じ時刻まで待つ）
            guard !Task.isCancelled else { return }
        }
        loading.lastStarted = .now
        loading.generation += 1
        let generation = loading.generation
        let lineup = model.lineup
        let services = lineup.map {
            EPGStore.ServiceKey(networkID: $0.channel.originalNetworkID, transportStreamID: $0.channel.transportStreamID, serviceID: $0.service.serviceID)
        }
        // 範囲の終わりは持っている番組で決まるので、始まりから先をすべて読む（番組表は放送から 8 日分ほどしか無い）
        let schedules = await model.epgStore?.schedules(of: services, overlapping: start..<Date.distantFuture)
            ?? lineup.map { _ in EPGStore.ServiceSchedule(coverage: nil, events: []) }
        let built = await Task.detached(priority: .userInitiated) {
            GuideTable.build(start: start, lineup: lineup, schedules: schedules)
        }.value
        // 読み始めた後で取り消されても、読んだ結果は新しいので使う（次々に合図が来ると、取り消してばかりで表が変わらなくなる）。
        // 後から読み始めた結果が先に出ていれば、古いほうは捨てる
        guard generation > loading.applied else { return }
        loading.applied = generation
        let isFirstLoad = table == nil
        table = built
        if isFirstLoad || pendingScrollToNow {
            pendingScrollToNow = false
            scrollRequest += 1
        }
    }

    private func select(_ entry: ChannelList.Entry) {
        model.select(entry)
        dismiss?()
    }
}

/// 番組表の読み直しの合図を見る。番組表の保存の回数は数秒の間に何度も変わるので、それを読むのはこの小さな view だけにし、
/// 番組表の画面全体が描き直されないようにする。範囲の始まり・チャンネル一覧が変わったら、待たずに読み直す
private struct GuideReloadDriver: View {
    let model: ViewerModel
    let rangeStart: Date?
    let reload: (_ immediate: Bool) async -> Void
    @State private var previous: ReloadKey?

    private struct ReloadKey: Equatable {
        var rangeStart: Date?
        var revision: Int
        /// 巡回が保存した回数（番組表を重ねて出している間の巡回で、集まった分をその場で出す）
        var patrolRevision: Int
        var lineup: [String]
    }

    var body: some View {
        let key = ReloadKey(rangeStart: rangeStart, revision: model.playback.broadcast.scheduleRevision,
                            patrolRevision: model.patrolRevision, lineup: model.lineup.map(\.id))
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: key) {
                let immediate = previous.map { $0.rangeStart != key.rangeStart || $0.lineup != key.lineup } ?? true
                previous = key
                await reload(immediate)
            }
    }
}

/// 読み直しの時刻と順番（画面の描き直しには関わらないので、観測しない入れ物に持つ）
@MainActor
private final class GuideLoadState {
    /// 最後に読み直しを始めた時刻
    var lastStarted: ContinuousClock.Instant?
    /// 読み直しを始めた回数と、表に当てた最後の回
    var generation = 0
    var applied = 0
}

/// 上の操作（日付・「今」・閉じる）。送った位置の日付を出すので、送った量のうち「何日目か」だけを見る
private struct GuideToolbar: View {
    let days: [GuideDay]
    let scroll: GuideScrollState
    let showsCoverageNote: Bool
    let moveDay: (Int) -> Void
    let showDay: (Int) -> Void
    let showNow: () -> Void
    let dismiss: (() -> Void)?

    var body: some View {
        let visible = min(scroll.visibleDay, max(days.count - 1, 0))
        HStack(spacing: 12) {
            ControlGroup {
                Button("前の日", systemImage: "chevron.left") { moveDay(-1) }
                    .disabled(days.isEmpty || visible == 0)
                Button("次の日", systemImage: "chevron.right") { moveDay(1) }
                    .disabled(days.isEmpty || visible == days.count - 1)
            }
            .labelStyle(.iconOnly)
            .fixedSize()
            Picker("日付", selection: Binding(get: { days.isEmpty ? nil : visible }, set: { if let index = $0 { showDay(index) } })) {
                ForEach(days.indices, id: \.self) { index in
                    Text(ProgramGuide.dayLabel(days[index])).tag(Optional(index))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            Button("今", action: showNow)
            if showsCoverageNote {
                Text("番組表は、視聴した局の分だけ集まります")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let dismiss {
                Button("閉じる", action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// 送った量と、見えている高さ
private struct GuideScrollGeometry: Equatable {
    var offset: CGPoint
    var viewportHeight: CGFloat
}

/// 送った量。番組表の本体は読まず、時刻の列（`y`）・上の操作（`visibleDay`）・行の並び（`visibleRows`）だけが読む（読む view だけが描き直される）
@MainActor
@Observable
private final class GuideScrollState {
    /// 縦に送った量
    var y: CGFloat = 0
    /// 横に送った量（日付を替えるときに横の位置を保つためだけに使う。描き直しには使わない）
    @ObservationIgnored var x: CGFloat = 0
    /// 画面の上端にある日（何日目か）。日が替わったときだけ変わる
    var visibleDay = 0
    /// 作る行（見えている行と前後の余分）。行の区切りを越えたときだけ変わる
    var visibleRows = 0..<GuideLayout.initialRows

    func update(_ geometry: GuideScrollGeometry, dayCount: Int, hourCount: Int) {
        y = geometry.offset.y
        x = geometry.offset.x
        let day = min(max(Int(geometry.offset.y / GuideLayout.dayHeight), 0), max(dayCount - 1, 0))
        if day != visibleDay { visibleDay = day }
        // 行は局名の行の下から始まるので、見えている範囲は送った量から見えている高さまで（局名の行のぶんは余分の行で足りる）
        let first = Int((geometry.offset.y / GuideLayout.hourHeight).rounded(.down)) - GuideLayout.overscanRows
        let last = Int(((geometry.offset.y + geometry.viewportHeight) / GuideLayout.hourHeight).rounded(.up)) + GuideLayout.overscanRows
        let rows = min(max(first, 0), hourCount)..<min(max(last, 0), hourCount)
        if rows != visibleRows { visibleRows = rows }
    }
}

/// 1 時間の行を並べる。行の位置は計算で決め（時刻の列と必ず揃う）、見えている行だけを作る。
///
/// 最初は `LazyVStack` に全部の行を並べたが、まだ作っていない行の高さを見積もりで置くので、「次の日」などで遠くへ送ると
/// 行の位置が計算とずれ、時刻の列と番組の欄が 1 時間ほど食い違った
private struct GuideRows: View {
    let table: GuideTable
    let now: Date
    let genreStyle: GuideGenreStyle
    let palette: GuideGenrePalette
    let scroll: GuideScrollState
    let hover: GuideHoverState
    let select: (ChannelList.Entry) -> Void

    var body: some View {
        let rows = scroll.visibleRows.clamped(to: 0..<table.hours.count)
        ZStack(alignment: .topLeading) {
            // 全部の行の大きさの空き（送れる範囲を決める）
            Color.clear
                .frame(width: GuideLayout.rulerWidth + GuideLayout.columnWidth * CGFloat(table.stations.count),
                       height: GuideLayout.hourHeight * CGFloat(table.hours.count))
            ForEach(Array(rows), id: \.self) { hour in
                GuideHourRow(hour: hour, start: table.span.start.addingTimeInterval(TimeInterval(hour) * 3600),
                             stations: table.stations, cells: table.hours[hour], now: now,
                             genreStyle: genreStyle, palette: palette, hover: hover, select: select)
                    .equatable()
                    .alignmentGuide(.top) { _ in -CGFloat(hour) * GuideLayout.hourHeight }
            }
        }
        // マウスの見張りは表全体で 1 つにし、下の行・局・番組を位置から割り出す。
        // 番組の欄ごとに見張ると数が増え、スクロールのたびにすべての見張りの範囲を直すので、縦も横も重くなった。
        // 行ごとに見張ると、「今」へ送った直後などに見張りの範囲が送った位置に追いつかず、マウスと違う行（3 行下）に届いた
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hovered(at: location)
            case .ended: hover.reset()
            }
        }
    }

    /// マウスの位置（表の左上から）から、下の行・局・番組を割り出す
    private func hovered(at location: CGPoint) {
        let row = Int((location.y / GuideLayout.hourHeight).rounded(.down))
        let column = Int(((location.x - GuideLayout.rulerWidth) / GuideLayout.columnWidth).rounded(.down))
        guard location.x >= GuideLayout.rulerWidth, table.hours.indices.contains(row), table.hours[row].indices.contains(column) else {
            hover.update(row: max(row, 0), station: nil, placement: nil)
            return
        }
        let minutes = Double(location.y / GuideLayout.pointsPerMinute)
        let placement = table.hours[row][column].first { minutes >= $0.offsetMinutes && minutes < $0.offsetMinutes + $0.lengthMinutes }
        hover.update(row: row, station: column, placement: placement)
    }
}

/// マウスの下の番組と、吹き出しを出している番組。
/// 吹き出しは 1 時間の行に付けて出すので、同じ番組の上で行をまたいでも待ち直さないよう、番組で覚える
@MainActor
@Observable
private final class GuideHoverState {
    struct Detail: Identifiable, Equatable {
        /// 吹き出しを出す行（マウスがあった行）と局の列
        let row: Int
        let station: Int
        let placement: GuidePlacement
        var id: String { "\(station)-\(placement.id)" }
    }

    private(set) var detail: Detail?
    @ObservationIgnored private var hovered: HoverKey?
    @ObservationIgnored private var activeRow: Int?
    @ObservationIgnored private var task: Task<Void, Never>?

    private struct HoverKey: Equatable {
        let station: Int
        let event: UInt16
    }

    /// マウスが行 `row` の、局 `station` の番組 `placement` の上にある（番組が無ければ nil）。番組が替わったときだけ待ち直す
    func update(row: Int, station: Int?, placement: GuidePlacement?) {
        activeRow = row
        let key = station.flatMap { station in placement.map { HoverKey(station: station, event: $0.id) } }
        guard key != hovered else { return }
        hovered = key
        task?.cancel()
        if detail != nil { detail = nil }
        guard let station, let placement else { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: GuidePopover.hoverDelay)
            guard !Task.isCancelled, let self else { return }
            self.detail = Detail(row: self.activeRow ?? row, station: station, placement: placement)
        }
    }

    /// 吹き出しを閉じた（外を押した）。マウスの下の番組は覚えたままにし、別の番組へ移るまで出し直さない。
    /// 吹き出しを出していないときにも SwiftUI が閉じる知らせを送ってくることがあり、そのまま待ちを取り消すと、
    /// 別の番組へ移った直後の待ちが消えて吹き出しが出なかったので、出しているときだけ閉じる
    func dismiss() {
        guard detail != nil else { return }
        task?.cancel()
        detail = nil
    }

    func reset() {
        task?.cancel()
        hovered = nil
        activeRow = nil
        if detail != nil { detail = nil }
    }
}

/// 1 時間の行。全局の、その 1 時間にかかる番組の欄を並べる。
///
/// 行をまたぐ番組は、かかる行ごとに同じ大きさの欄を同じ位置に描いて、行の範囲で切る（つなぎ目はずれないので、1 つの欄に見える）。
/// 同じ内容なら描き直さない（今の時刻が進んでも、放送中・終わったが変わらない欄は描き直さない）
private struct GuideHourRow: View, Equatable {
    let hour: Int
    /// この行の始まりの時刻
    let start: Date
    let stations: [GuideStation]
    /// 局ごとの、この 1 時間にかかる番組
    let cells: [[GuidePlacement]]
    let now: Date
    let genreStyle: GuideGenreStyle
    let palette: GuideGenrePalette
    let hover: GuideHoverState
    let select: (ChannelList.Entry) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hour == rhs.hour && lhs.start == rhs.start && lhs.now == rhs.now && lhs.stations == rhs.stations
            && lhs.cells == rhs.cells && lhs.genreStyle == rhs.genreStyle && lhs.palette == rhs.palette
    }

    /// この行の始まりからの分（行の中での番組の位置）
    private var startMinutes: Double { Double(hour * 60) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 時刻の列の幅の空き（時刻の列そのものはスクロールの外に重ねる）
            Color.clear.frame(width: GuideLayout.rulerWidth)
            ForEach(stations.indices, id: \.self) { index in
                cell(stations[index], placements: cells.indices.contains(index) ? cells[index] : [])
            }
        }
        .frame(height: GuideLayout.hourHeight, alignment: .top)
        .overlay(alignment: .topLeading) {
            if let y = Self.nowOffset(now, from: start, within: 3600) {
                GuideNowLine(width: nil).offset(y: y)
            }
        }
        .overlay(alignment: .top) {
            // 日の境目（朝 4 時。最初の日の始まりは局名の行の線と重なるので引かない）
            if hour > 0, hour % 24 == 0 { GuideDayBoundary() }
        }
        // 吹き出しはこの行に付けて出す（マウスの見張りは `GuideRows` が表全体で 1 つ持つ）
        .overlay(alignment: .topLeading) {
            GuidePopoverHost(hover: hover, row: hour, rowStartMinutes: startMinutes)
        }
    }

    private func cell(_ station: GuideStation, placements: [GuidePlacement]) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(station.coverage == nil ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.background))
            ForEach(placements) { placement in
                ProgramCell(placement: placement, isOnAir: Self.isOnAir(placement.event, at: now),
                            hasEnded: (placement.event.end ?? .distantFuture) <= now, genreStyle: genreStyle,
                            genreColor: placement.event.genre.flatMap(palette.color(for:))) { select(station.entry) }
                    .equatable()
                    .offset(y: CGFloat(placement.offsetMinutes - startMinutes) * GuideLayout.pointsPerMinute)
            }
        }
        .frame(width: GuideLayout.columnWidth, height: GuideLayout.hourHeight, alignment: .topLeading)
        .clipped()
        .overlay(alignment: .leading) { GuideRule(axis: .vertical) }
    }

    static func isOnAir(_ event: BroadcastEvent, at now: Date) -> Bool {
        guard let start = event.start else { return false }
        return start <= now && now < (event.end ?? start)
    }

    /// 今の時刻の線の位置（`start` からの距離）。`length` 秒の間に入っていなければ nil
    static func nowOffset(_ now: Date, from start: Date, within length: TimeInterval) -> CGFloat? {
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= 0, elapsed < length else { return nil }
        return CGFloat(elapsed / 60) * GuideLayout.pointsPerMinute - 1
    }
}

/// 行の上に重ねて、吹き出しを出す。吹き出しの状態はこの小さな view だけが読み、行そのものは描き直さない
private struct GuidePopoverHost: View {
    let hover: GuideHoverState
    let row: Int
    let rowStartMinutes: Double

    var body: some View {
        let detail = hover.detail.flatMap { $0.row == row ? $0 : nil }
        Color.clear
            .allowsHitTesting(false)
            .popover(item: Binding(get: { detail }, set: { if $0 == nil, detail != nil { hover.dismiss() } }),
                     attachmentAnchor: .rect(.rect(anchorRect(detail))), arrowEdge: .trailing) { detail in
                ProgramDetail(event: detail.placement.event)
            }
    }

    /// 吹き出しの矢印を向ける所。番組の欄（この行に見えている部分）の中心から出す。
    /// 欄の幅いっぱいの矩形にすると矢印が欄の右端から出るので、細い縦の線を欄の横の中央に置く（縦は見えている部分の中央）。
    /// 幅を 0 にすると空の矩形とみなされ、吹き出しが出なかった
    private func anchorRect(_ detail: GuideHoverState.Detail?) -> CGRect {
        guard let detail else { return .zero }
        let top = max(CGFloat(detail.placement.offsetMinutes - rowStartMinutes) * GuideLayout.pointsPerMinute, 0)
        let bottom = min(CGFloat(detail.placement.offsetMinutes + detail.placement.lengthMinutes - rowStartMinutes) * GuideLayout.pointsPerMinute,
                         GuideLayout.hourHeight)
        let centerX = GuideLayout.rulerWidth + (CGFloat(detail.station) + 0.5) * GuideLayout.columnWidth
        return CGRect(x: centerX - GuidePopover.anchorWidth / 2, y: top, width: GuidePopover.anchorWidth, height: max(bottom - top, 1))
    }
}

/// 1 番組の欄。同じ内容なら描き直さない（押したときの処理は比べない）
private struct ProgramCell: View, Equatable {
    let placement: GuidePlacement
    let isOnAir: Bool
    let hasEnded: Bool
    let genreStyle: GuideGenreStyle
    /// ジャンルの色。ジャンルが無い番組は nil（色を付けない）
    let genreColor: Color?
    let select: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.placement == rhs.placement && lhs.isOnAir == rhs.isOnAir && lhs.hasEnded == rhs.hasEnded
            && lhs.genreStyle == rhs.genreStyle && lhs.genreColor == rhs.genreColor
    }

    private var event: BroadcastEvent { placement.event }
    private var height: CGFloat { CGFloat(placement.lengthMinutes) * GuideLayout.pointsPerMinute }

    /// 欄の背景。背景を塗る設定ならジャンルの淡い色、そうでなければ放送中の番組だけを強調色で塗る
    private var background: AnyShapeStyle {
        if genreStyle.paintsBackground {
            return genreColor.map { AnyShapeStyle($0.opacity(GuideGenreLayout.backgroundOpacity)) } ?? AnyShapeStyle(.clear)
        }
        return isOnAir ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear)
    }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 1) {
                Text(event.start.map(ProgramDisplay.clock) ?? "")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(event.title)
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.leading)
                if height >= GuideLayout.heightForDescription, !event.text.isEmpty {
                    Text(event.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .padding(.leading, genreStyle.showsStripe ? GuideGenreLayout.stripeWidth : 0)
            .frame(width: GuideLayout.columnWidth, height: height, alignment: .topLeading)
            .background(background)
            .overlay(alignment: .leading) {
                if genreStyle.showsStripe, let genreColor {
                    Rectangle().fill(genreColor).frame(width: GuideGenreLayout.stripeWidth)
                }
            }
            .opacity(hasEnded ? 0.55 : 1)
            .overlay {
                // 背景をジャンルの色で塗るときは、放送中の番組を塗らずに枠で示す。枠は帯と同じジャンルの色で描く
                // （ジャンルが無い番組は強調色）
                if isOnAir, genreStyle.paintsBackground {
                    Rectangle().strokeBorder(genreColor ?? Color.accentColor, lineWidth: GuideGenreLayout.onAirOutlineWidth)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .overlay(alignment: .top) { GuideRule(axis: .horizontal) }
        }
        .buttonStyle(.plain)
    }
}

/// 番組の欄の吹き出しの中身。文字は番組の欄より大きく、色は副次の灰色を使わずに読みやすくする
private struct ProgramDetail: View {
    let event: BroadcastEvent

    var body: some View {
        VStack(alignment: .leading, spacing: GuidePopover.spacing) {
            Text(ProgramDisplay.timeRange(event))
                .font(.body.monospacedDigit())
            Text(event.title)
                .font(.title3.bold())
            if !event.text.isEmpty {
                Text(event.text)
                    .font(.body)
            }
        }
        .foregroundStyle(.primary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: GuidePopover.width, alignment: .leading)
        .padding(GuidePopover.padding)
        // 吹き出しの既定の背景は半透明で、下の番組の欄の文字が透けて読みにくいので、不透明にする
        .presentationBackground(Color(nsColor: .windowBackgroundColor))
    }
}

/// スクロールの外に重ねる時刻の列。横には動かず、縦は送った量だけずらす。局名の行の下で切る。
///
/// 1.0.2 の後に一度、時刻の列を局の列と同じ横の並びの「左に留める見出し」にした。横に送るたびに並び全体（全局の番組の欄）の
/// 配置を計算し直すことになり、横のスクロールだけがもたついたので、スクロールの外へ出した
private struct FloatingRuler<Content: View>: View {
    let scroll: GuideScrollState
    let top: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
            .offset(y: top - scroll.y)
            .frame(width: GuideLayout.rulerWidth, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .allowsHitTesting(false)
    }
}

/// 今の時刻の線。幅を渡さなければ行の幅いっぱい
private struct GuideNowLine: View {
    let width: CGFloat?

    var body: some View {
        Rectangle()
            .fill(.red)
            .frame(width: width, height: 2)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .allowsHitTesting(false)
    }
}

/// 日の境目（朝 4 時）の線。1 時間ごとの区切り線より太く濃く引く
private struct GuideDayBoundary: View {
    var body: some View {
        Rectangle()
            .fill(GuideLayout.dayBoundaryColor)
            .frame(height: GuideLayout.dayBoundaryThickness)
            .allowsHitTesting(false)
    }
}

/// 番組表の区切り線。overlay に `Divider` を置くと向きが定まらず、横線のつもりが列の中央に縦線として出たので、向きを決めて引く
private struct GuideRule: View {
    let axis: Axis

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}
