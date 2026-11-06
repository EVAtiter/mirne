// coax の pkg/isdb/caption/caption.go（Copyright 2026 Till0196・SPDX-License-Identifier: Apache-2.0 OR GPL-2.0-or-later）を、
// mirne（Apache-2.0）へ Apache-2.0 の条件で Swift に移植したもの。
// 違い: TS の字幕だけを移した（MMT の字幕・ワンセグ（C プロファイル）の配置は移していない）。
// 縦書きは画面の大きさと字間の既定だけを受け取り、配置は横書きとして行う（縦書きの配置は扱わない）。

import Foundation

/// 字幕か文字スーパーか（PES の data_identifier）。
public enum CaptionKind: Sendable, Equatable {
    /// 字幕（0x80）
    case caption
    /// 文字スーパー（0x81）
    case superimpose
}

/// 字幕 PES の 1 つのデータグループ（ARIB STD-B24 第一編 第三部 第 9 章）。管理データか本文データのどちらか一方
public struct CaptionGroup: Sendable {
    public let kind: CaptionKind
    /// data_group_id（0x0・0x20 が管理、0x1〜0x8・0x21〜0x28 が本文。0x20 のビットは組 B）
    public let id: UInt8
    public let management: CaptionManagement?
    public let statement: CaptionStatement?

    public var isManagement: Bool { id & 0x0F == 0 }

    /// 本文データの言語番号（1〜8）。管理データなら nil
    public var language: UInt8? {
        let number = id & 0x0F
        return number == 0 ? nil : number
    }
}

/// 字幕の管理データ（言語と画面の形）
public struct CaptionManagement: Sendable {
    /// 時刻制御モード（0 自由・1 実時刻・2 オフセット）
    public let timeMode: UInt8
    public let languages: [CaptionLanguage]
    public let units: [CaptionUnit]
}

/// 管理データの 1 言語
public struct CaptionLanguage: Sendable, Equatable {
    /// 言語番号（0〜7。本文データの data_group_id の下位ビットから 1 を引いたもの）
    public let tag: UInt8
    /// 表示モード（上位 2 ビットが受信時、下位 2 ビットが録画再生時）
    public let displayMode: UInt8
    /// ISO 639 の言語コード（"jpn" など）
    public let languageCode: String
    /// 表示書式（表 8-4）
    public let format: UInt8
    /// 文字符号化方式（0 が 8 単位符号）
    public let characterCoding: UInt8
    public let rollup: UInt8
}

/// 字幕の本文データ
public struct CaptionStatement: Sendable {
    /// 時刻制御モード
    public let timeMode: UInt8
    /// 提示の時刻（ミリ秒。時刻制御モードが 1・2 のときだけ）
    public let presentationTime: UInt64?
    public let units: [CaptionUnit]
}

/// データユニット 1 つ
public struct CaptionUnit: Sendable {
    public enum Kind: Sendable, Equatable {
        /// 8 単位符号の本文
        case text
        /// DRCS の図形（表 D-1）。`twoByte` は 0x31（2 バイトの DRCS-0）か 0x30（1 バイトの DRCS-1〜15）か
        case drcs(twoByte: Bool)
        /// そのほか（ビットマップ・ジオメトリックなど）
        case other
    }

    public let kind: Kind
    /// data_unit_parameter
    public let parameter: UInt8
    public let data: [UInt8]
}

/// 色。a が 0 なら透明
public struct CaptionColor: Sendable, Hashable {
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8

    public static let transparent = CaptionColor(r: 0, g: 0, b: 0, a: 0)
    public static let white = CaptionColor(r: 255, g: 255, b: 255, a: 255)
    public static let black = CaptionColor(r: 0, g: 0, b: 0, a: 255)

    /// 既定の CLUT の色（0〜127。ARIB STD-B24 第一編 第二部 表 8-8。値は受信機のもの）
    public static func indexed(_ index: UInt8) -> CaptionColor {
        let entry = CaptionCLUT.colors[Int(index & 0x7F)]
        return CaptionColor(r: entry.0, g: entry.1, b: entry.2, a: entry.3)
    }
}

/// DRCS の図形 1 つ（放送が送ってくる文字の形）
public struct CaptionDRCSGlyph: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// 階調の数（depth + 2）
    public let levels: Int
    /// 画素ごとの階調（行の順）。0 は透明、levels - 1 が文字の色
    public let bitmap: [UInt8]
}

/// DRCS の文字を割り当てる私用領域の文字（U+F0000 から）
public enum CaptionDRCS {
    /// 2 バイトの DRCS-0 は区と点で、1 バイトの DRCS-1〜15 は集合と符号で割り当てる
    public static func scalar(set: UInt8, code: UInt16, width: Int) -> Unicode.Scalar {
        func minus(_ value: UInt32, _ by: UInt32) -> UInt32 { value < by ? 0 : value - by }
        let index: UInt32
        if width == 2 || set == 0 {
            index = minus(UInt32(UInt8(code >> 8)), 0x21) * 94 + minus(UInt32(UInt8(code & 0xFF)), 0x21)
        } else {
            index = 0x3000 + UInt32(min(set, 15)) * 0x60 + minus(UInt32(UInt8(code & 0xFF)), 0x21)
        }
        return Unicode.Scalar(0xF0000 + index)!
    }

