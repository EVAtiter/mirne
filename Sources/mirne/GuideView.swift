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
    /// 局名の行・時刻の列・左上の角の背景。番組の欄（白・ジャンルの色）と分けて、表の枠として見せる。
    /// 3 つとも同じ不透明の色にする（局名の行は半透明の `.bar`、時刻の列は白で揃っていなかった。時刻の列は番組の欄の上に重なるので、透けない色が要る）
    static var frameBackground: Color { Color(nsColor: .windowBackgroundColor) }
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
    /// 局名の行の高さ（左上の角を同じ高さで塗り、時刻の列をその下から出す）
    @State private var headerHeight: CGFloat = 0
    /// 縦に送った量（時刻の列だけが読む）
    @State private var rulerScroll = RulerScroll()

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
        // 別ウィンドウは閉じても SwiftUI が隠しておくだけなので、開き直すと前に見ていた日と位置のまま出る。開き直したら「今」と同じにする
        .onChange(of: model.guideWindowShowCount) { showNow() }
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
            Button("今", action: showNow)
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

    /// 今日の、今の時刻の少し前へ送る（「今」ボタン・番組表を開き直したとき）
    private func showNow() {
        selectedDay = days.first
        scrollRequest += 1
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
                                hourAnchors
                                ForEach(columns) { column in
                                    ColumnView(column: column, now: model.guideNow, height: dayHeight,
                                               genreStyle: model.guideGenreStyle, genreColors: model.guideGenreColors) { select(column.entry) }
                                }
                            }
                            nowLine(width: GuideLayout.rulerWidth + GuideLayout.columnWidth * CGFloat(columns.count))
                        }
                    } header: {
                        header
                    }
                }
            }
            // 縦に送った量だけを時刻の列へ渡す（この値を読むのは時刻の列だけなので、番組の欄は描き直さない）
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
                rulerScroll.y = y
            }
            .overlay(alignment: .topLeading) {
                FloatingRuler(scroll: rulerScroll, top: headerHeight) { rulerContent }
            }
            .overlay(alignment: .topLeading) { corner }
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
            stationHeaders
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

    @ViewBuilder private var stationHeaders: some View {
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

    /// 1 時間目・2 時間目… の印（今の時刻へ送る先にもなる）
    private struct RulerHour: Hashable {
        let index: Int
    }

    /// 時刻の列の幅の空き。1 時間ごとに「今」で送る先の印を置く（時刻の列そのものはスクロールの外に重ねる）
    private var hourAnchors: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { index in
                Color.clear
                    .frame(width: GuideLayout.rulerWidth, height: 60 * GuideLayout.pointsPerMinute)
                    .id(RulerHour(index: index))
            }
        }
    }

    /// 時刻の列の中身（番組の欄の上に重なるので、背景を塗って下の欄を隠す）
    private var rulerContent: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { index in
                    Text(ProgramGuide.hourLabel(index))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                        .frame(width: GuideLayout.rulerWidth, height: 60 * GuideLayout.pointsPerMinute, alignment: .top)
                        .overlay(alignment: .top) { GuideRule(axis: .horizontal) }
                }
            }
            nowLine(width: GuideLayout.rulerWidth)
        }
        .background(GuideLayout.frameBackground)
        .overlay(alignment: .trailing) { GuideRule(axis: .vertical) }
    }

    /// 今の時刻の線（選んだ日が今日のとき）。時刻の列と番組の欄で別々に引く（時刻の列はスクロールの外に重ねるため）
    @ViewBuilder private func nowLine(width: CGFloat) -> some View {
        let now = model.guideNow
        if let day = selectedDay, day.contains(now) {
            Rectangle()
                .fill(.red)
                .frame(width: width, height: 2)
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
    let genreStyle: GuideGenreStyle
    let genreColors: GuideGenreColors
    let select: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(column.coverage == nil ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.background))
            ForEach(column.placements) { placement in
                ProgramCell(placement: placement, now: now, genreStyle: genreStyle,
                            genreColor: placement.event.genre.map { genreColors.color(for: GuideGenreCategory($0)) }, select: select)
                    .offset(y: CGFloat(placement.offsetMinutes) * GuideLayout.pointsPerMinute)
            }
        }
        .frame(width: GuideLayout.columnWidth, height: height, alignment: .topLeading)
        .clipped()
        .overlay(alignment: .leading) { GuideRule(axis: .vertical) }
        // マウスの見張りは列ごとに 1 つにし、下の番組を位置から割り出す。番組の欄ごとに見張ると数百になり、
        // スクロールのたびにすべての見張りの範囲を直すので、縦も横も重くなった
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hover(at: location.y)
            case .ended: hover(at: nil)
            }
        }
        .popover(item: $detail, attachmentAnchor: .rect(.rect(detailRect)), arrowEdge: .trailing) { placement in
            ProgramDetail(event: placement.event)
        }
        .onDisappear { hoverTask?.cancel() }
    }

    /// マウスの下の番組（吹き出しを出す候補）・出している番組・出すまでの待ち
    @State private var hovered: GuidePlacement.ID?
    @State private var detail: GuidePlacement?
    @State private var hoverTask: Task<Void, Never>?

    /// 吹き出しの矢印を向ける番組の欄
    private var detailRect: CGRect {
        guard let detail else { return .zero }
        return CGRect(x: 0, y: CGFloat(detail.offsetMinutes) * GuideLayout.pointsPerMinute,
                      width: GuideLayout.columnWidth, height: CGFloat(detail.lengthMinutes) * GuideLayout.pointsPerMinute)
    }

    /// マウスの縦の位置から下の番組を割り出し、番組が替わったときだけ待ち直す（同じ番組の上で動かしても何もしない）
    private func hover(at y: CGFloat?) {
        let minutes = y.map { Double($0 / GuideLayout.pointsPerMinute) }
        let placement = minutes.flatMap { m in
            column.placements.first { m >= $0.offsetMinutes && m < $0.offsetMinutes + $0.lengthMinutes }
        }
        guard placement?.id != hovered else { return }
        hovered = placement?.id
        hoverTask?.cancel()
        detail = nil
        guard let placement else { return }
        hoverTask = Task {
            try? await Task.sleep(for: GuidePopover.hoverDelay)
            guard !Task.isCancelled else { return }
            detail = placement
        }
    }
}

