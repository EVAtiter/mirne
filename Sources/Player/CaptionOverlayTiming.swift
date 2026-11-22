import Foundation

// 字幕の重ね描き（CaptionOverlay）が、出す字幕を決め直す間隔（2026-11-21 に CaptionOverlay から分け、間隔の選び方を足した）。
// AppKit・SwiftUI に依存させない（試験で間隔の選び方を確かめる）

/// 字幕の重ね描きの決まり
enum CaptionOverlayTiming {
    /// 再生の時計を見て、出す字幕を決め直す間隔。字幕は映像と 0.2 秒以内に合えばよい（完了の判定）ので、
    /// 毎フレームではなくこの間隔で見る（出す字幕が変わったときだけ SwiftUI が描き直す）
    static let pollInterval: Duration = .milliseconds(30)
    /// 字幕を出さなくてよい間に見直す間隔。再生が始まった・字幕を出すようにした・字幕の ES が現れたのに気付ければよい。
    /// 再生の始めや字幕の ES が現れた直後に字幕が出ていることはまず無いので、最初の字幕がこの分遅れても困らない
    static let idlePollInterval: Duration = .milliseconds(250)

    /// 次に見直すまでの間隔。再生していて（時計が動いていて止めていない）、字幕を出す設定で、今のサービスに字幕の ES があるときだけ短く見る。
    ///
    /// 時計が止まっている間は、出す字幕も点滅も変わらない。字幕を出さない設定のとき・字幕の無い番組では、
    /// 出す字幕を決め直しても画面に何も出ないので、前は 30 ms ごとに見ていたのを長い間隔にした（2026-11-21）。
    /// 字幕を出すようにしたときは、重ね描きのモデルがすぐ決め直す
    static func interval(isPlaying: Bool, isEnabled: Bool, hasCaptionStream: Bool) -> Duration {
        isPlaying && isEnabled && hasCaptionStream ? pollInterval : idlePollInterval
    }
}