    /// DRCS の文字か
    public static func contains(_ scalar: Unicode.Scalar) -> Bool {
        (0xF0000..<0xF4000).contains(scalar.value)
    }

    /// DRCS のデータユニット（表 D-1）を読む。1 文字に形（字体・大きさ）が複数あれば、すべて返す
    public static func parse(twoByte: Bool, _ bytes: [UInt8]) -> [(scalar: Unicode.Scalar, glyph: CaptionDRCSGlyph)] {
        var out: [(scalar: Unicode.Scalar, glyph: CaptionDRCSGlyph)] = []
        guard let count = bytes.first else { return out }
        var at = 1
        for _ in 0..<count {
            guard at + 3 <= bytes.count else { break }
            let first = bytes[at], second = bytes[at + 1], fonts = Int(bytes[at + 2])
            at += 3
            let scalar = twoByte
                ? Self.scalar(set: 0, code: UInt16(first) << 8 | UInt16(second), width: 2)
                : Self.scalar(set: first & 0x0F, code: UInt16(second), width: 1)
            for _ in 0..<fonts {
                guard at + 4 <= bytes.count else { return out }
                let mode = bytes[at], depth = bytes[at + 1], width = Int(bytes[at + 2]), height = Int(bytes[at + 3])
                at += 4
                // ジオメトリック（mode 2 以上）は運用で使われない
                guard mode & 0x0F <= 1 else { return out }
                let levels = Int(depth) + 2
                var bits = 0
                var value = levels - 1
                while value > 0 { bits += 1; value >>= 1 }
                let pixels = width * height
                let length = (pixels * bits + 7) / 8
                guard at + length <= bytes.count else { return out }
                let data = bytes[at..<at + length]
                at += length
                var bitmap: [UInt8] = []
                bitmap.reserveCapacity(pixels)
                var bit = 0
                for _ in 0..<pixels {
                    var level: UInt8 = 0
                    for _ in 0..<bits {
                        let byte = data[data.startIndex + bit >> 3]
                        level = level << 1 | (byte >> (7 - UInt8(bit & 7))) & 1
                        bit += 1
                    }
                    bitmap.append(level)
                }
                out.append((scalar, CaptionDRCSGlyph(width: width, height: height, levels: levels, bitmap: bitmap)))
            }
        }
        return out
    }
}

/// 字幕 PES の解析。
public enum CaptionDecoder {
    /// data_identifier
    static let captionIdentifier: UInt8 = 0x80
    static let superimposeIdentifier: UInt8 = 0x81
    /// private_stream_id（字幕・文字スーパーでは常に 0xFF）
    static let privateStreamID: UInt8 = 0xFF
    /// データユニットの区切り（unit_separator）
    static let unitSeparator: UInt8 = 0x1F

    /// PES の中身（PES ヘッダの後ろ、data_identifier から）を読む。1 つの PES に 1 つのデータグループ。CRC は確かめない
    public static func parsePES<Bytes: Collection>(_ payload: Bytes) -> CaptionGroup? where Bytes.Element == UInt8 {
        let bytes = Array(payload)
        guard bytes.count >= 3 else { return nil }
        let kind: CaptionKind
        switch bytes[0] {
        case captionIdentifier: kind = .caption
        case superimposeIdentifier: kind = .superimpose
        default: return nil
        }
        guard bytes[1] == privateStreamID else { return nil }
        let headerLength = Int(bytes[2] & 0x0F)
        guard 3 + headerLength <= bytes.count else { return nil }
        let group = Array(bytes[(3 + headerLength)...])
        guard group.count >= 5 else { return nil }
        let id = group[0] >> 2
        let size = Int(group[3]) << 8 | Int(group[4])
        guard 5 + size <= group.count else { return nil }
        let data = Array(group[5..<(5 + size)])
        if id & 0x0F == 0 {
            guard let management = parseManagement(data) else { return nil }
            return CaptionGroup(kind: kind, id: id, management: management, statement: nil)
        }
        guard let statement = parseStatement(data) else { return nil }
        return CaptionGroup(kind: kind, id: id, management: nil, statement: statement)
    }

    private static func parseManagement(_ data: [UInt8]) -> CaptionManagement? {
        guard let first = data.first else { return nil }
        let timeMode = first >> 6
        var at = 1
        // オフセット時刻（OTM）は 5 バイト
        if timeMode == 2 { at += 5 }
        guard at < data.count else { return nil }
        let count = Int(data[at])
        at += 1
        var languages: [CaptionLanguage] = []
        for _ in 0..<count {
            guard at < data.count else { return nil }
            let tag = data[at] >> 5, displayMode = data[at] & 0x0F
            at += 1
            // 表示条件（DC）は 1 バイト
            if [0b1100, 0b1101, 0b1110].contains(displayMode) { at += 1 }
            guard at + 4 <= data.count else { return nil }
            let code = String(decoding: data[at..<at + 3], as: UTF8.self)
            let last = data[at + 3]
            at += 4
            languages.append(CaptionLanguage(tag: tag, displayMode: displayMode, languageCode: code,
                                             format: last >> 4, characterCoding: (last >> 2) & 3, rollup: last & 3))
        }
        guard let units = parseUnits(data, at: at) else { return nil }
        return CaptionManagement(timeMode: timeMode, languages: languages, units: units)
    }

