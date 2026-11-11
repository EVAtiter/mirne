import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 設定の画面の寸法。
enum SettingsLayout {
    static let width: CGFloat = 560
    /// 外部フィルタの欄は説明が長いので、保存ボタンまでスクロールせずに見える高さにする
    static let filterPaneHeight: CGFloat = 560
    /// チャンネルの表の高さ（地上波の 11〜12 局が並ぶくらい）
    static let channelListHeight: CGFloat = 380
    /// 名前の上書きの欄の幅
    static let channelNameFieldWidth: CGFloat = 220
    /// 並べ替えのつかむ印の大きさ（つかみやすいよう、印より広く取る）
    static let channelDragHandleWidth: CGFloat = 24
    /// 番組表の欄は 13 のジャンルの色が並ぶので、示し方とあわせてスクロールせずに見える高さにする
    static let guidePaneHeight: CGFloat = 820
    /// 説明の吹き出しの幅
    static let notePopoverWidth: CGFloat = 380
}

/// 設定の欄の説明。1 行だけ出し、続きは「?」を押すと吹き出しで出す（1 行に収まる説明は `details` を空にする）
struct SettingsNote: View {
    let summary: Text
    let details: [String]
    @State private var showsDetails = false

    init(_ summary: Text, details: [String] = []) {
        self.summary = summary
        self.details = details
    }

    init(_ summary: String, details: [String] = []) {
        self.init(Text(summary), details: details)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            summary
            if !details.isEmpty {
                Button {
                    showsDetails.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("説明を表示")
                .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(details, id: \.self) { Text($0) }
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: SettingsLayout.notePopoverWidth, alignment: .leading)
                    .padding()
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// 設定の画面。外部フィルタ・coaxd の場所・チャンネルの編集・デインターレース・字幕の既定。
struct SettingsView: View {
    let model: ViewerModel

    var body: some View {
        TabView {
            FilterSettingsPane(model: model)
                .tabItem { Label("外部フィルタ", systemImage: "line.3.horizontal.decrease.circle") }
            TunerSettingsPane(model: model)
                .tabItem { Label("チューナー", systemImage: "antenna.radiowaves.left.and.right") }
            ChannelSettingsPane(model: model)
                .tabItem { Label("チャンネル", systemImage: "list.number") }
            VideoSettingsPane(model: model)
                .tabItem { Label("映像", systemImage: "tv") }
            GuideSettingsPane(model: model)
                .tabItem { Label("番組表", systemImage: "list.bullet.rectangle") }
#if MIRNE_LAN
            LANSettingsTab(model: model)
#endif
        }
        .frame(width: SettingsLayout.width)
    }
}

/// 外部フィルタ。説明は一般的な書き方だけにする
private struct FilterSettingsPane: View {
    let model: ViewerModel
    @State private var commandLine = ""
    @State private var environmentText = ""
    @State private var usesPCSC = false
    @State private var saved = true

    var body: some View {
        Form {
            Section {
                TextField("コマンド", text: $commandLine, prompt: Text("使わないときは空のまま"))
                    .font(.system(.body, design: .monospaced))
                Toggle("coax pcsc のソケットを渡す", isOn: $usesPCSC)
                VStack(alignment: .leading, spacing: 4) {
                    Text("環境変数（1 行に 1 つ、名前=値）")
                    TextEditor(text: $environmentText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 64)
                }
            } footer: {
                SettingsNote("受信した TS をこのコマンドに通してから再生します。", details: [
                    "受信した TS を標準入力に渡し、標準出力から返ってきた TS を再生します。コマンドは /bin/sh で実行します。",
                    "コマンドは、標準入力が終わったら（EOF）終了するものにしてください。mirne が止めるときは、起動したプロセスをまとめて止めます。",
                    "「coax pcsc のソケットを渡す」をオンにすると、同梱の coax pcsc を起動し、そのソケットのパスを環境変数 PCSCLITE_CSOCK_NAME で渡します。",
                    "変更は、次に選局したときから使います。",
                ])
            }
            HStack {
                Spacer()
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saved)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: SettingsLayout.filterPaneHeight)
        .onAppear(perform: load)
        .onChange(of: commandLine) { saved = false }
        .onChange(of: environmentText) { saved = false }
        .onChange(of: usesPCSC) { saved = false }
    }

    private func load() {
        let settings = model.filterSettings
        commandLine = settings.command.map(FilterCommandText.display) ?? ""
        environmentText = (settings.command?.environment ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        usesPCSC = settings.usesPCSC
        saved = true
    }

    private func save() {
        let line = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = line.isEmpty ? nil : ExternalFilterCommand(executable: "/bin/sh", arguments: ["-c", line],
                                                                 environment: FilterCommandText.environment(from: environmentText))
        model.filterSettings = FilterSettings(command: command, usesPCSC: usesPCSC)
        saved = true
    }
}

/// 外部フィルタのコマンドと文字列の行き来。
enum FilterCommandText {
    /// 画面に出すコマンドの行（`/bin/sh -c` で包んだものは中身だけ）
    static func display(_ command: ExternalFilterCommand) -> String {
        if command.executable == "/bin/sh", command.arguments.first == "-c", command.arguments.count == 2 {
            return command.arguments[1]
        }
        return ([command.executable] + command.arguments).joined(separator: " ")
    }

    /// 「名前=値」の行から環境変数を読む。= の無い行と空行は読み飛ばす
    static func environment(from text: String) -> [String: String] {
        var environment: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let equal = trimmed.firstIndex(of: "="), equal != trimmed.startIndex else { continue }
            environment[String(trimmed[..<equal])] = String(trimmed[trimmed.index(after: equal)...])
        }
        return environment
    }
}

/// coaxd の場所
private struct TunerSettingsPane: View {
    @Bindable var model: ViewerModel
    @State private var usesBundled = AppSettings.coaxdPath == nil
    @State private var path = AppSettings.coaxdPath ?? ""

    var body: some View {
        Form {
            Section {
                Picker("coaxd", selection: $usesBundled) {
                    Text("同梱の coaxd を使う").tag(true)
                    Text("指定した coaxd を使う").tag(false)
                }
                .pickerStyle(.radioGroup)
                HStack {
                    TextField("場所", text: $path, prompt: Text("/path/to/coaxd"))
                        .font(.system(.body, design: .monospaced))
                    Button("選ぶ…", action: choose)
                }
                .disabled(usesBundled)
            } footer: {
                SettingsNote("変更は、mirne を起動し直したときから使います。")
            }
            Section {
                Toggle("起動したときに前回の局を選局する", isOn: $model.autoTuneLastChannel)
            }
        }
        .formStyle(.grouped)
        .onChange(of: usesBundled) { store() }
        .onChange(of: path) { store() }
    }

    private func store() {
        AppSettings.coaxdPath = usesBundled ? nil : path
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}

/// 映像と字幕の既定
/// チャンネルの編集。局の単位で、表示・非表示、並べ替え（ドラッグ）、名前の上書き
private struct ChannelSettingsPane: View {
    @Bindable var model: ViewerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.editableStations.isEmpty {
                Text("チャンネルスキャンをすると、ここで局の表示・並び・名前を変えられます。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: SettingsLayout.channelListHeight)
            } else {
                // List の並べ替え（onMove）は行のどこをつかんでも動くので、右端の印だけをつかめるよう自前で並べる
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.editableStations) { entry in
                            ChannelEditRow(model: model, entry: entry, dragging: $dragging)
                                .onDrop(of: [ChannelDrag.type], delegate: ChannelDropDelegate(
                                    target: entry.channel.stationKey, dragging: $dragging, model: model))
                            Divider()
                        }
                    }
                }
                .frame(height: SettingsLayout.channelListHeight)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack {
                    SettingsNote(Text("右端の \(Image(systemName: "line.3.horizontal")) をドラッグすると並べ替えられます。"), details: [
                        "右端の印をドラッグすると並べ替えられます。",
                        "隠した局はサイドバー・↑↓・数字キーで選べなくなります。",
                    ])
                    Spacer()
                    Button("元に戻す") { model.channelEdits = ChannelEdits() }
                        .disabled(model.channelEdits.isEmpty)
                }
            }
        }
        .padding()
    }

