// coax の pkg/isdb/pieces.go（Copyright 2026 Till0196・SPDX-License-Identifier: Apache-2.0 OR GPL-2.0-or-later）を、
// mirne（Apache-2.0）へ Apache-2.0 の条件で Swift に移植したもの。
// 違い: ワンセグ（C プロファイル）の読み方と、データ放送の EUC-JP を引く WideCell は移していない。
// 文字そのものは番組名と同じ `ARIBStringDecoder.decode` で引く。

import Foundation

/// 字幕の 8 単位符号を読んで出てくるもの 1 つ（文字か、引数付きの制御符号）。
public enum CaptionPiece: Equatable, Sendable {
    /// 文字。`width` は 2 バイトの集合なら 2（全角の升目）、1 バイトの集合なら 1
    case character(Character, width: Int)
    case space
    /// 放送が図形を送る文字（DRCS）。`set` は 0（2 バイトの DRCS-0）〜15、`code` は集合の中の符号
    case drcs(set: UInt8, code: UInt16, width: Int)
    /// 制御符号（先頭が符号、続きが引数）
    case control([UInt8])
    /// 文字にならなかったもの
    case lost
}

/// 字幕の文字列を、文字と制御符号の並びに分ける（ARIB STD-B24 第二編）。
///
/// 番組名の読み方（`ARIBStringDecoder`）との違いは 3 つ。字幕は 4 番目の場所にマクロの集合を置いて始まり、
/// 放送はそれに頼る（SS3 0x61 で 2 番目の場所をカタカナに替えるのが普通）。改行（APD）では集合を戻さず、
/// 画面消去（CS）で戻す。位置・大きさ・色の制御符号は読み飛ばさず、引数ごと返す（意味は `CaptionPresenter` が決める）
struct CaptionPieceReader {
    typealias CharacterSet = ARIBStringDecoder.CharacterSet

    /// 1 つの場所に入っている集合
    enum GraphicSet: Equatable {
        case set(CharacterSet)
        /// DRCS-0（2 バイト）〜 DRCS-15（1 バイト）
        case drcs(UInt8)
        case macro

        var isTwoByte: Bool {
            switch self {
            case let .set(set): set.isTwoByte
            case let .drcs(number): number == 0
            case .macro: false
            }
        }
    }

    /// 字幕が始まるときの集合（G0 漢字・G1 英数・G2 平仮名・G3 マクロ。GL が G0、GR が G2）
    private static let initialSets: [GraphicSet] = [.set(.kanji), .set(.ascii), .set(.hiragana), .macro]

    private var sets = initialSets
    private var left = 0
    private var right = 2
    private var single = 0
    /// マクロを展開している深さ（マクロの中のマクロは展開しない）
    private var depth = 0

    /// 1 つの文字列を読む
    static func pieces(_ bytes: [UInt8]) -> [CaptionPiece] {
        var reader = CaptionPieceReader()
        var out: [CaptionPiece] = []
        reader.run(bytes, into: &out)
        return out
    }

    private mutating func run(_ bytes: [UInt8], into out: inout [CaptionPiece]) {
        var index = 0
        while index < bytes.count {
            index += step(bytes, index, into: &out)
        }
    }

    private mutating func step(_ bytes: [UInt8], _ index: Int, into out: inout [CaptionPiece]) -> Int {
        let code = bytes[index]
        switch code {
        case 0x00, 0x7F, 0xFF:
            return 1
        case ARIBStringDecoder.Control.escape:
            return escape(bytes, index)
        case 0x20, 0xA0:
            out.append(.space)
            single = 0
            return 1
        case 0x01..<0x20, 0x80...0x9F:
            return control(bytes, index, into: &out)
        default:
            return graphic(bytes, index, into: &out)
        }
    }

