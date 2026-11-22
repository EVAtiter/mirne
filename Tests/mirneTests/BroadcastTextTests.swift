import Foundation
import Testing

// 番組マークの角括弧への置き換え（BroadcastText）と、Mac のフォントの字形の確かめ

@Suite("番組マーク")
struct BroadcastTextTests {
    @Test("PUA と囲み文字の番組マークを角括弧にする。表に無い PUA はそのまま")
    func normalizes() {
        #expect(BroadcastText.normalize("手話ニュース\u{E0FD}\u{E0FE}") == "手話ニュース[手][字]")
        #expect(BroadcastText.normalize("ニュース🈑") == "ニュース[字]")
        #expect(BroadcastText.normalize("番組🈟🈞") == "番組[新][再]")
        #expect(BroadcastText.normalize("x\u{E000}") == "x\u{E000}")
        #expect(BroadcastText.normalize("ふつうの番組") == "ふつうの番組")
        // ㊙ と ⁉ は PUA で届くが、角括弧にせず番組表の経路と同じ通常の文字にする（plan.md §56.3）
        #expect(BroadcastText.normalize("ジュワーッ\u{E19B}ギョウザ・どこ\u{E2F0}") == "ジュワーッ㊙ギョウザ・どこ⁉")
    }

    @Test("番組表から読んだ番組は、字形の無い囲み文字だけを角括弧にする（字形の無い 🅍 が「?」で出ていた）")
    func normalizesGuideSchedule() {
        let event = BroadcastEvent(tableID: 0x50, serviceID: 1, eventID: 2, start: nil, duration: nil,
                                   title: "架空の音楽番組🅍🈑", text: "説明🈓", lossless: true)
        let source = EPGStore.ServiceSchedule(coverage: nil, events: [event])
        // 🈑 だけ字形があるとみなす
        let schedule = source.normalizingBroadcastMarks(keepsEnclosed: { $0 == "🈑" })
        #expect(schedule.events.map(\.title) == ["架空の音楽番組[SS]🈑"])
        #expect(schedule.events.map(\.text) == ["説明[デ]"])
        // PUA はいつも角括弧にする
        #expect(BroadcastText.normalize("x\u{E0FE}🈑", keepsEnclosed: { _ in true }) == "x[字]🈑")
    }

    @Test("字形の有無を Mac のフォントで調べる（🅍 は無く、🈑 はある）")
    func glyphAvailability() {
        #expect(!GlyphAvailability.hasGlyph("\u{1F14D}"))
        #expect(GlyphAvailability.hasGlyph("\u{1F211}"))
    }
}
