import AppKit
import SwiftUI

/// 番組表で、番組の欄をジャンルの色でどう示すか。
enum GuideGenreStyle: String, CaseIterable, Codable, Identifiable {
    /// 欄の左端に色の帯
    case stripe
    /// 欄の背景を淡い色で塗る
    case background
    /// 帯と背景の両方
    case both
    /// 使わない
    case none

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .stripe: "左端に色の帯"
        case .background: "背景を塗る"
        case .both: "帯と背景の両方"
        case .none: "使わない"
        }
    }

    var showsStripe: Bool { self == .stripe || self == .both }
    var paintsBackground: Bool { self == .background || self == .both }
}

/// 番組表の色の決まり
enum GuideGenreLayout {
    /// 左端の色の帯の幅
    static let stripeWidth: CGFloat = 4
    /// 背景を塗るときに放送中の番組を囲む枠の太さ。色は帯と同じジャンルの色にする（帯が枠の左の辺に重なる）。
    /// 帯と同じ 4pt では表の中で太すぎたので、帯より細くした
    static let onAirOutlineWidth: CGFloat = 2
    /// 背景を塗るときの濃さ（ライト・ダークのどちらでも文字が読める淡さ）
    static let backgroundOpacity: Double = 0.22
}

/// ジャンルの大分類（ARIB STD-B10 の content_nibble_level_1）。色はこの単位で付ける
enum GuideGenreCategory: UInt8, CaseIterable, Identifiable {
    case news = 0x0
    case sports = 0x1
    case information = 0x2
    case drama = 0x3
    case music = 0x4
    case variety = 0x5
    case movie = 0x6
    case anime = 0x7
    case documentary = 0x8
    case theater = 0x9
    case hobby = 0xA
    case welfare = 0xB
    case other = 0xF

    var id: UInt8 { rawValue }

    /// 番組のジャンルの大分類。予備（0xC・0xD）は「その他」に入れる
    init(_ genre: ProgramGenre) {
        self = GuideGenreCategory(rawValue: genre.major) ?? .other
    }

    var name: LocalizedStringKey {
        switch self {
        case .news: "ニュース／報道"
        case .sports: "スポーツ"
        case .information: "情報／ワイドショー"
        case .drama: "ドラマ"
        case .music: "音楽"
        case .variety: "バラエティ"
        case .movie: "映画"
        case .anime: "アニメ／特撮"
        case .documentary: "ドキュメンタリー／教養"
        case .theater: "劇場／公演"
        case .hobby: "趣味／教育"
        case .welfare: "福祉"
        case .other: "その他"
        }
    }

    /// 既定の色（sRGB の 16 進）。色相が隣り合うジャンルどうしで紛れないように選んだ
    var defaultHex: String {
        switch self {
        case .news: "#3B82F6"
        case .sports: "#22A355"
        case .information: "#F59E0B"
        case .drama: "#DC2626"
        case .music: "#EC4899"
        case .variety: "#F97316"
        case .movie: "#6366F1"
        case .anime: "#06B6D4"
        case .documentary: "#65A30D"
        case .theater: "#B45309"
        case .hobby: "#14B8A6"
        case .welfare: "#78716C"
        case .other: "#9CA3AF"
        }
    }
}

/// ジャンルごとの色と、色を付けるか。設定で変えた色だけを持ち、無いものは既定の色を使う。
/// 色を付けないジャンルの番組は、番組表でジャンルの無い番組と同じに出す
struct GuideGenreColors: Codable, Equatable {
    /// 大分類（rawValue）→ sRGB の 16 進
    var custom: [UInt8: String] = [:]
    /// 色を付けない大分類（rawValue）。既定はすべてに付ける
    var uncolored: Set<UInt8> = []

    func color(for category: GuideGenreCategory) -> Color {
        Color(hex: custom[category.rawValue] ?? category.defaultHex) ?? .gray
    }

    mutating func set(_ color: Color, for category: GuideGenreCategory) {
        let hex = color.hexString
        custom[category.rawValue] = hex == category.defaultHex ? nil : hex
    }

    /// このジャンルの番組に色を付けるか
    func isColored(_ category: GuideGenreCategory) -> Bool {
        !uncolored.contains(category.rawValue)
    }

    mutating func setColored(_ colored: Bool, for category: GuideGenreCategory) {
        if colored {
            uncolored.remove(category.rawValue)
        } else {
            uncolored.insert(category.rawValue)
        }
    }

    /// 色がすべて既定か（「既定の色に戻す」で使う。色を付けるかどうかは含めない）
    var isDefault: Bool { custom.isEmpty }
}

extension GuideGenreColors {
    private enum CodingKeys: String, CodingKey {
        case custom
        case uncolored
    }

    /// 前の版（1.1.x）の記録には `uncolored` が無いので、無ければすべてに色を付ける（変えた色は残す）
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        custom = try container.decodeIfPresent([UInt8: String].self, forKey: .custom) ?? [:]
        uncolored = try container.decodeIfPresent(Set<UInt8>.self, forKey: .uncolored) ?? []
    }
}

/// ジャンルの色を前もって作った表。番組の欄ごとに色の文字列を読み直さないよう、番組表を描くたびに 1 回だけ作って配る。
/// 色を付けないジャンルは表に入れない
struct GuideGenrePalette: Equatable {
    private let colors: [GuideGenreCategory: Color]

    init(_ colors: GuideGenreColors) {
        self.colors = Dictionary(uniqueKeysWithValues: GuideGenreCategory.allCases.filter(colors.isColored).map { ($0, colors.color(for: $0)) })
    }

    /// 番組のジャンルの色。色を付けないジャンルなら nil（ジャンルの無い番組と同じに出す）
    func color(for genre: ProgramGenre) -> Color? {
        colors[GuideGenreCategory(genre)]
    }
}

extension Color {
    /// 「#RRGGBB」から（sRGB）
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(.sRGB, red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// 「#RRGGBB」（sRGB）。色の選択で別の色空間の色が来ても sRGB に直してから書く
    var hexString: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        func component(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", component(color.redComponent), component(color.greenComponent), component(color.blueComponent))
    }
}
