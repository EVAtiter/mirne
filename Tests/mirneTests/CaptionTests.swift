// coax の pkg/isdb/caption/caption_test.go・pkg/isdb/pieces_test.go（Copyright 2026 Till0196・
// SPDX-License-Identifier: Apache-2.0 OR GPL-2.0-or-later）の試験のうち、移植した範囲のものを Swift に移したもの。

import Foundation
import Testing

/// 試験用の字幕 PES を組み立てる
private enum CaptionSample {
    /// data_identifier・private_stream_id・ヘッダ長 0 の後に、データグループ（CRC は 0 で埋める）
    static func group(_ kind: UInt8, id: UInt8, _ data: [UInt8]) -> [UInt8] {
        [kind, 0xFF, 0x00, id << 2, 0x00, 0x00, UInt8(data.count >> 8), UInt8(data.count & 0xFF)] + data + [0, 0]
    }

    /// 時刻制御モード 0 の本文データに、本文のデータユニット 1 つ
    static func statement(_ text: [UInt8]) -> [UInt8] {
        let unit = [0x1F, 0x20, UInt8(text.count >> 16), UInt8((text.count >> 8) & 0xFF), UInt8(text.count & 0xFF)] + text
        return [0x00, UInt8(unit.count >> 16), UInt8((unit.count >> 8) & 0xFF), UInt8(unit.count & 0xFF)] + unit
    }

    static func layout(_ text: [UInt8], kind: CaptionKind = .caption) throws -> CaptionLayout {
        let bytes = group(kind == .caption ? 0x80 : 0x81, id: 0x01, statement(text))
        let statement = try #require(CaptionDecoder.parsePES(bytes)?.statement)
        return CaptionPresenter(kind: kind).present(statement)
    }

    static func characters(_ pieces: [CaptionPiece]) -> String {
        String(pieces.compactMap { if case let .character(character, _) = $0 { character } else { nil } })
    }
}

@Suite("字幕の 8 単位符号の読み取り")
struct CaptionPieceTests {
    @Test("字幕は 4 番目の場所にマクロの集合を置いて始まり、SS3 0x61 で 2 番目の場所がカタカナになる")
    func defaultMacroChangesSets() {
        // SS3 0x61（マクロ 1：G1 をカタカナに）、LS1、0x22 でカタカナの「ア」
        #expect(CaptionSample.characters(CaptionPieceReader.pieces([0x1D, 0x61, 0x0E, 0x22])) == "ア")
    }

    @Test("1 バイトの文字は幅 1 のまま返す（升目を決めるのは配置の側）")
    func piecesKeepWidth() {
        let pieces = CaptionPieceReader.pieces([0x0E, 0x41, 0x0F, 0x24, 0x22])
        #expect(pieces == [.character("A", width: 1), .character("あ", width: 2)])
    }

    @Test("画面消去で集合を字幕の始まりの状態へ戻し、制御符号として返す")
    func clearScreenResetsSets() {
        // LS1 で英数にしてから CS。0x24 0x22 はまた漢字の集合で「あ」と読む
        let pieces = CaptionPieceReader.pieces([0x0E, 0x0C, 0x24, 0x22])
        #expect(pieces == [.control([0x0C]), .character("あ", width: 2)])
    }

    @Test("DRCS の文字は集合と符号で返す")
    func drcsPiece() {
        #expect(CaptionPieceReader.pieces([0x1B, 0x24, 0x28, 0x20, 0x40, 0x21, 0x21]) == [.drcs(set: 0, code: 0x2121, width: 2)])
    }

    @Test("制御符号は引数ごと返す")
    func controlCarriesParameters() {
        #expect(CaptionPieceReader.pieces([0x1C, 0x42, 0x43, 0x24, 0x22]) == [.control([0x1C, 0x42, 0x43]), .character("あ", width: 2)])
    }

    @Test("9〜15 区は番組名と同じく読む（13 区は読め、それ以外は文字にならない）")
    func rowThirteen() {
        let pieces = CaptionPieceReader.pieces([0x2D, 0x21, 0x29, 0x21])
        #expect(CaptionSample.characters(pieces) == "①")
        #expect(pieces.filter { $0 == .lost }.count == 1)
    }
}

@Suite("字幕 PES の解析と配置")
struct CaptionPresenterTests {
    @Test("管理データから言語と表示書式を読む")
    func managementNamesLanguageAndFormat() throws {
        // 時刻制御モード 0、1 言語（タグ 0・表示モード 0・jpn・書式 7 = 960×540 の横書き）、データユニットなし
        let data: [UInt8] = [0x00, 0x01, 0x00, 0x6A, 0x70, 0x6E, 0x70, 0x00, 0x00, 0x00]
        let group = try #require(CaptionDecoder.parsePES(CaptionSample.group(0x80, id: 0x00, data)))
        #expect(group.isManagement)
        let language = try #require(group.management?.languages.first)
        #expect(language.languageCode == "jpn")
        #expect(language.format == 7)
    }