    private static func parseStatement(_ data: [UInt8]) -> CaptionStatement? {
        guard let first = data.first else { return nil }
        let timeMode = first >> 6
        var at = 1
        var presentationTime: UInt64?
        if timeMode == 1 || timeMode == 2 {
            guard at + 5 <= data.count else { return nil }
            // 時・分・秒・ミリ秒の BCD（HHMMSSmmm）
            let t = data[at..<at + 5].map { $0 }
            at += 5
            func bcd(_ byte: UInt8) -> UInt64 { UInt64(byte >> 4) * 10 + UInt64(byte & 0x0F) }
            let millis = bcd(t[3]) * 10 + UInt64(t[4] >> 4)
            presentationTime = ((bcd(t[0]) * 60 + bcd(t[1])) * 60 + bcd(t[2])) * 1000 + millis
        }
        guard let units = parseUnits(data, at: at) else { return nil }
        return CaptionStatement(timeMode: timeMode, presentationTime: presentationTime, units: units)
    }

    /// データユニットを読む（3 バイトの全体の長さの後ろから）
    private static func parseUnits(_ data: [UInt8], at start: Int) -> [CaptionUnit]? {
        guard start + 3 <= data.count else { return nil }
        let total = Int(data[start]) << 16 | Int(data[start + 1]) << 8 | Int(data[start + 2])
        var at = start + 3
        let end = min(at + total, data.count)
        var out: [CaptionUnit] = []
        while at + 5 <= end, data[at] == unitSeparator {
            let parameter = data[at + 1]
            let size = Int(data[at + 2]) << 16 | Int(data[at + 3]) << 8 | Int(data[at + 4])
            let body = Array(data[(at + 5)..<min(at + 5 + size, end)])
            let kind: CaptionUnit.Kind = switch parameter {
            case 0x20: .text
            case 0x30, 0x31: .drcs(twoByte: parameter == 0x31)
            default: .other
            }
            out.append(CaptionUnit(kind: kind, parameter: parameter, data: body))
            at += 5 + size
        }
        return out
    }
}

/// 画面に置く文字の並び 1 つ。位置と大きさは字幕の画面の画素（`CaptionLayout.screenWidth`）で、描く側は拡大するだけ
public struct CaptionText: Sendable, Equatable {
    /// 左上
    public var x: Int, y: Int
    /// 1 文字の升目（中速の大きさなら幅は半分）
    public var cellWidth: Int, cellHeight: Int
    /// 文字の大きさ（升目から字間・行間を除いたもの）
    public var glyphWidth: Int, glyphHeight: Int
    public var text: String
    public var foreground: CaptionColor
    public var background: CaptionColor
    /// 縁取りの色（ORN。無ければ nil）
    public var outline: CaptionColor?
    /// 点滅（FLC）：0 なし・1 正相・2 逆相
    public var flash: UInt8
    /// 囲み（HLC）：ビット 1 右・2 下・4 左・8 上
    public var enclosure: UInt8
    /// 本文の始まりから、出すまでの待ち（TIME。ミリ秒）
    public var delay: UInt32
    /// 本文の始まりから、消すまで（TIME の後の CS。ミリ秒）。nil なら次の本文まで出したまま
    public var until: UInt32?
    /// この並びの文字の数（升目の数）
    var cells = 0
}

/// 本文全体の動き（SCR）。本文の始まりから `delay` 後に、`from` から `to` へ `duration` かけて動かす
public struct CaptionMotion: Sendable, Equatable {
    public var fromX = 0, fromY = 0
    public var toX = 0, toY = 0
    public var delay: UInt32 = 0
    public var duration: UInt32 = 0
}

/// 1 つの本文を画面に置いたもの
public struct CaptionLayout: Sendable {
    /// 字幕の画面の大きさ（SWF）
    public var screenWidth: Int, screenHeight: Int
    /// 表示領域（SDF・SDP）。背景で塗る受信機もある
    public var areaX: Int, areaY: Int, areaWidth: Int, areaHeight: Int
    /// 先に画面を消す（CS があった）
    public var clear = false
    /// TIME で待ってから消す本文なら、その時刻（ミリ秒）。それまで `texts` を出す
    public var clearAfter: UInt32?
    public var texts: [CaptionText] = []
    public var superimpose: Bool
    /// この本文が使う DRCS の形（私用領域の文字ごと）
    public var drcs: [Unicode.Scalar: [CaptionDRCSGlyph]] = [:]
    /// 表示領域を塗るラスタ色（RCS）。透明なら塗らない
    public var raster: CaptionColor
    /// 鳴らす内蔵音（PRA。1〜13）。0 なら鳴らさない
    public var sound: UInt8 = 0
    /// 本文全体の動き（スクロール）
    public var motion: CaptionMotion?
}