    private mutating func graphic(_ bytes: [UInt8], _ index: Int, into out: inout [CaptionPiece]) -> Int {
        let code = bytes[index]
        var slot = left
        if single != 0 {
            slot = single
        } else if code & 0x80 != 0 {
            slot = right
        }
        single = 0
        let set = sets[slot]
        if set == .macro {
            macro(code & 0x7F)
            return 1
        }
        guard set.isTwoByte else {
            out.append(character(set, cell: UInt16(code & 0x7F), width: 1))
            return 1
        }
        // 2 バイトの文字の前半で終わっている（文字列が途中で切れている）か、前半と後半が別の側から来ている
        guard index + 1 < bytes.count, (bytes[index + 1] ^ code) & 0x80 == 0 else {
            out.append(.lost)
            return 1
        }
        out.append(character(set, cell: UInt16(code & 0x7F) << 8 | UInt16(bytes[index + 1] & 0x7F), width: 2))
        return 2
    }

    /// マクロの集合の符号が表すものを実行する。既定のマクロ（表 7-13）だけを知っている
    /// （放送が MACRO 0x95 で定義するものは、制御符号として読み飛ばす）。マクロが残すのは状態で、文字は出さない
    private mutating func macro(_ code: UInt8) {
        let number = Int(code) - 0x60
        guard CaptionMacros.defaults.indices.contains(number), depth == 0 else { return }
        depth += 1
        var scratch: [CaptionPiece] = []
        run(CaptionMacros.defaults[number], into: &scratch)
        depth -= 1
    }

    private func character(_ set: GraphicSet, cell: UInt16, width: Int) -> CaptionPiece {
        switch set {
        case let .drcs(number):
            return .drcs(set: number, code: cell, width: width)
        case .macro:
            return .lost
        case let .set(characterSet):
            let first = width == 1 ? UInt8(cell & 0xFF) : UInt8(cell >> 8)
            let second = width == 1 ? UInt8(0) : UInt8(cell & 0xFF)
            guard let decoded = ARIBStringDecoder.decode(characterSet, first, second) else { return .lost }
            return .character(decoded, width: width)
        }
    }

    // MARK: - 指示と呼び出し

    private mutating func escape(_ bytes: [UInt8], _ index: Int) -> Int {
        typealias Control = ARIBStringDecoder.Control
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
            // DRCS-1〜15（0x41〜0x4F）かマクロ（0x70）
            guard index + offset + 1 < bytes.count else { return bytes.count - index }
            let next = bytes[index + offset + 1]
            if next == 0x70 { sets[slot] = .macro }
            if (0x41...0x4F).contains(next) { sets[slot] = .drcs(next & 0x0F) }
            return offset + 2
        }
        if let set = CharacterSet(rawValue: final), ARIBStringDecoder.isSingleByteSet(set) {
            sets[slot] = .set(set)
        }
        return offset + 1
    }

    private mutating func designateMultiByte(_ bytes: [UInt8], _ index: Int) -> Int {
        guard index + 2 < bytes.count else { return bytes.count - index }
        let final = bytes[index + 2]
        if let set = CharacterSet(rawValue: final), ARIBStringDecoder.isTwoByteSet(set) {
            sets[0] = .set(set)
            return 3
        }
        guard (0x28...0x2B).contains(final) else { return 3 }
        let slot = Int(final - 0x28)
        guard index + 3 < bytes.count else { return bytes.count - index }
        let next = bytes[index + 3]
        if next == 0x20 {
            // DRCS-0（2 バイト）
            if index + 4 < bytes.count, bytes[index + 4] == 0x40 { sets[slot] = .drcs(0) }
            return 5
        }
        if let set = CharacterSet(rawValue: next), ARIBStringDecoder.isTwoByteSet(set) {
            sets[slot] = .set(set)
        }
        return 4
    }

    // MARK: - 制御符号

    private mutating func control(_ bytes: [UInt8], _ index: Int, into out: inout [CaptionPiece]) -> Int {
        typealias Control = ARIBStringDecoder.Control
        switch bytes[index] {
        case Control.lockingShift0: left = 0; single = 0; return 1
        case Control.lockingShift1: left = 1; single = 0; return 1
        case Control.singleShift2: single = 2; return 1
        case Control.singleShift3: single = 3; return 1
        case CaptionControl.clearScreen:
            // 画面消去で、集合を字幕の始まりの状態へ戻す
            sets = Self.initialSets
            left = 0
            right = 2
        default:
            break
        }
        single = 0
        let length = ARIBStringDecoder.controlLength(bytes, index)
        out.append(.control(Array(bytes[index..<index + length])))
        return length
    }
}