    /// ドラッグ中の局（`stationKey`）
    @State private var dragging: String?
}

/// 並べ替えのドラッグで運ぶもの。mirne だけの種類にして、名前の欄（文字を受け取る）に落ちないようにする
enum ChannelDrag {
    static let type = UTType(exportedAs: "com.slack-kingdom.mirne.station")

    static func provider(for key: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(Data(key.utf8), nil)
            return nil
        }
        return provider
    }
}

/// 局の行に重なったら、ドラッグ中の局をその位置へ動かす（離すまで待たずに並びが変わる）
private struct ChannelDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let model: ViewerModel

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        var keys = model.editableStations.map(\.channel.stationKey)
        guard let from = keys.firstIndex(of: dragging), let to = keys.firstIndex(of: target) else { return }
        keys.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        withAnimation(.easeInOut(duration: 0.15)) { model.channelEdits.order = keys }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// チャンネルの表の 1 行：並べ替えのつかむ印・表示のチェック・リモコンキー・名前の上書き
private struct ChannelEditRow: View {
    @Bindable var model: ViewerModel
    let entry: ChannelList.Entry
    @Binding var dragging: String?
    /// 名前の欄の文字。上書きしていなくても元の名前を入れておき、そのまま書き換えられるようにする。
    /// 欄の文字を上書きの値から毎回作ると、全部消した瞬間に元の名前が戻って入力し直せないので、行の中で持つ
    @State private var text = ""
    @FocusState private var editing: Bool