/// 字幕の画面の決まり（ARIB STD-B24 第一編 第二部 表 8-2・8-3、TR-B14）
enum CaptionScreen {
    /// 管理データの書式も SWF も無いときの画面（960×540 の横書き）
    static let defaultWidth = 960
    static let defaultHeight = 540
    /// 文字の大きさの既定（SSM）
    static let defaultGlyphSize = 36
    /// RPC がくり返す数の上限（いちばん広い画面をいちばん小さい文字で埋める数）。CSI で表示領域をいくらでも広く宣言できるため
    static let mostRepeat = 1920
}

/// 管理データで画面を整え、本文データを画面に置く（1 言語ぶん）。coax の Presenter
public final class CaptionPresenter {
    public let kind: CaptionKind
    /// 置く言語（1 が第 1 言語）。画面は管理データのその言語の項目で整える
    public let language: UInt8

    private struct Area { var x: Int, y: Int, width: Int, height: Int }
    private struct Setup { var area: Area, glyphWidth: Int, glyphHeight: Int, horizontalSpacing: Int, verticalSpacing: Int }

    private var screenWidth = CaptionScreen.defaultWidth
    private var screenHeight = CaptionScreen.defaultHeight
    private var area = Area(x: 0, y: 0, width: CaptionScreen.defaultWidth, height: CaptionScreen.defaultHeight)
    private var glyphWidth = CaptionScreen.defaultGlyphSize
    private var glyphHeight = CaptionScreen.defaultGlyphSize
    /// 字間（SHS）・行間（SVS）
    private var horizontalSpacing = 4
    private var verticalSpacing = 24
    private var initial: Setup
    private var inManagement = false
    /// CS の後に動作位置を動かしたか文字を置いたか。それからは SWF・SDF・SDP・RCS を受け付けない（受信機の決まり）
    private var moved = false
    /// SZX：1 標準・2 中型（幅が半分）・3 小型・4 縦倍・5 横倍・6 縦横倍
    private var sizeMode: UInt8 = 1
    private var foreground = CaptionColor.white
    private var background = CaptionColor.transparent
    private var outline: CaptionColor?
    /// COL のパレット（0〜7）。番号に 16 倍して足す
    private var palette: UInt8 = 0
    private var inverted = false
    /// x は文字の左、y は文字の下（規格の動作位置は文字の左下）
    private var x = 0
    private var y = 0
    private var hidden = false
    /// 最後に置いた文字の升目の高さ。APD・APR はこれだけ下がる（行の終わりで大きさが変わっても行が重ならないように）
    private var lastHeight: Int?
    private var vertical = false
    private var drcs: [Unicode.Scalar: [CaptionDRCSGlyph]] = [:]
    private var raster = CaptionColor.transparent
    /// RPC：次の文字をくり返す数（0 なら行の終わりまで）。nil ならくり返さない
    private var repeatCount: Int?
    private var flash: UInt8 = 0
    private var enclosure: UInt8 = 0
    private var delay: UInt32 = 0

    /// `language` 番目（1 から）の言語を置く
    public init(kind: CaptionKind, language: UInt8 = 1) {
        self.kind = kind
        self.language = max(language, 1)
        initial = Setup(area: Area(x: 0, y: 0, width: CaptionScreen.defaultWidth, height: CaptionScreen.defaultHeight),
                        glyphWidth: CaptionScreen.defaultGlyphSize, glyphHeight: CaptionScreen.defaultGlyphSize,
                        horizontalSpacing: 4, verticalSpacing: 24)
        reset(width: CaptionScreen.defaultWidth, height: CaptionScreen.defaultHeight, vertical: false)
    }

    /// 管理データで画面を整える（言語の項目の表示書式。表 8-4）
    public func manage(_ management: CaptionManagement) {
        takeDRCS(management.units)
        let entry = management.languages.first { $0.tag + 1 == language } ?? management.languages.first
        if let entry {
            // 9 は 960×540 の縦書き、10 は 720×480 の横書き、11 は縦書き、それ以外は 960×540 の横書き
            switch entry.format {
            case 9: reset(width: 960, height: 540, vertical: true)
            case 10: reset(width: 720, height: 480, vertical: false)
            case 11: reset(width: 720, height: 480, vertical: true)
            default: reset(width: 960, height: 540, vertical: false)
            }
        }
        // 管理データの中の制御符号は画面を整えるだけで、何も描かない
        var scratch = makeLayout()
        inManagement = true
        for unit in management.units where unit.kind == .text {
            text(unit.data, into: &scratch)
        }
        inManagement = false
    }