/// 字幕の画面の制御で使う符号（ARIB STD-B24 第二編 表 7-14〜7-16）
enum CaptionControl {
    static let activePositionBackward: UInt8 = 0x08
    static let activePositionForward: UInt8 = 0x09
    static let activePositionDown: UInt8 = 0x0A
    static let activePositionUp: UInt8 = 0x0B
    static let clearScreen: UInt8 = 0x0C
    static let activePositionReturn: UInt8 = 0x0D
    static let parameterizedActivePositionForward: UInt8 = 0x16
    static let activePositionSet: UInt8 = 0x1C
    /// 前景色の 8 色（BKF〜WHF）の最初
    static let blackForeground: UInt8 = 0x80
    static let whiteForeground: UInt8 = 0x87
    static let smallSize: UInt8 = 0x88
    static let middleSize: UInt8 = 0x89
    static let normalSize: UInt8 = 0x8A
    static let sizeControl: UInt8 = 0x8B
    static let color: UInt8 = 0x90
    static let flashing: UInt8 = 0x91
    static let polarity: UInt8 = 0x93
    static let highlight: UInt8 = 0x97
    static let repeatCharacter: UInt8 = 0x98
    static let controlSequence: UInt8 = 0x9B
    static let time: UInt8 = 0x9D
}

/// 既定のマクロ（ARIB STD-B24 第二編 表 7-13）。符号 0x60〜0x6F が展開するもの。
/// どれも最初の 3 つの場所に集合を指示し、4 つ目にマクロの集合を入れ、LS0 と LS2R をする
enum CaptionMacros {
    static let defaults: [[UInt8]] = [
        [0x1B, 0x24, 0x42, 0x1B, 0x29, 0x4A, 0x1B, 0x2A, 0x30, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x24, 0x42, 0x1B, 0x29, 0x31, 0x1B, 0x2A, 0x30, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x24, 0x42, 0x1B, 0x29, 0x20, 0x41, 0x1B, 0x2A, 0x30, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x28, 0x32, 0x1B, 0x29, 0x34, 0x1B, 0x2A, 0x35, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x28, 0x32, 0x1B, 0x29, 0x33, 0x1B, 0x2A, 0x35, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x28, 0x32, 0x1B, 0x29, 0x20, 0x41, 0x1B, 0x2A, 0x35, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x28, 0x20, 0x41, 0x1B, 0x29, 0x20, 0x42, 0x1B, 0x2A, 0x20, 0x43, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x28, 0x20, 0x44, 0x1B, 0x29, 0x20, 0x45, 0x1B, 0x2A, 0x20, 0x46, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x28, 0x20, 0x47, 0x1B, 0x29, 0x20, 0x48, 0x1B, 0x2A, 0x20, 0x49, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x28, 0x20, 0x4A, 0x1B, 0x29, 0x20, 0x4B, 0x1B, 0x2A, 0x20, 0x4C, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x28, 0x20, 0x4D, 0x1B, 0x29, 0x20, 0x4E, 0x1B, 0x2A, 0x20, 0x4F, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x24, 0x42, 0x1B, 0x29, 0x20, 0x42, 0x1B, 0x2A, 0x30, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x24, 0x42, 0x1B, 0x29, 0x20, 0x43, 0x1B, 0x2A, 0x30, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x24, 0x42, 0x1B, 0x29, 0x20, 0x44, 0x1B, 0x2A, 0x30, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x28, 0x31, 0x1B, 0x29, 0x30, 0x1B, 0x2A, 0x4A, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x28, 0x4A, 0x1B, 0x29, 0x32, 0x1B, 0x2A, 0x20, 0x41, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
    ]
}