/// 1 番組の欄
private struct ProgramCell: View {
    let placement: GuidePlacement
    let now: Date
    let genreStyle: GuideGenreStyle
    /// ジャンルの色。ジャンルが無い番組は nil（色を付けない）
    let genreColor: Color?
    let select: () -> Void

    private var event: BroadcastEvent { placement.event }
    private var height: CGFloat { CGFloat(placement.lengthMinutes) * GuideLayout.pointsPerMinute }
    private var isOnAir: Bool {
        guard let start = event.start else { return false }
        return start <= now && now < (event.end ?? start)
    }
    private var hasEnded: Bool { (event.end ?? .distantFuture) <= now }

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

/// 縦に送った量。番組表の本体は読まず、時刻の列だけが読む（読む view だけが描き直される）
@MainActor
@Observable
private final class RulerScroll {
    var y: CGFloat = 0
}

/// スクロールの外に重ねる時刻の列。横には動かず、縦は送った量だけずらす。局名の行の下で切る。
///
/// 1.0.2 の後に一度、時刻の列を局の列と同じ横の並びの「左に留める見出し」にした。横に送るたびに並び全体（全局の番組の欄）の
/// 配置を計算し直すことになり、横のスクロールだけがもたついたので、スクロールの外へ出した
private struct FloatingRuler<Content: View>: View {
    let scroll: RulerScroll
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

/// 番組表の区切り線。overlay に `Divider` を置くと向きが定まらず、横線のつもりが列の中央に縦線として出たので、向きを決めて引く
private struct GuideRule: View {
    let axis: Axis

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}