    /// 本文を 1 つ置く
    public func present(_ statement: CaptionStatement) -> CaptionLayout {
        var layout = makeLayout()
        delay = 0
        // 図形は本文の文字より後に来てもよい（1 つの本文の中なら順は問わない）
        takeDRCS(statement.units)
        for unit in statement.units where unit.kind == .text {
            text(unit.data, into: &layout)
        }
        // 使った DRCS の形だけを渡す
        for item in layout.texts {
            for scalar in item.text.unicodeScalars where CaptionDRCS.contains(scalar) {
                if layout.drcs[scalar] == nil, let glyphs = drcs[scalar] { layout.drcs[scalar] = glyphs }
            }
        }
        return layout
    }

    private func makeLayout() -> CaptionLayout {
        CaptionLayout(screenWidth: screenWidth, screenHeight: screenHeight,
                      areaX: area.x, areaY: area.y, areaWidth: area.width, areaHeight: area.height,
                      superimpose: kind == .superimpose, raster: raster)
    }

    /// 画面の大きさと向きから既定を決める（表 8-2・8-3）
    private func reset(width: Int, height: Int, vertical: Bool) {
        glyphWidth = CaptionScreen.defaultGlyphSize
        glyphHeight = CaptionScreen.defaultGlyphSize
        switch (width, height, vertical) {
        case (720, 480, false): (horizontalSpacing, verticalSpacing) = (4, 16)
        case (720, 480, true): (horizontalSpacing, verticalSpacing) = (8, 24)
        case (_, _, false): (horizontalSpacing, verticalSpacing) = (4, 24)
        default: (horizontalSpacing, verticalSpacing) = (12, 24)
        }
        screenWidth = width
        screenHeight = height
        area = Area(x: 0, y: 0, width: width, height: height)
        initial = Setup(area: area, glyphWidth: glyphWidth, glyphHeight: glyphHeight,
                        horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing)
        moved = false
        self.vertical = vertical
        sizeMode = 1
        home()
    }

    /// 動作位置を表示領域の 1 行目の始めへ
    private func home() {
        x = area.x
        y = area.y + cell().height
        hidden = false
        lastHeight = nil
    }

    private static func scaled(_ width: Int, _ height: Int, mode: UInt8) -> (width: Int, height: Int) {
        switch mode {
        case 2: (width / 2, height)
        case 3: (width / 2, height / 2)
        case 4: (width, height * 2)
        case 5: (width * 2, height)
        case 6: (width * 2, height * 2)
        default: (width, height)
        }
    }

    /// 1 文字の升目（大きさを含む）
    private func cell() -> (width: Int, height: Int) {
        Self.scaled(glyphWidth + horizontalSpacing, glyphHeight + verticalSpacing, mode: sizeMode)
    }

    private func glyph() -> (width: Int, height: Int) {
        Self.scaled(glyphWidth, glyphHeight, mode: sizeMode)
    }

    /// 動作位置の左上（画素）
    private func position() -> (x: Int, y: Int) {
        (x, y - cell().height)
    }

    private func color(_ number: UInt8) -> CaptionColor { .indexed(palette &* 16 &+ number) }

    private func setForeground(_ color: CaptionColor) {
        if inverted { background = color } else { foreground = color }
    }

    private func setBackground(_ color: CaptionColor) {
        if inverted { foreground = color } else { background = color }
    }

    /// DRCS のデータユニットを覚える。同じ文字の同じ大きさの形は前のものを置き換える
    private func takeDRCS(_ units: [CaptionUnit]) {
        for unit in units {
            guard case let .drcs(twoByte) = unit.kind else { continue }
            for entry in CaptionDRCS.parse(twoByte: twoByte, unit.data) {
                var glyphs = (drcs[entry.scalar] ?? []).filter { $0.width != entry.glyph.width || $0.height != entry.glyph.height }
                glyphs.append(entry.glyph)
                drcs[entry.scalar] = glyphs
            }
        }
    }

    private func text(_ bytes: [UInt8], into layout: inout CaptionLayout) {
        var run: CaptionText?
        for piece in CaptionPieceReader.pieces(bytes) {
            switch piece {
            case let .character(character, _):
                put(character, run: &run, layout: &layout)
            case .space:
                put(" ", run: &run, layout: &layout)
            case let .drcs(set, code, width):
                put(Character(CaptionDRCS.scalar(set: set, code: code, width: width)), run: &run, layout: &layout)
            case let .control(code):
                flush(&run, into: &layout)
                control(code, layout: &layout)
            case .lost:
                continue
            }
        }
        flush(&run, into: &layout)
    }

    private func flush(_ run: inout CaptionText?, into layout: inout CaptionLayout) {
        if let finished = run, !finished.text.isEmpty { layout.texts.append(finished) }
        run = nil
    }

