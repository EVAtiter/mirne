// coax の pkg/isdb/decode.go・charset.go・control.go（Copyright 2026 Till0196・
// Apache-2.0 OR GPL-2.0-or-later）を、mirne（Apache-2.0）へ Apache-2.0 の条件で Swift に移植したもの。
// 違い: JIS X 0208 の漢字は Go の x/text の EUC-JP ではなく Foundation の EUC-JP で引く。DRCS（外字の図形）は扱わない。

import Foundation

/// ARIB STD-B24 の 8 単位符号の文字列を復号する（番組名・番組説明・サービス名など）。
public struct ARIBStringDecoder {
    /// 復号の結果
    public struct Result: Sendable {
        public var text: String
        /// 復号できなかった文字の数（0 なら欠けなく復号できた）
        public var undecodable: Int
        public var lossless: Bool { undecodable == 0 }
    }

    /// 文字集合の終端符号（F）
    enum CharacterSet: UInt8 {
        case kanji = 0x42, jisX0213Plane1 = 0x39, jisX0213Plane2 = 0x3A, additional = 0x3B
        case alphanumeric = 0x4A, ascii = 0x40, hiragana = 0x30, katakana = 0x31
        case mosaicA = 0x32, mosaicB = 0x33, mosaicC = 0x34, mosaicD = 0x35
        case proportionalAlphanumeric = 0x36, proportionalHiragana = 0x37, proportionalKatakana = 0x38
        case jisX0201Katakana = 0x49
        /// DRCS-0（2 バイト）と DRCS-1〜15（1 バイト）。図形は扱わないので、どれも復号できない文字になる
        case drcs0 = 0xC0, drcsSingle = 0xC1, macro = 0xF0

        var isTwoByte: Bool {
            switch self {
            case .kanji, .jisX0213Plane1, .jisX0213Plane2, .additional, .drcs0: true
            default: false
            }
        }
    }

    /// 制御符号
    enum Control {
        static let escape: UInt8 = 0x1B
        static let lockingShift0: UInt8 = 0x0F
        static let lockingShift1: UInt8 = 0x0E
        static let singleShift2: UInt8 = 0x19
        static let singleShift3: UInt8 = 0x1D
        static let activePositionDown: UInt8 = 0x0A
        static let activePositionReturn: UInt8 = 0x0D
        static let parameterizedActivePositionForward: UInt8 = 0x16
        static let activePositionSet: UInt8 = 0x1C
        static let smallSize: UInt8 = 0x88
        static let middleSize: UInt8 = 0x89
        static let normalSize: UInt8 = 0x8A
        static let sizeControl: UInt8 = 0x8B
        static let color: UInt8 = 0x90
        static let flashing: UInt8 = 0x91
        static let conceal: UInt8 = 0x92
        static let pattern: UInt8 = 0x93
        static let writingMode: UInt8 = 0x94
        static let macro: UInt8 = 0x95
        static let highlight: UInt8 = 0x97
        static let repeatCharacter: UInt8 = 0x98
        static let controlSequence: UInt8 = 0x9B
        static let time: UInt8 = 0x9D
        // ESC の後の終端
        static let lockingShift2: UInt8 = 0x6E
        static let lockingShift3: UInt8 = 0x6F
        static let lockingShift1Right: UInt8 = 0x7E
        static let lockingShift2Right: UInt8 = 0x7D
        static let lockingShift3Right: UInt8 = 0x7C
    }

    private var graphicSets: [CharacterSet] = []
    private var left = 0
    private var right = 2
    private var single = 0
    /// 標準の大きさか（SSZ・MSZ で半分、NSZ で戻る）。標準の大きさの英数と空白は全角にする
    private var normalSize = true
    private var text = ""
    private var undecodable = 0

    public init() {}

    /// 1 つの文字列を復号する
    public static func decode<Bytes: Collection>(_ bytes: Bytes) -> Result where Bytes.Element == UInt8 {
        var decoder = ARIBStringDecoder()
        return decoder.decode(Array(bytes))
    }

    public mutating func decode(_ bytes: [UInt8]) -> Result {
        resetDesignations()
        normalSize = true
        text = ""
        undecodable = 0
        var index = 0
        while index < bytes.count {
            index += step(bytes, index)
        }
        return Result(text: text, undecodable: undecodable)
    }

    private mutating func resetDesignations() {
        graphicSets = [.kanji, .alphanumeric, .hiragana, .katakana]
        left = 0
        right = 2
        single = 0
    }

    private mutating func step(_ bytes: [UInt8], _ index: Int) -> Int {
        let code = bytes[index]
        switch code {
        case 0x00, 0x7F, 0xFF:
            return 1
        case Control.escape:
            return escape(bytes, index)
        case 0x01..<0x20, 0x80...0x9F:
            return control(bytes, index)
        case 0x20, 0xA0:
            // 標準の大きさの空白は全角（Mirakurun の aribts と同じ読み方。番組名が同じ文字列になるように）
            text.append(normalSize ? "\u{3000}" : " ")
            single = 0
            return 1
        default:
            return graphic(bytes, index)
        }
    }

