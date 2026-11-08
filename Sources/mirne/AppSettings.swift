import Foundation

/// アプリの設定の読み書き（UserDefaults）。設定画面は SettingsView。
enum AppSettings {
    private enum Key {
        /// 外部フィルタの設定（FilterSettings の JSON）
        static let externalFilter = "externalFilter"
        /// 音量（0〜1）
        static let volume = "volume"
        /// 外部の coaxd のパス（無ければ同梱品）
        static let coaxdPath = "coaxdPath"
        /// デインターレースの方式（DeinterlaceMode の rawValue）
        static let deinterlace = "deinterlace"
        /// 字幕を最初から出すか
        static let captionsByDefault = "captionsByDefault"
        /// 視聴ウィンドウを常に最前面にするか
        static let alwaysOnTop = "alwaysOnTop"
        /// 起動したときに前回の局を選局するか
        static let autoTuneLastChannel = "autoTuneLastChannel"
        /// 最後に選んだサービス（ChannelList.Entry.id）
        static let lastChannel = "lastChannel"
        /// チャンネル一覧の編集（ChannelEdits の JSON）
        static let channelEdits = "channelEdits"
        /// 視聴ウィンドウの位置と大きさ（ViewerWindowPlacement の JSON）
        static let viewerWindowPlacement = "viewerWindowPlacement"
        /// 視聴ウィンドウのサイドバー（チャンネル一覧）を出しているか
        static let viewerSidebarVisible = "viewerSidebarVisible"
        /// 番組表でジャンルをどう示すか（GuideGenreStyle の rawValue）
        static let guideGenreStyle = "guideGenreStyle"
        /// 番組表のジャンルの色（GuideGenreColors の JSON）
        static let guideGenreColors = "guideGenreColors"
        /// 番組表のウィンドウの位置と大きさ（GuideWindowPlacement の JSON）
        static let guideWindowPlacement = "guideWindowPlacement"
    }

    /// 外部フィルタの設定。未設定ならフィルタを使わない
    static var filter: FilterSettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: Key.externalFilter),
                  let settings = try? JSONDecoder().decode(FilterSettings.self, from: data) else { return FilterSettings() }
            return settings
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Key.externalFilter)
        }
    }

    /// 外部の coaxd のパス。nil なら同梱品を使う
    static var coaxdPath: String? {
        get { UserDefaults.standard.string(forKey: Key.coaxdPath).flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue, forKey: Key.coaxdPath) }
    }

    /// 使う coaxd（指定があればそれ、無ければ同梱品）
    static func coaxdExecutable() -> URL? {
        coaxdPath.map { URL(fileURLWithPath: $0) } ?? CoaxdLauncher.locate()
    }

    /// デインターレースの方式（既定は動き適応）
    static var deinterlace: DeinterlaceMode {
        get {
            (UserDefaults.standard.object(forKey: Key.deinterlace) as? UInt32).flatMap(DeinterlaceMode.init(rawValue:)) ?? .adaptive
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.deinterlace) }
    }

    /// 字幕の既定。起動したときに字幕を出すか。未設定なら出さない
    static var captionsByDefault: Bool {
        get { UserDefaults.standard.bool(forKey: Key.captionsByDefault) }
        set { UserDefaults.standard.set(newValue, forKey: Key.captionsByDefault) }
    }

    /// 視聴ウィンドウを常に最前面にするか。次に起動しても続く。未設定なら普通の窓
    static var alwaysOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: Key.alwaysOnTop) }
        set { UserDefaults.standard.set(newValue, forKey: Key.alwaysOnTop) }
    }

    /// 起動したときに前回の局を選局するか。未設定なら選局する（設定で切れる）
    static var autoTuneLastChannel: Bool {
        get { UserDefaults.standard.object(forKey: Key.autoTuneLastChannel) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.autoTuneLastChannel) }
    }

    /// 最後に選んだサービス（`ChannelList.Entry.id`。周波数とサービス ID）。未選択なら nil
    static var lastChannel: String? {
        get { UserDefaults.standard.string(forKey: Key.lastChannel) }
        set { UserDefaults.standard.set(newValue, forKey: Key.lastChannel) }
    }

    /// チャンネル一覧の編集（並び・隠す・名前の上書き）。スキャンの結果とは別に持つ
    static var channelEdits: ChannelEdits {
        get {
            UserDefaults.standard.data(forKey: Key.channelEdits)
                .flatMap { try? JSONDecoder().decode(ChannelEdits.self, from: $0) } ?? ChannelEdits()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Key.channelEdits) }
    }

    /// 視聴ウィンドウの位置と大きさ。未設定なら nil
    static var viewerWindowPlacement: ViewerWindowPlacement? {
        get {
            UserDefaults.standard.data(forKey: Key.viewerWindowPlacement)
                .flatMap { try? JSONDecoder().decode(ViewerWindowPlacement.self, from: $0) }
        }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.viewerWindowPlacement) }
    }

    /// 視聴ウィンドウのサイドバー（チャンネル一覧）を出しているか。次に起動しても続く。未設定なら出す
    static var viewerSidebarVisible: Bool {
        get { UserDefaults.standard.object(forKey: Key.viewerSidebarVisible) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.viewerSidebarVisible) }
    }

    /// 番組表でジャンルをどう示すか。未設定なら左端の色の帯
    static var guideGenreStyle: GuideGenreStyle {
        get { UserDefaults.standard.string(forKey: Key.guideGenreStyle).flatMap(GuideGenreStyle.init(rawValue:)) ?? .stripe }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.guideGenreStyle) }
    }

    /// 番組表のジャンルの色。未設定なら既定の色
    static var guideGenreColors: GuideGenreColors {
        get {
            UserDefaults.standard.data(forKey: Key.guideGenreColors)
                .flatMap { try? JSONDecoder().decode(GuideGenreColors.self, from: $0) } ?? GuideGenreColors()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Key.guideGenreColors) }
    }

    /// 番組表のウィンドウの位置と大きさ。未設定なら nil
    static var guideWindowPlacement: GuideWindowPlacement? {
        get {
            UserDefaults.standard.data(forKey: Key.guideWindowPlacement)
                .flatMap { try? JSONDecoder().decode(GuideWindowPlacement.self, from: $0) }
        }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.guideWindowPlacement) }
    }

    /// 音量の記憶。未設定なら nil
    static var volume: Float? {
        get { UserDefaults.standard.object(forKey: Key.volume) as? Float }
        set { UserDefaults.standard.set(newValue, forKey: Key.volume) }
    }
}