    /// 1 文字置いて動作位置を進める。1 バイトの（半角の）文字も、標準の大きさでは升目 1 つを使う（表 7-14。英数も 1 升目）
    private func put(_ character: Character, run: inout CaptionText?, layout: inout CaptionLayout) {
        guard !hidden else { return }
        let cell = cell()
        let glyph = glyph()
        let position = position()
        let continues = run.map {
            $0.y == position.y && $0.cellWidth == cell.width && $0.cellHeight == cell.height
                && $0.foreground == foreground && $0.background == background && $0.outline == outline
                && $0.flash == flash && $0.enclosure == enclosure && $0.delay == delay
                && $0.x + $0.cells * cell.width == position.x
        } ?? false
        if !continues {
            flush(&run, into: &layout)
            run = CaptionText(x: position.x, y: position.y, cellWidth: cell.width, cellHeight: cell.height,
                              glyphWidth: glyph.width, glyphHeight: glyph.height, text: "",
                              foreground: foreground, background: background, outline: outline,
                              flash: flash, enclosure: enclosure, delay: delay, until: nil)
        }
        var times = 1
        if let repeatCount {
            if repeatCount == 0 {
                // 行の終わりまで
                let left = max(area.x + area.width - x, 0)
                times = max(left / max(cell.width, 1), 1)
            } else {
                times = repeatCount
            }
        }
        repeatCount = nil
        times = min(times, CaptionScreen.mostRepeat)
        for _ in 0..<times {
            run?.text.append(character)
            run?.cells += 1
        }
        advance(times)
        moved = true
        lastHeight = cell.height
    }

    /// 動作位置を 1 行下げる（APD・APR）。表示領域の下を越えたら 1 行目へ
    private func down() {
        let cell = cell()
        y += lastHeight ?? cell.height
        if y > area.y + area.height {
            y = area.y + cell.height
        }
    }

    /// 動作位置を右へ進める。表示領域の右端で次の行の始めへ（1 文字ずつ確かめる）
    private func advance(_ count: Int) {
        let cell = cell()
        for _ in 0..<max(count, 0) {
            x += cell.width
            if x >= area.x + area.width {
                x = area.x
                y += cell.height
            }
        }
    }

    private func control(_ code: [UInt8], layout: inout CaptionLayout) {
        guard let first = code.first else { return }
        let cell = cell()
        func parameter(_ index: Int) -> UInt8? { index < code.count ? code[index] : nil }
        switch first {
        case CaptionControl.activePositionBackward, CaptionControl.activePositionForward, CaptionControl.activePositionDown,
             CaptionControl.activePositionUp, CaptionControl.activePositionReturn,
             CaptionControl.parameterizedActivePositionForward, CaptionControl.activePositionSet:
            moved = true
        default:
            break
        }
        switch first {
        case CaptionControl.activePositionBackward:
            x -= cell.width
        case CaptionControl.activePositionForward:
            advance(1)
        case CaptionControl.activePositionDown:
            down()
        case CaptionControl.activePositionUp:
            y -= cell.height
        case CaptionControl.activePositionReturn:
            x = area.x
            down()
        case CaptionControl.clearScreen:
            clearScreen(layout: &layout)
        case CaptionControl.flashing:
            // 0x40 正相・0x47 逆相・0x4F 止める
            if let value = parameter(1) {
                flash = switch value {
                case 0x40: 1
                case 0x47: 2
                default: 0
                }
            }
        case CaptionControl.highlight:
            // 囲み（下位 4 ビットが右・下・左・上）
            if let value = parameter(1) { enclosure = value & 0x0F }
        case CaptionControl.time:
            // 待ち（9D 20 P は (P - 0x40) / 10 秒）。後に続くものを遅らせる
            if parameter(1) == 0x20, let value = parameter(2), value >= 0x40 {
                delay += UInt32(value - 0x40) * 100
            }
        case CaptionControl.repeatCharacter:
            // 次の文字をくり返す（0x40 なら行の終わりまで）
            if let value = parameter(1) { repeatCount = Int(value & 0x3F) }
        case CaptionControl.parameterizedActivePositionForward:
            if let value = parameter(1) { advance(Int(value & 0x3F)) }
        case CaptionControl.activePositionSet:
            // 行と列（それぞれ 0x40 を足したもの）。今の大きさで数える（表 7-9）
            if let row = parameter(1), let column = parameter(2) {
                x = area.x + Int(column & 0x3F) * cell.width
                y = area.y + (Int(row & 0x3F) + 1) * cell.height
                hidden = false
            }
        case CaptionControl.blackForeground...CaptionControl.whiteForeground:
            setForeground(color(first - CaptionControl.blackForeground))
        case CaptionControl.color:
            // 90 20 4X はパレット。4X は前景、5X は背景（下位 4 ビットが番号）。6X・7X は中間色で、描かない
            if let value = parameter(1) {
                switch value {
                case 0x20:
                    if let next = parameter(2), next & 0xF0 == 0x40 { palette = next & 0x07 }
                case 0x40...0x4F:
                    setForeground(color(value & 0x0F))
                case 0x50...0x5F:
                    setBackground(color(value & 0x0F))
                default:
                    break
                }
            }
        case CaptionControl.polarity:
            // 0x40 正転・0x41 反転（前景と背景を入れ替える）
            if let value = parameter(1) {
                let invert = value == 0x41
                if invert != inverted {
                    swap(&foreground, &background)
                    inverted = invert
                }
            }
        case CaptionControl.smallSize:
            sizeMode = 3
        case CaptionControl.middleSize:
            sizeMode = 2
        case CaptionControl.normalSize:
            sizeMode = 1
        case CaptionControl.sizeControl:
            if let value = parameter(1) {
                sizeMode = switch value {
                case 0x60: 3
                case 0x41: 4
                case 0x44: 5
                case 0x45: 6
                default: 1
                }
            }
        case CaptionControl.controlSequence:
            controlSequence(code, layout: &layout)
        default:
            break
        }
    }