    private mutating func graphic(_ bytes: [UInt8], _ index: Int) -> Int {
        let code = bytes[index]
        var slot = left
        if single != 0 {
            slot = single
        } else if code & 0x80 != 0 {
            slot = right
        }
        single = 0
        let set = graphicSets[slot]
        guard set.isTwoByte else {
            character(set, cell: UInt16(code & 0x7F), width: 1)
            return 1
        }
        guard index + 1 < bytes.count, (bytes[index + 1] ^ code) & 0x80 == 0 else {
            undecodable += 1
            return 1
        }
        character(set, cell: UInt16(code & 0x7F) << 8 | UInt16(bytes[index + 1] & 0x7F), width: 2)
        return 2
    }

    private mutating func character(_ set: CharacterSet, cell: UInt16, width: Int) {
        let first = width == 1 ? UInt8(cell & 0xFF) : UInt8(cell >> 8)
        let second = width == 1 ? UInt8(0) : UInt8(cell & 0xFF)
        guard var decoded = Self.decode(set, first, second) else {
            undecodable += 1
            return
        }
        if width == 1, normalSize {
            decoded = Self.fullWidth(decoded)
        }
        text.append(decoded)
    }

    /// 1 文字を引く（字幕の読み取り `CaptionPieceReader` も使う）
    static func decode(_ set: CharacterSet, _ first: UInt8, _ second: UInt8) -> Character? {
        switch set {
        case .ascii, .alphanumeric, .proportionalAlphanumeric:
            if let exception = ARIBTables.alphanumericExceptions[first] { return exception }
            return Character(Unicode.Scalar(first))
        case .katakana, .proportionalKatakana:
            guard first >= 0x21 else { return nil }
            if first <= 0x76 { return Character(Unicode.Scalar(0x3080 + UInt32(first))!) }
            return kanaPunctuation[Int(first - 0x77)]
        case .hiragana, .proportionalHiragana:
            switch first {
            case 0x21...0x73: return Character(Unicode.Scalar(0x3020 + UInt32(first))!)
            case 0x77, 0x78: return hiraganaPunctuation[Int(first - 0x77)]
            case 0x79...: return kanaPunctuation[Int(first - 0x77)]
            default: return nil
            }
        case .jisX0201Katakana:
            guard (0x21...0x5F).contains(first) else { return nil }
            return Character(Unicode.Scalar(0xFF40 + UInt32(first))!)
        case .kanji, .additional, .jisX0213Plane1, .jisX0213Plane2:
            return twoByte(first, second)
        default:
            return nil
        }
    }

    private static let kanaPunctuation: [Character] = ["ヽ", "ヾ", "ー", "。", "「", "」", "、", "・"]
    private static let hiraganaPunctuation: [Character] = ["ゝ", "ゞ"]

    private static func twoByte(_ first: UInt8, _ second: UInt8) -> Character? {
        guard (0x21...0x7E).contains(first), (0x21...0x7E).contains(second) else { return nil }
        let cell = UInt16(first) << 8 | UInt16(second)
        if let symbol = ARIBTables.additionalSymbols[cell] { return symbol }
        if let combining = ARIBTables.combiningCells[cell] { return combining }
        if let fixed = ARIBTables.jisOverrides[cell] { return fixed }
        // JIS X 0208 は EUC-JP（区点に 0x80 を足した 2 バイト）として Foundation で引く。
        // ただし 9〜15 区（0x29〜0x2F）は Foundation が Apple 独自の文字を返すので引かない
        // （13 区は上の固定の表にある。それ以外は ARIB で未定義）
        guard (0x21...0x74).contains(first), !(0x29...0x2F).contains(first) else { return nil }
        guard let decoded = String(bytes: [first | 0x80, second | 0x80], encoding: .japaneseEUC),
              decoded.count == 1 else { return nil }
        return decoded.first
    }