    @Test("APS で指した位置に置く")
    func statementLaidOutWhereAPSSays() throws {
        // APS で 2 行目・3 列目、「あい」（字幕が始まる漢字の集合）
        let layout = try CaptionSample.layout([0x1C, 0x40 + 2, 0x40 + 3, 0x24, 0x22, 0x24, 0x24], kind: .superimpose)
        #expect(layout.screenWidth == 960 && layout.screenHeight == 540)
        #expect(layout.superimpose)
        let text = try #require(layout.texts.first)
        #expect(layout.texts.count == 1)
        #expect(text.text == "あい")
        #expect(text.x == 3 * 40 && text.y == 2 * 60)
        #expect(text.cellWidth == 40 && text.cellHeight == 60)
        #expect(text.foreground == .white)
    }

    @Test("DRCS の図形を読み、本文が使う文字に付ける")
    func drcsGlyphsAreAttached() throws {
        // DRCS-0（2 バイト）：区点 0x21 0x21、形 1 つ、モード 1・depth 2（4 階調・2 ビット）、2×2
        let drcsUnit: [UInt8] = [0x01, 0x21, 0x21, 0x01, 0x21, 0x02, 0x02, 0x02, 0b11_00_00_11]
        let parsed = CaptionDRCS.parse(twoByte: true, drcsUnit)
        #expect(parsed.count == 1)
        #expect(parsed.first?.glyph.bitmap == [3, 0, 0, 3])
        #expect(parsed.first?.scalar == CaptionDRCS.scalar(set: 0, code: 0x2121, width: 2))

        // 本文は DRCS-0 を G0 に指示して（ESC 0x24 0x28 0x20 0x40）0x21 0x21
        let text: [UInt8] = [0x1B, 0x24, 0x28, 0x20, 0x40, 0x21, 0x21]
        let unitD: [UInt8] = [0x1F, 0x31, 0, 0, UInt8(drcsUnit.count)] + drcsUnit
        let unitT: [UInt8] = [0x1F, 0x20, 0, 0, UInt8(text.count)] + text
        let total = unitD.count + unitT.count
        let data: [UInt8] = [0x00, 0, UInt8(total >> 8), UInt8(total & 0xFF)] + unitD + unitT
        let statement = try #require(CaptionDecoder.parsePES(CaptionSample.group(0x81, id: 0x01, data))?.statement)
        let layout = CaptionPresenter(kind: .superimpose).present(statement)
        #expect(layout.texts.count == 1)
        let scalar = try #require(layout.texts.first?.text.unicodeScalars.first)
        #expect(CaptionDRCS.contains(scalar))
        #expect(layout.drcs[scalar]?.count == 1)
    }

    @Test("色と大きさが変わると並びを分ける")
    func colorsAndSizesSplitRuns() throws {
        // 赤（0x81）、あ、中型（0x89）、LS1 で G1（英数）、A
        let layout = try CaptionSample.layout([0x81, 0x24, 0x22, 0x89, 0x0E, 0x41])
        #expect(layout.texts.count == 2)
        #expect(layout.texts.first?.foreground == .indexed(1))
        let second = try #require(layout.texts.last)
        #expect(second.text == "A" && second.cellWidth == 20 && second.cellHeight == 60)
    }

    @Test("本文の終わりで切れた CSI は読み飛ばす")
    func cutOffCSIIsPassedOver() throws {
        #expect(try CaptionSample.layout([0x24, 0x22, 0x9B]).texts.count == 1)
    }

    @Test("TIME で待ってからの CS は、それまで置いたものをそのときまで出す")
    func timeThenClearKeepsText() throws {
        let layout = try CaptionSample.layout([0x24, 0x22, 0x9D, 0x20, 0x40 + 30, 0x0C])
        #expect(layout.texts.count == 1)
        #expect(layout.texts.first?.until == 3000)
        #expect(layout.clearAfter == 3000)
        #expect(!layout.clear)
    }

    @Test("本文データの提示の時刻をミリ秒で読む")
    func statementTimeIsRead() throws {
        let data: [UInt8] = [0x40, 0x01, 0x02, 0x03, 0x45, 0x60, 0, 0, 0]
        let statement = try #require(CaptionDecoder.parsePES(CaptionSample.group(0x80, id: 0x01, data))?.statement)
        let expected: UInt64 = ((1 * 60 + 2) * 60 + 3) * 1000 + 456
        #expect(statement.presentationTime == expected)
    }
}