    /// CS：画面を消し、表示領域・文字の大きさ・字間を整えたときの値へ、色・反転・点滅・囲み・縁取り・ラスタ色を既定へ戻す
    private func clearScreen(layout: inout CaptionLayout) {
        area = initial.area
        glyphWidth = initial.glyphWidth
        glyphHeight = initial.glyphHeight
        horizontalSpacing = initial.horizontalSpacing
        verticalSpacing = initial.verticalSpacing
        moved = false
        if delay > 0 {
            // TIME で待ってからの CS：それまでに置いたものは、そのときまで出しておく
            for index in layout.texts.indices where layout.texts[index].until == nil {
                layout.texts[index].until = delay
            }
            layout.clearAfter = delay
        } else {
            layout.clear = true
            layout.texts = []
        }
        sizeMode = 1
        home()
        foreground = .white
        background = .transparent
        palette = 0
        inverted = false
        outline = nil
        flash = 0
        enclosure = 0
        raster = .transparent
        layout.raster = .transparent
    }

    /// CSI：9B P1 3B P2 … F
    private func controlSequence(_ code: [UInt8], layout: inout CaptionLayout) {
        // 少なくとも 9B と終端。それより短いのは本文の終わりで切れた並び
        guard code.count >= 2, let final = code.last else { return }
        var parameters: [UInt32] = []
        var number: UInt32 = 0
        for byte in code[1..<(code.count - 1)] {
            if byte == 0x3B {
                parameters.append(number)
                number = 0
            } else if (0x30...0x39).contains(byte) {
                let (product, overflow) = number.multipliedReportingOverflow(by: 10)
                let (sum, overflow2) = product.addingReportingOverflow(UInt32(byte - 0x30))
                number = overflow || overflow2 ? .max : sum
            }
        }
        parameters.append(number)
        func parameter(_ index: Int) -> Int? { index < parameters.count ? Int(parameters[index]) : nil }
        switch final {
        case 0x53:
            // SWF：画面の形（管理データの表示書式とは番号が違う）
            guard let value = parameter(0), !moved else { return }
            switch value {
            case 5: reset(width: 1920, height: 1080, vertical: false)
            case 6: reset(width: 1920, height: 1080, vertical: true)
            case 7: reset(width: 960, height: 540, vertical: false)
            case 8: reset(width: 960, height: 540, vertical: true)
            case 9: reset(width: 720, height: 480, vertical: false)
            case 10: reset(width: 720, height: 480, vertical: true)
            case 11: reset(width: 1280, height: 720, vertical: false)
            case 12: reset(width: 1280, height: 720, vertical: true)
            default: break
            }
        case 0x5F:
            // SDP：表示領域の位置
            if let left = parameter(0), let top = parameter(1), !moved {
                area.x = left
                area.y = top
                home()
                if inManagement { initial.area = area }
            }
        case 0x56:
            // SDF：表示領域の大きさ
            if let width = parameter(0), let height = parameter(1), !moved {
                area.width = width
                area.height = height
                if inManagement { initial.area = area }
            }
        case 0x57:
            // SSM：文字の大きさ
            if let width = parameter(0), let height = parameter(1), width == height, [16, 20, 24, 30, 36].contains(width) {
                glyphWidth = width
                glyphHeight = height
                if inManagement {
                    initial.glyphWidth = width
                    initial.glyphHeight = height
                }
            }
        case 0x58:
            // SHS：字間
            if let value = parameter(0) {
                horizontalSpacing = value
                if inManagement { initial.horizontalSpacing = value }
            }
        case 0x59:
            // SVS：行間
            if let value = parameter(0) {
                verticalSpacing = value
                if inManagement { initial.verticalSpacing = value }
            }
        case 0x63:
            // ORN：縁取り（1 の後に色。集合 × 100 + 番号で書く）
            if parameter(0) == 1 {
                let value = parameter(1) ?? 0
                outline = .indexed(UInt8(truncatingIfNeeded: (value / 100) * 16 + value % 100))
            } else {
                outline = nil
            }
        case 0x61:
            // ACPS：動作位置（画素）
            if let left = parameter(0), let top = parameter(1) {
                x = left
                y = top
                moved = true
                hidden = x > area.x + area.width || y > area.y + area.height
            }
        case 0x6E:
            // RCS：ラスタ色（表示領域を塗る色）
            if let value = parameter(0), value < 128, !moved {
                raster = .indexed(UInt8(value))
                layout.raster = raster
            }
        case 0x67:
            // SCR：スクロール（P1 が 1・2 は行、3・4 は画面。偶数は流し出す。P2 が速さ）。文字は右から左へ流れる
            if let mode = parameter(0), let speed = parameter(1), (1...4).contains(mode), speed > 0 {
                // 速さは 1 秒あたりの画素とみなし、表示領域の幅を流す
                let width = area.width
                layout.motion = CaptionMotion(toX: -width, duration: UInt32(clamping: width * 1000 / speed))
            }
        case 0x68:
            // PRA：内蔵音
            if let value = parameter(0), (1...13).contains(value) { layout.sound = UInt8(value) }
        default:
            break
        }
    }
}