    /// 標準の大きさの英数を全角にする（aribts の表と同じ。字幕の描画も使う）
    static func fullWidth(_ character: Character) -> Character {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return character }
        switch scalar {
        case "\"": return "\u{201D}"
        case "'": return "\u{2019}"
        case "\\", "\u{00A5}": return "\u{FFE5}"
        case "`": return "\u{2018}"
        case "~", "\u{203E}": return "\u{FFE3}"
        case "!"..."}": return Character(Unicode.Scalar(scalar.value - 0x21 + 0xFF01)!)
        default: return character
        }
    }

    // MARK: - 指示と呼び出し

    private mutating func escape(_ bytes: [UInt8], _ index: Int) -> Int {
        guard index + 1 < bytes.count else { return 1 }
        let final = bytes[index + 1]
        switch final {
        case Control.lockingShift2: left = 2; single = 0; return 2
        case Control.lockingShift3: left = 3; single = 0; return 2
        case Control.lockingShift1Right: right = 1; single = 0; return 2
        case Control.lockingShift2Right: right = 2; single = 0; return 2
        case Control.lockingShift3Right: right = 3; single = 0; return 2
        case 0x24: return designateMultiByte(bytes, index)
        case 0x28...0x2B: return designateSingleByte(bytes, index, slot: Int(final - 0x28), at: 2)
        default: return 2
        }
    }

    private mutating func designateSingleByte(_ bytes: [UInt8], _ index: Int, slot: Int, at offset: Int) -> Int {
        guard index + offset < bytes.count else { return bytes.count - index }
        let final = bytes[index + offset]
        if final == 0x20 {
            // DRCS（外字の図形）。図形は扱わないので、指示だけを受け取る
            guard index + offset + 1 < bytes.count else { return bytes.count - index }
            let next = bytes[index + offset + 1]
            if next == 0x70 { graphicSets[slot] = .macro }
            if (0x41...0x4F).contains(next) { graphicSets[slot] = .drcsSingle }
            return offset + 2
        }
        if let set = CharacterSet(rawValue: final), Self.isSingleByteSet(set) {
            graphicSets[slot] = set
        }
        return offset + 1
    }

    private mutating func designateMultiByte(_ bytes: [UInt8], _ index: Int) -> Int {
        guard index + 2 < bytes.count else { return bytes.count - index }
        let final = bytes[index + 2]
        if let set = CharacterSet(rawValue: final), Self.isTwoByteSet(set) {
            graphicSets[0] = set
            return 3
        }
        guard (0x28...0x2B).contains(final) else { return 3 }
        let slot = Int(final - 0x28)
        guard index + 3 < bytes.count else { return bytes.count - index }
        let next = bytes[index + 3]
        if next == 0x20 {
            if index + 4 < bytes.count, bytes[index + 4] == 0x40 { graphicSets[slot] = .drcs0 }
            return 5
        }
        if let set = CharacterSet(rawValue: next), Self.isTwoByteSet(set) {
            graphicSets[slot] = set
        }
        return 4
    }

    static func isTwoByteSet(_ set: CharacterSet) -> Bool {
        [.kanji, .jisX0213Plane1, .jisX0213Plane2, .additional].contains(set)
    }

    static func isSingleByteSet(_ set: CharacterSet) -> Bool {
        switch set {
        case .ascii, .alphanumeric, .jisX0201Katakana: true
        default: (CharacterSet.hiragana.rawValue...CharacterSet.proportionalKatakana.rawValue).contains(set.rawValue)
        }
    }

    // MARK: - 制御符号

    private mutating func control(_ bytes: [UInt8], _ index: Int) -> Int {
        switch bytes[index] {
        case Control.lockingShift0: left = 0; single = 0; return 1
        case Control.lockingShift1: left = 1; single = 0; return 1
        case Control.singleShift2: single = 2; return 1
        case Control.singleShift3: single = 3; return 1
        case Control.activePositionDown:
            text.append("\n")
            resetDesignations()
            return 1
        case Control.activePositionReturn:
            text.append("\r")
            single = 0
            return 1
        default:
            break
        }
        let length = Self.controlLength(bytes, index)
        switch bytes[index] {
        case Control.smallSize, Control.middleSize: normalSize = false
        case Control.normalSize: normalSize = true
        case Control.sizeControl: normalSize = !(length > 1 && bytes[index + 1] == 0x60)
        default: break
        }
        single = 0
        return length
    }

    /// 制御符号とその引数の長さ
    static func controlLength(_ bytes: [UInt8], _ index: Int) -> Int {
        let rest = bytes.count - index
        func clamp(_ n: Int) -> Int { min(n, rest) }
        switch bytes[index] {
        case Control.parameterizedActivePositionForward, Control.sizeControl, Control.flashing, Control.pattern,
             Control.writingMode, Control.highlight, Control.repeatCharacter:
            return clamp(2)
        case Control.activePositionSet:
            return clamp(3)
        case Control.color, Control.conceal:
            return rest > 1 && bytes[index + 1] == 0x20 ? clamp(3) : clamp(2)
        case Control.macro:
            for n in 1..<max(rest, 1) where bytes[index + n] == Control.macro { return clamp(n + 2) }
            return rest
        case Control.controlSequence:
            var n = 1
            while n < rest, (0x20...0x3F).contains(bytes[index + n]) { n += 1 }
            if n < rest, (0x40...0x7E).contains(bytes[index + n]) { n += 1 }
            return n
        case Control.time:
            if rest > 1, bytes[index + 1] == 0x20 { return clamp(3) }
            var n = 1
            while n < rest, (0x28...0x3B).contains(bytes[index + n]) {
                if bytes[index + n] == 0x29 { n += 1; break }
                n += 1
            }
            return n
        default:
            return 1
        }
    }
}