    private var key: String { entry.channel.stationKey }
    private var isVisible: Bool { !model.channelEdits.hidden.contains(key) }
    private var original: String { model.originalName(of: entry.channel) }
    /// 今の名前（上書きがあればそれ、無ければ元の名前）
    private var currentName: String { model.channelEdits.names[key] ?? original }

    var body: some View {
        HStack(spacing: 10) {
            // リストの行の中の Toggle(.checkbox) は浮いて見えるので、画像のボタンで出す
            Button {
                if isVisible { model.channelEdits.hidden.insert(key) } else { model.channelEdits.hidden.remove(key) }
            } label: {
                Image(systemName: isVisible ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isVisible ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isVisible ? "一覧から隠す" : "一覧に出す")
            Text(entry.remoteControlKey.map(String.init) ?? "–")
                .font(.system(.body, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            TextField("名前", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: SettingsLayout.channelNameFieldWidth)
                .focused($editing)
            Text(original)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            // 並べ替えのつかむ印。ここをつかんだときだけ動かせる
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: SettingsLayout.channelDragHandleWidth, height: SettingsLayout.channelDragHandleWidth)
                .contentShape(Rectangle())
                .help("ドラッグして並べ替える")
                .onDrag {
                    dragging = key
                    return ChannelDrag.provider(for: key)
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .opacity(isVisible ? 1 : 0.5)
        .onAppear { text = currentName }
        // 書き換えたら上書きに。元の名前と同じか空なら、上書きを外す（元の名前で出る）
        .onChange(of: text) {
            let name: String? = text.isEmpty || text == original ? nil : text
            if model.channelEdits.names[key] != name { model.channelEdits.names[key] = name }
        }
        // 欄から離れたときに空なら、元の名前を入れ直す
        .onChange(of: editing) {
            if !editing, text.isEmpty { text = original }
        }
        // 「元に戻す」などで上書きが外から変わったら、欄も合わせる（入力中は触らない）
        .onChange(of: model.channelEdits.names[key]) {
            if !editing, text != currentName { text = currentName }
        }
    }
}

private struct VideoSettingsPane: View {
    @Bindable var model: ViewerModel

    var body: some View {
        Form {
            Picker("デインターレース", selection: $model.deinterlace) {
                Text("動き適応（既定）").tag(DeinterlaceMode.adaptive)
                Text("bob").tag(DeinterlaceMode.bob)
                Text("しない（weave）").tag(DeinterlaceMode.weave)
            }
            Toggle("起動したときに字幕を表示する", isOn: $model.captionsByDefault)
        }
        .formStyle(.grouped)
    }
}

/// 番組表：ジャンルの示し方と、ジャンルごとの色
private struct GuideSettingsPane: View {
    @Bindable var model: ViewerModel

    var body: some View {
        Form {
            Section {
                Picker("ジャンルの示し方", selection: $model.guideGenreStyle) {
                    ForEach(GuideGenreStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
            } footer: {
                SettingsNote("番組のジャンルは、放送の番組情報から集めます。", details: [
                    "番組のジャンルは、放送の番組情報から集めます。",
                    "まだ集め直していない番組には色が付きません。",
                ])
            }
            Section {
                ForEach(GuideGenreCategory.allCases) { category in
                    HStack {
                        Toggle(isOn: colored(category)) { Text(category.name) }
                            .toggleStyle(.checkbox)
                        Spacer()
                        // 色を付けないジャンルの色は使わないので、選べなくする
                        ColorPicker(category.name, selection: color(for: category), supportsOpacity: false)
                            .labelsHidden()
                            .disabled(!model.guideGenreColors.isColored(category))
                    }
                }
                // 色だけを既定に戻す（色を付けるかどうかはそのまま）
                Button("既定の色に戻す") {
                    model.guideGenreColors = GuideGenreColors(uncolored: model.guideGenreColors.uncolored)
                }
                .disabled(model.guideGenreColors.isDefault)
            } header: {
                Text("ジャンルの色")
            } footer: {
                SettingsNote("チェックを外したジャンルの番組には色を付けず、ジャンルの無い番組と同じに出します。")
            }
            .disabled(model.guideGenreStyle == .none)
        }
        .formStyle(.grouped)
        .frame(height: SettingsLayout.guidePaneHeight)
    }

    /// このジャンルの番組に色を付けるか
    private func colored(_ category: GuideGenreCategory) -> Binding<Bool> {
        Binding {
            model.guideGenreColors.isColored(category)
        } set: { colored in
            model.guideGenreColors.setColored(colored, for: category)
        }
    }

    private func color(for category: GuideGenreCategory) -> Binding<Color> {
        Binding {
            model.guideGenreColors.color(for: category)
        } set: { color in
            model.guideGenreColors.set(color, for: category)
        }
    }
}
