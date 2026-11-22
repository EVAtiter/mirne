import Foundation
import Testing

// 字幕の重ね描きが、出す字幕を決め直す間隔（2026-11-21）。字幕を画面に出しうるときだけ短く見る
struct CaptionOverlayTimingTests {
    @Test("再生していて・字幕を出す設定で・字幕の ES があるときだけ 30 ms。ほかは 250 ms")
    func intervalFollowsState() {
        #expect(CaptionOverlayTiming.interval(isPlaying: true, isEnabled: true, hasCaptionStream: true) == .milliseconds(30))
        for (playing, enabled, stream) in [(false, true, true), (true, false, true), (true, true, false), (false, false, false)] {
            #expect(CaptionOverlayTiming.interval(isPlaying: playing, isEnabled: enabled, hasCaptionStream: stream) == .milliseconds(250))
        }
    }
}
