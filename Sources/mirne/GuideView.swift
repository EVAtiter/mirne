import SwiftUI

/// ウィンドウの ID（`openWindow` で開く）
enum WindowID {
    static let guide = "guide"
}

/// 番組表の画面の寸法。
enum GuideLayout {
    /// 1 分の高さ。1 時間で 180 pt（30 分の番組に番組名が 2〜3 行入る）
    static let pointsPerMinute: CGFloat = 3
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
}

/// 番組表。局を横・時間を縦に並べ、番組を押すとその局を選局する。
///
/// 別ウィンドウとシートの両方から使う。シートのときは `dismiss` を渡し、番組を選んだら閉じる（映像を見るため）。
/// 番組表は視聴した物理チャンネルの分だけ集まるので、まだ集まっていない局は「未取得」と出す。
struct GuideView: View {
    let model: ViewerModel
    var dismiss: (() -> Void)?

    @State private var days: [GuideDay] = []
    @State private var selectedDay: GuideDay?
    @State private var columns: [Column] = []
    /// 表示した後に今の時刻へ送る（読み込みが済んでから）
    @State private var scrollRequest = 0

    struct Column: Identifiable {
        let entry: ChannelList.Entry
        let coverage: EPGCoverage?
        let placements: [GuidePlacement]
        var id: String { entry.id }
    }