/// 既定の CLUT（ARIB STD-B24 第一編 第二部 表 8-8）。0〜7 が基本の色、8 が透明、9〜15 が半分の明るさ、
/// 16〜64 が 85 刻みの組み合わせ、65〜127 がそれらの半透明
enum CaptionCLUT {
    static let colors: [(UInt8, UInt8, UInt8, UInt8)] = [
        (0, 0, 0, 255), (255, 0, 0, 255), (0, 255, 0, 255), (255, 255, 0, 255),
        (0, 0, 255, 255), (255, 0, 255, 255), (0, 255, 255, 255), (255, 255, 255, 255),
        (0, 0, 0, 0), (170, 0, 0, 255), (0, 170, 0, 255), (170, 170, 0, 255),
        (0, 0, 170, 255), (170, 0, 170, 255), (0, 170, 170, 255), (170, 170, 170, 255),
        (0, 0, 85, 255), (0, 85, 0, 255), (0, 85, 85, 255), (0, 85, 170, 255),
        (0, 85, 255, 255), (0, 170, 85, 255), (0, 170, 255, 255), (0, 255, 85, 255),
        (0, 255, 170, 255), (85, 0, 0, 255), (85, 0, 85, 255), (85, 0, 170, 255),
        (85, 0, 255, 255), (85, 85, 0, 255), (85, 85, 85, 255), (85, 85, 170, 255),
        (85, 85, 255, 255), (85, 170, 0, 255), (85, 170, 85, 255), (85, 170, 170, 255),
        (85, 170, 255, 255), (85, 255, 0, 255), (85, 255, 85, 255), (85, 255, 170, 255),
        (85, 255, 255, 255), (170, 0, 85, 255), (170, 0, 255, 255), (170, 85, 0, 255),
        (170, 85, 85, 255), (170, 85, 170, 255), (170, 85, 255, 255), (170, 170, 85, 255),
        (170, 170, 255, 255), (170, 255, 0, 255), (170, 255, 85, 255), (170, 255, 170, 255),
        (170, 255, 255, 255), (255, 0, 85, 255), (255, 0, 170, 255), (255, 85, 0, 255),
        (255, 85, 85, 255), (255, 85, 170, 255), (255, 85, 255, 255), (255, 170, 0, 255),
        (255, 170, 85, 255), (255, 170, 170, 255), (255, 170, 255, 255), (255, 255, 85, 255),
        (255, 255, 170, 255), (0, 0, 0, 128), (255, 0, 0, 128), (0, 255, 0, 128),
        (255, 255, 0, 128), (0, 0, 255, 128), (255, 0, 255, 128), (0, 255, 255, 128),
        (255, 255, 255, 128), (170, 0, 0, 128), (0, 170, 0, 128), (170, 170, 0, 128),
        (0, 0, 170, 128), (170, 0, 170, 128), (0, 170, 170, 128), (170, 170, 170, 128),
        (0, 0, 85, 128), (0, 85, 0, 128), (0, 85, 85, 128), (0, 85, 170, 128),
        (0, 85, 255, 128), (0, 170, 85, 128), (0, 170, 255, 128), (0, 255, 85, 128),
        (0, 255, 170, 128), (85, 0, 0, 128), (85, 0, 85, 128), (85, 0, 170, 128),
        (85, 0, 255, 128), (85, 85, 0, 128), (85, 85, 85, 128), (85, 85, 170, 128),
        (85, 85, 255, 128), (85, 170, 0, 128), (85, 170, 85, 128), (85, 170, 170, 128),
        (85, 170, 255, 128), (85, 255, 0, 128), (85, 255, 85, 128), (85, 255, 170, 128),
        (85, 255, 255, 128), (170, 0, 85, 128), (170, 0, 255, 128), (170, 85, 0, 128),
        (170, 85, 85, 128), (170, 85, 170, 128), (170, 85, 255, 128), (170, 170, 85, 128),
        (170, 170, 255, 128), (170, 255, 0, 128), (170, 255, 85, 128), (170, 255, 170, 128),
        (170, 255, 255, 128), (255, 0, 85, 128), (255, 0, 170, 128), (255, 85, 0, 128),
        (255, 85, 85, 128), (255, 85, 170, 128), (255, 85, 255, 128), (255, 170, 0, 128),
        (255, 170, 85, 128), (255, 170, 170, 128), (255, 170, 255, 128), (255, 255, 85, 128),
    ]
}
