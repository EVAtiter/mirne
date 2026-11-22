import Foundation

/// MPEG-2 のピクチャを復号に回すかの判断。復号の仕組み（VideoToolbox・FFmpeg）によらず共通。
///
/// - 最初の I ピクチャ（シーケンスヘッダ付き）まで捨てる
/// - その直後の B ピクチャ（前の GOP を参照する先頭の B）は、最初の P を復号に回すまで捨てる
/// - 欠けた PES もそのまま回す（数だけ数える）。MPEG-2 はスライスごとに立ち直れるので、ブロックノイズは出ても
///   映像は止まらない（テレビと同じ振る舞い）。次の I まで捨てる方針は、0.1% のパケット欠落で
///   897 フレーム中 77 しか表示できず、止まって見えたので採らなかった（実測）
struct MPEG2PictureGate {
    private enum State {
        case waitingForIntra
        /// I を回した。P が来るまで B を捨てる
        case afterIntra
        case running
    }

    private var state = State.waitingForIntra
    /// 捨てたピクチャの数（理由ごと）
    private(set) var skippedBeforeIntra = 0
    private(set) var skippedLeadingB = 0
    /// 欠けたまま回したピクチャ
    private(set) var damagedPictures = 0

    /// このピクチャを復号に回すなら true。`hasSequenceHeader` は同じ PES にシーケンスヘッダがあったか
    mutating func admit(_ picture: MPEG2PictureInfo, hasSequenceHeader: Bool, damaged: Bool) -> Bool {
        if damaged {
            damagedPictures += 1
        }
        switch (state, picture.codingType) {
        case (.waitingForIntra, .intra) where hasSequenceHeader:
            state = .afterIntra
        case (.waitingForIntra, _):
            skippedBeforeIntra += 1
            return false
        case (.afterIntra, .bidirectional):
            skippedLeadingB += 1
            return false
        case (.afterIntra, .predicted):
            state = .running
        default:
            break
        }
        return true
    }

    /// 最初の I から始め直す（選局し直した・シーケンスが変わったとき）
    mutating func restart() {
        state = .waitingForIntra
    }
}