    private struct ReloadKey: Equatable {
        var day: GuideDay?
        var revision: Int
        /// 巡回が保存した回数（番組表を重ねて出している間の巡回で、集まった分をその場で出す）
        var patrolRevision: Int
        var lineup: [String]
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.lineup.isEmpty {
                ContentUnavailableView("チャンネルがありません", systemImage: "list.bullet.rectangle",
                                       description: Text("チャンネルスキャンをすると、番組表を見られます。"))
            } else {
                grid
            }
        }
        .task(id: ReloadKey(day: selectedDay, revision: model.playback.broadcast.scheduleRevision, patrolRevision: model.patrolRevision, lineup: model.lineup.map(\.id))) {
            reload()
        }
    }

    // MARK: - 上の操作

    private var toolbar: some View {
        HStack(spacing: 12) {
            ControlGroup {
                Button("前の日", systemImage: "chevron.left") { moveDay(by: -1) }
                    .disabled(dayIndex.map { $0 == 0 } ?? true)
                Button("次の日", systemImage: "chevron.right") { moveDay(by: 1) }
                    .disabled(dayIndex.map { $0 == days.count - 1 } ?? true)
            }
            .labelStyle(.iconOnly)
            .fixedSize()
            Picker("日付", selection: $selectedDay) {
                ForEach(days) { day in
                    Text(ProgramGuide.dayLabel(day)).tag(Optional(day))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            Button("今") {
                selectedDay = days.first
                scrollRequest += 1
            }
            if columns.contains(where: { $0.coverage == nil }) {
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

    private var dayIndex: Int? {
        selectedDay.flatMap { days.firstIndex(of: $0) }
    }

    private func moveDay(by offset: Int) {
        guard let index = dayIndex, days.indices.contains(index + offset) else { return }
        selectedDay = days[index + offset]
    }

    // MARK: - グリッド

    private var dayHeight: CGFloat { CGFloat(24 * 60) * GuideLayout.pointsPerMinute }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ZStack(alignment: .topLeading) {
                            HStack(alignment: .top, spacing: 0) {
                                ruler
                                ForEach(columns) { column in
                                    ColumnView(column: column, now: model.guideNow, height: dayHeight) { select(column.entry) }
                                }
                            }
                            nowLine
                        }
                    } header: {
                        header
                    }
                }
            }
            .onChange(of: scrollRequest) {
                let day = selectedDay ?? ProgramGuide.day(containing: model.guideNow)
                let hour = day.contains(model.guideNow) ? Int(model.guideNow.timeIntervalSince(day.start) / 3600) - GuideLayout.hoursBeforeNow : 0
                proxy.scrollTo(RulerHour(index: max(hour, 0)), anchor: .topLeading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: GuideLayout.rulerWidth)
            ForEach(columns) { column in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let key = column.entry.remoteControlKey {
                            Text("\(key)").font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(column.entry.service.name).font(.headline).lineLimit(1)
                    }
                    Text(column.coverage.map { "取得 \(ProgramGuide.receivedLabel($0.lastReceived))" } ?? "未取得")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(width: GuideLayout.columnWidth, alignment: .leading)
                .overlay(alignment: .leading) { GuideRule(axis: .vertical) }
            }
        }
        .background(.bar)
        .overlay(alignment: .bottom) { GuideRule(axis: .horizontal) }
    }

    /// 1 時間目・2 時間目… の印（今の時刻へ送る先にもなる）
    private struct RulerHour: Hashable {
        let index: Int
    }

    private var ruler: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { index in
                Text(ProgramGuide.hourLabel(index))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .frame(width: GuideLayout.rulerWidth, height: 60 * GuideLayout.pointsPerMinute, alignment: .top)
                    .overlay(alignment: .top) { GuideRule(axis: .horizontal) }
                    .id(RulerHour(index: index))
            }
        }
    }

    /// 今の時刻の線（選んだ日が今日のとき）
    @ViewBuilder private var nowLine: some View {
        let now = model.guideNow
        if let day = selectedDay, day.contains(now) {
            Rectangle()
                .fill(.red)
                .frame(width: GuideLayout.rulerWidth + GuideLayout.columnWidth * CGFloat(columns.count), height: 2)
                .offset(y: CGFloat(now.timeIntervalSince(day.start) / 60) * GuideLayout.pointsPerMinute - 1)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 読み込みと選局

    private func reload() {
        let now = model.guideNow
        let store = model.epgStore
        let lineup = model.lineup
        let coverages = lineup.map { entry in
            store?.coverage(networkID: entry.channel.originalNetworkID, transportStreamID: entry.channel.transportStreamID,
                            serviceID: entry.service.serviceID)
        }
        let newDays = ProgramGuide.days(from: now, through: coverages.compactMap { $0?.latestEnd }.max())
        let isFirstLoad = days.isEmpty
        days = newDays
        let day = selectedDay.flatMap { selected in newDays.first { $0 == selected } } ?? newDays[0]
        if selectedDay != day { selectedDay = day }
        columns = zip(lineup, coverages).map { entry, coverage in
            let events = coverage == nil ? [] : store?.events(networkID: entry.channel.originalNetworkID,
                                                              transportStreamID: entry.channel.transportStreamID,
                                                              serviceID: entry.service.serviceID,
                                                              overlapping: day.start..<day.end) ?? []
            return Column(entry: entry, coverage: coverage, placements: ProgramGuide.placements(events, in: day))
        }
        if isFirstLoad { scrollRequest += 1 }
    }

    private func select(_ entry: ChannelList.Entry) {
        model.select(entry)
        dismiss?()
    }
}

/// 1 局の列
private struct ColumnView: View {
    let column: GuideView.Column
    let now: Date
    let height: CGFloat
    let select: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(column.coverage == nil ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.background))
            ForEach(column.placements) { placement in
                ProgramCell(placement: placement, now: now, select: select)
                    .offset(y: CGFloat(placement.offsetMinutes) * GuideLayout.pointsPerMinute)
            }
        }
        .frame(width: GuideLayout.columnWidth, height: height, alignment: .topLeading)
        .clipped()
        .overlay(alignment: .leading) { GuideRule(axis: .vertical) }
    }
}

/// 1 番組の欄
private struct ProgramCell: View {
    let placement: GuidePlacement
    let now: Date
    let select: () -> Void

    private var event: BroadcastEvent { placement.event }
    private var height: CGFloat { CGFloat(placement.lengthMinutes) * GuideLayout.pointsPerMinute }
    private var isOnAir: Bool {
        guard let start = event.start else { return false }
        return start <= now && now < (event.end ?? start)
    }
    private var hasEnded: Bool { (event.end ?? .distantFuture) <= now }

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
            .frame(width: GuideLayout.columnWidth, height: height, alignment: .topLeading)
            .background(isOnAir ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear))
            .opacity(hasEnded ? 0.55 : 1)
            .clipped()
            .contentShape(Rectangle())
            .overlay(alignment: .top) { GuideRule(axis: .horizontal) }
        }
        .buttonStyle(.plain)
        .help("\(ProgramDisplay.timeRange(event))  \(event.title)\(event.text.isEmpty ? "" : "\n\(event.text)")")
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
