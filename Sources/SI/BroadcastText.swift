// torne mobile HB（MIT、© mar1mo-41414）の lib/core/broadcast_text.dart を Swift へ移植したもの。

import CoreText
import Foundation
import Synchronization

/// 放送の文字の番組マーク（[字]・[手] など）を、角括弧の表記にそろえる（plan.md §16.1・§21.6）。
///
/// nasne の FW は、ARIB STD-B24 の追加記号（90 区 48〜84 点）を 2 通りで渡してくる：
/// SOAP・JSON の経路では私用領域（PUA）の文字、番組表の経路では ARIB のデコーダが出す囲み文字（U+1F2xx など）。
/// どちらも Mac のフォントに字形が無いことがあるので、モデルに入る入口で角括弧の表記に置き換える。
/// 表に無い PUA の文字はそのまま通す（呼び方を作らない）。
public enum BroadcastText {
    /// PUA の番組マーク（AFS の ARIB 外字の割り当て）
    static let puaReplacements: [UInt32: String] = [
        0xE0F8: "[HV]", 0xE0F9: "[SD]", 0xE0FA: "[P]", 0xE0FB: "[W]", 0xE0FC: "[MV]",
        0xE0FD: "[手]", 0xE0FE: "[字]", 0xE0FF: "[双]", 0xE180: "[デ]", 0xE181: "[S]",
        0xE182: "[二]", 0xE183: "[多]", 0xE184: "[解]", 0xE185: "[SS]", 0xE186: "[B]",
        0xE187: "[N]", 0xE18A: "[天]", 0xE18B: "[交]", 0xE18C: "[映]", 0xE18D: "[無]",
        0xE18E: "[料]", 0xE190: "[前]", 0xE191: "[後]", 0xE192: "[再]", 0xE193: "[新]",
        0xE194: "[初]", 0xE195: "[終]", 0xE196: "[生]", 0xE197: "[販]", 0xE198: "[声]",
        0xE199: "[吹]", 0xE19A: "[PPV]", 0xE19C: "[ほか]",
        // 90/83 ㊙ は FW が通常の Unicode で送るとされていたが、実測では PUA で届いた（torne mobile HB の plan.md §56.3）。
        // 番組表の経路（ARIBStringDecoder）が出す U+3299 にそろえる
        0xE19B: "\u{3299}",
        // 90 区の外。DIDL と EIT の同じ位置の突き合わせで ⁉（U+2049）と分かった（§56.3）。番組表の経路も U+2049 を出す
        0xE2F0: "\u{2049}",
    ]

    /// 同じ番組マークの、通常の Unicode の囲み文字
    static let unicodeReplacements: [UInt32: String] = [
        0x1F14A: "[HV]", 0x1F14C: "[SD]", 0x1F13F: "[P]", 0x1F146: "[W]", 0x1F14B: "[MV]",
        0x1F210: "[手]", 0x1F211: "[字]", 0x1F212: "[双]", 0x1F213: "[デ]", 0x1F142: "[S]",
        0x1F214: "[二]", 0x1F215: "[多]", 0x1F216: "[解]", 0x1F14D: "[SS]", 0x1F131: "[B]",
        0x1F13D: "[N]", 0x1F217: "[天]", 0x1F218: "[交]", 0x1F219: "[映]", 0x1F21A: "[無]",
        0x1F21B: "[料]", 0x1F21C: "[前]", 0x1F21D: "[後]", 0x1F21E: "[再]", 0x1F21F: "[新]",
        0x1F220: "[初]", 0x1F221: "[終]", 0x1F222: "[生]", 0x1F223: "[販]", 0x1F224: "[声]",
        0x1F225: "[吹]", 0x1F14E: "[PPV]", 0x1F200: "[ほか]",
    ]

    public static func normalize(_ input: String) -> String {
        normalize(input, keepsEnclosed: { _ in false })
    }

    /// 囲み文字のうち `keepsEnclosed` が true を返すものは、角括弧にせずそのまま残す（番組表の経路）。
    /// PUA の番組マークはいつも角括弧にする
    static func normalize(_ input: String, keepsEnclosed: (Unicode.Scalar) -> Bool) -> String {
        guard input.unicodeScalars.contains(where: { puaReplacements[$0.value] != nil || unicodeReplacements[$0.value] != nil })
        else { return input }
        var output = ""
        for scalar in input.unicodeScalars {
            if let replacement = puaReplacements[scalar.value] {
                output += replacement
            } else if let replacement = unicodeReplacements[scalar.value], !keepsEnclosed(scalar) {
                output += replacement
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }
}

/// Mac のフォントに字形がある文字か（システムのフォントから代わりのフォントを探し、LastResort に落ちなければある）。
/// 番組マークの数は限られるので、文字ごとに一度だけ調べて覚えておく
enum GlyphAvailability {
    /// 調べるときの基準のフォント（番組表の文字と同じシステムのフォント。大きさは字形の有無に関わらない）
    private static let probeFontSize: CGFloat = 13
    /// 字形が無いときに CoreText が選ぶフォント
    private static let lastResortName = "LastResort"
    private static let cache = Mutex<[UInt32: Bool]>([:])

    static func hasGlyph(_ scalar: Unicode.Scalar) -> Bool {
        if let known = cache.withLock({ $0[scalar.value] }) { return known }
        let base = CTFontCreateUIFontForLanguage(.system, probeFontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, probeFontSize, nil)
        let string = String(Character(scalar)) as CFString
        let font = CTFontCreateForString(base, string, CFRange(location: 0, length: CFStringGetLength(string)))
        let found = (CTFontCopyPostScriptName(font) as String) != lastResortName
        cache.withLock { $0[scalar.value] = found }
        return found
    }
}

/// 番組表の経路（EPGStore から読んだ番組）の番組マークのうち、Mac のフォントに字形の無い囲み文字を角括弧にする。
/// 字形のある囲み文字（🈑 など）はそのまま出す。番組表は mirne のデコーダが出す囲み文字のまま保存しているので、読み出したところで置き換える
/// （🅍 など字形の無い文字が「?」で出ていた。2026-11-21）
public extension EPGStore.ServiceSchedule {
    func normalizingBroadcastMarks() -> Self {
        normalizingBroadcastMarks(keepsEnclosed: GlyphAvailability.hasGlyph)
    }

    internal func normalizingBroadcastMarks(keepsEnclosed: (Unicode.Scalar) -> Bool) -> Self {
        var schedule = self
        schedule.events = events.map { event in
            var event = event
            event.title = BroadcastText.normalize(event.title, keepsEnclosed: keepsEnclosed)
            event.text = BroadcastText.normalize(event.text, keepsEnclosed: keepsEnclosed)
            return event
        }
        return schedule
    }
}
