import Foundation
import Testing

/// 試験用の字幕の並び
private enum CaptionTimelineSample {
    static func text(_ string: String, delay: UInt32 = 0, until: UInt32? = nil) -> CaptionText {
        CaptionText(x: 0, y: 0, cellWidth: 40, cellHeight: 60, glyphWidth: 36, glyphHeight: 36, text: string,
                    foreground: .white, background: .transparent, outline: nil, flash: 0, enclosure: 0, delay: delay, until: until)
    }

    static func layout(_ texts: [CaptionText], clear: Bool = true, clearAfter: UInt32? = nil) -> CaptionLayout {
        var layout = CaptionLayout(screenWidth: 960, screenHeight: 540, areaX: 0, areaY: 0, areaWidth: 960, areaHeight: 540,
                                   superimpose: false, raster: .transparent)
        layout.clear = clear
        layout.clearAfter = clearAfter
        layout.texts = texts
        return layout
    }

    static func shown(_ timeline: CaptionTimeline, at time: Int64) -> [String] {
        timeline.visible(at: time).map(\.text.text)
    }
}

@Suite("字幕の時刻の並び")
struct CaptionTimelineTests {
    private typealias Sample = CaptionTimelineSample
    private let second: Int64 = 90_000

    @Test("本文は PTS から出し、次の CS の PTS で消す")
    func showsFromPTSUntilNextClear() {
        let timeline = CaptionTimeline()
        timeline.apply(Sample.layout([Sample.text("一")]), at: 10 * second)
        timeline.apply(Sample.layout([]), at: 11 * second)
        #expect(Sample.shown(timeline, at: 10 * second - 1).isEmpty)
        #expect(Sample.shown(timeline, at: 10 * second) == ["一"])
        #expect(Sample.shown(timeline, at: 11 * second - 1) == ["一"])
        #expect(Sample.shown(timeline, at: 11 * second).isEmpty)
    }

    @Test("CS の無い本文は前のものに重ねて出す")
    func statementWithoutClearAddsToScreen() {
        let timeline = CaptionTimeline()
        timeline.apply(Sample.layout([Sample.text("一")]), at: 10 * second)
        timeline.apply(Sample.layout([Sample.text("二")], clear: false), at: 12 * second)
        #expect(Sample.shown(timeline, at: 12 * second) == ["一", "二"])
    }

    @Test("文字ごとの待ちと消す時刻、TIME の後の CS を本文の PTS から数える")
    func delayUntilAndClearAfter() {
        let timeline = CaptionTimeline()
        timeline.apply(Sample.layout([Sample.text("一", until: 1500), Sample.text("二", delay: 500)], clearAfter: 3000), at: 10 * second)
        #expect(Sample.shown(timeline, at: 10 * second) == ["一"])
        #expect(Sample.shown(timeline, at: 10 * second + second / 2) == ["一", "二"])
        #expect(Sample.shown(timeline, at: 11 * second + second / 2) == ["二"])
        #expect(Sample.shown(timeline, at: 13 * second).isEmpty)
    }

    @Test("空にすると、出していたものもこれから出すものも捨てる")
    func resetDropsEverything() {
        let timeline = CaptionTimeline()
        timeline.apply(Sample.layout([Sample.text("一")]), at: 10 * second)
        timeline.apply(Sample.layout([Sample.text("二")]), at: 12 * second)
        let generation = timeline.currentGeneration
        timeline.reset()
        #expect(timeline.count == 0)
        #expect(timeline.currentGeneration == generation + 1)
        #expect(Sample.shown(timeline, at: 12 * second).isEmpty)
    }

    @Test("消去の来ないまま溜まり続けないよう、上限を超えたら古いものから捨てる")
    func capsCuesWithoutClear() {
        let timeline = CaptionTimeline()
        for index in 0..<(CaptionStream.cueLimit + 10) {
            timeline.apply(Sample.layout([Sample.text("\(index)")], clear: false), at: Int64(index) * second)
        }
        #expect(timeline.count == CaptionStream.cueLimit)
    }

    @Test("字幕の ES は component_tag 0x30 を選び、文字スーパーとタグの無い独立 PES は選ばない")
    func choosesCaptionStream() {
        func map(_ streams: [ElementaryStream]) -> ProgramMap {
            ProgramMap(programNumber: 1024, version: 0, pcrPID: 0x100, streams: streams)
        }
        let superimpose = ElementaryStream(pid: 0x138, streamType: ElementaryStream.privatePES, componentTag: 0x38)
        let untagged = ElementaryStream(pid: 0x140, streamType: ElementaryStream.privatePES)
        let second = ElementaryStream(pid: 0x131, streamType: ElementaryStream.privatePES, componentTag: 0x31)
        let first = ElementaryStream(pid: 0x130, streamType: ElementaryStream.privatePES, componentTag: 0x30)
        #expect(map([superimpose, untagged, second, first]).caption?.pid == 0x130)
        #expect(map([superimpose, second]).caption?.pid == 0x131)
        #expect(map([superimpose, untagged]).caption == nil)
    }

    @Test("1 パケットに収まる PES は、次の PES を待たずにその場で出す")
    func singlePacketPESIsEmittedAtOnce() {
        var continuity: UInt8 = 0
        let pat = SISample.section(tableID: 0x00, body: [0x12, 0x34, 0xC1, 0x00, 0x00, 0x04, 0x00, 0xE1, 0xF0])
        let pmt = SISample.section(tableID: 0x02, body: [0x04, 0x00, 0xC1, 0x00, 0x00, 0xE1, 0x00, 0xF0, 0x00,
                                                          0x06, 0xE1, 0x30, 0xF0, 0x03, 0x52, 0x01, 0x30])
        var data = SISample.packets(pid: 0x0000, section: pat, continuity: &continuity)
        data += SISample.packets(pid: 0x01F0, section: pmt, continuity: &continuity)
        // PES（stream_id 0xBD・PTS 付き）の中身は 4 バイト。残りは適応フィールドで埋める
        let body: [UInt8] = [0x80, 0xFF, 0xF0, 0x00]
        let header: [UInt8] = [0x84, 0x80, 0x05, 0x21, 0x00, 0x01, 0x00, 0x01]
        let pes: [UInt8] = [0x00, 0x00, 0x01, 0xBD, 0x00, UInt8(header.count + body.count)] + header + body
        let stuffing = 183 - pes.count
        let packet: [UInt8] = [0x47, 0x41, 0x30, 0x30, UInt8(stuffing), 0x00] + Array(repeating: 0xFF, count: stuffing - 1) + pes
        data += Data(packet)
        let events = TSDemuxer().feed(data)
        let found = events.compactMap { event -> PESPacket? in
            if case let .pes(packet) = event, packet.pid == 0x130 { packet } else { nil }
        }
        #expect(found.count == 1)
        #expect(found.first?.payload == Data(body))
    }
}
