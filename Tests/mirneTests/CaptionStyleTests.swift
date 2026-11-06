import CoreGraphics
import Foundation
import Testing

@Suite("字幕の見た目")
struct CaptionStyleTests {
    private func cue(flash: UInt8, showAt: Int64 = 0) -> CaptionCue {
        let text = CaptionText(x: 0, y: 0, cellWidth: 40, cellHeight: 60, glyphWidth: 36, glyphHeight: 36, text: "点",
                               foreground: .white, background: .transparent, outline: nil, flash: flash, enclosure: 0, delay: 0, until: nil)
        return CaptionCue(id: 0, text: text, screenWidth: 960, screenHeight: 540, drcs: [:], showAt: showAt, hideAt: nil)
    }

    @Test("点滅は出した時刻から半周期ごとに切り替わり、正相は出して始まり、逆相は消して始まる")
    func flashPhases() {
        let half = CaptionFlash.halfPeriod
        let normal = cue(flash: 1, showAt: 1_000)
        #expect(!normal.isHiddenByFlash(at: 1_000))
        #expect(normal.isHiddenByFlash(at: 1_000 + half))
        #expect(!normal.isHiddenByFlash(at: 1_000 + half * 2))
        let reverse = cue(flash: 2, showAt: 1_000)
        #expect(reverse.isHiddenByFlash(at: 1_000))
        #expect(!reverse.isHiddenByFlash(at: 1_000 + half))
        #expect(!cue(flash: 0).isHiddenByFlash(at: half))
    }

    @Test("半角の文字は標準の大きさなら全角の形、中型なら半角のまま描き、全角の文字は幅を縦横比に合わせる")
    func glyphShapes() {
        // 標準（36×36）：英数は全角の形にして等倍
        #expect(CaptionGlyphShape.shape("A", glyphWidth: 36, glyphHeight: 36) == ("Ａ", 1))
        // 中型（18×36）：英数は半角のまま等倍、漢字は幅を半分に
        #expect(CaptionGlyphShape.shape("A", glyphWidth: 18, glyphHeight: 36) == ("A", 1))
        #expect(CaptionGlyphShape.shape("字", glyphWidth: 18, glyphHeight: 36) == ("字", 0.5))
        // 横倍（72×36）：漢字は幅を 2 倍に
        #expect(CaptionGlyphShape.shape("字", glyphWidth: 72, glyphHeight: 36) == ("字", 2))
        #expect(CaptionGlyphShape.isNarrow("ｱ"))
        #expect(!CaptionGlyphShape.isNarrow("あ"))
    }

    @Test("外字は文字の大きさにいちばん近い形を選び、階調を文字の色の濃さにする")
    func drcsGlyph() throws {
        let small = CaptionDRCSGlyph(width: 2, height: 2, levels: 4, bitmap: [3, 0, 0, 1])
        let large = CaptionDRCSGlyph(width: 36, height: 36, levels: 2, bitmap: Array(repeating: 1, count: 36 * 36))
        #expect(CaptionGlyphShape.closest([small, large], width: 30, height: 30) == large)
        #expect(CaptionGlyphShape.closest([small, large], width: 4, height: 4) == small)
        #expect(CaptionGlyphShape.closest([], width: 36, height: 36) == nil)

        let image = try #require(CaptionDRCSImage.make(small, color: CaptionColor(r: 255, g: 0, b: 0, a: 255)))
        #expect(image.width == 2 && image.height == 2)
        let data = try #require(image.dataProvider?.data as Data?)
        // 1 画素目は階調 3/3（赤そのもの）、2 画素目は透明、4 画素目は 1/3 の濃さ
        #expect(Array(data[0..<4]) == [255, 0, 0, 255])
        #expect(Array(data[4..<8]) == [0, 0, 0, 0])
        #expect(Array(data[12..<16]) == [85, 0, 0, 85])
    }

    @Test("字幕の並びには、その並びが使う外字の形だけを持たせる")
    func cueCarriesItsDRCS() {
        let used = CaptionDRCS.scalar(set: 0, code: 0x2121, width: 2)
        let unused = CaptionDRCS.scalar(set: 0, code: 0x2122, width: 2)
        let glyph = CaptionDRCSGlyph(width: 2, height: 2, levels: 2, bitmap: [1, 0, 0, 1])
        var layout = CaptionLayout(screenWidth: 960, screenHeight: 540, areaX: 0, areaY: 0, areaWidth: 960, areaHeight: 540,
                                   superimpose: false, raster: .transparent)
        layout.texts = [CaptionText(x: 0, y: 0, cellWidth: 40, cellHeight: 60, glyphWidth: 36, glyphHeight: 36, text: "字" + String(Character(used)),
                                    foreground: .white, background: .transparent, outline: nil, flash: 0, enclosure: 0, delay: 0, until: nil)]
        layout.drcs = [used: [glyph], unused: [glyph]]
        let timeline = CaptionTimeline()
        timeline.apply(layout, at: 0)
        let cue = timeline.visible(at: 0).first
        #expect(cue?.drcs.keys.sorted { $0.value < $1.value } == [used])
    }
}
