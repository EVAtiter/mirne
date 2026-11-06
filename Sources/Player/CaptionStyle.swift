import CoreGraphics
import Foundation

/// 字幕の点滅（FLC）
public enum CaptionFlash {
    /// 半周期（90 kHz。0.5 秒）。字幕を出した時刻から数え、正相はこの間出してこの間消し、逆相はその逆。
    /// 描く側は時計を見る間隔（30 ms）ごとに決め直すので、その幅でずれる
    public static let halfPeriod: Int64 = 45_000
}

extension CaptionCue {
    /// 点滅で消えている時刻か。正相（1）は出した時刻から半周期出して半周期消し、逆相（2）はその逆
    public func isHiddenByFlash(at time: Int64) -> Bool {
        guard text.flash != 0 else { return false }
        let firstHalf = max(time - showAt, 0) / CaptionFlash.halfPeriod % 2 == 0
        return firstHalf != (text.flash == 1)
    }
}

/// 字幕の 1 文字の形の決め方
public enum CaptionGlyphShape {
    /// 描く文字と、横に伸ばす倍率。文字は高さに合わせた大きさで描き、幅を文字の大きさの縦横比に合わせる。
    /// 半角の文字（英数など）は、文字の大きさが正方形以上（標準・小型・横倍など）なら全角の形にしてから伸ばす
    /// （受信機は標準の大きさの英数を全角で出す）。中型（幅が半分）なら半角のまま描く
    public static func shape(_ scalar: Unicode.Scalar, glyphWidth: CGFloat, glyphHeight: CGFloat) -> (Character, CGFloat) {
        let ratio = glyphWidth / max(glyphHeight, 1)
        let character = Character(scalar)
        guard isNarrow(scalar) else { return (character, ratio) }
        if ratio >= 1 { return (ARIBStringDecoder.fullWidth(character), ratio) }
        return (character, ratio * 2)
    }

    /// 半角の文字か（ラテン文字・記号と、半角カタカナ）
    public static func isNarrow(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x1100 || (0xFF61...0xFFDC).contains(scalar.value)
    }

    /// 文字の大きさ（字幕の画面の画素）にいちばん近い外字の形
    public static func closest(_ glyphs: [CaptionDRCSGlyph], width: Int, height: Int) -> CaptionDRCSGlyph? {
        glyphs.min { abs($0.width - width) + abs($0.height - height) < abs($1.width - width) + abs($1.height - height) }
    }
}

/// 外字（DRCS）の図形を、文字の色と階調の濃さの画像にする
public enum CaptionDRCSImage {
    /// 階調 0 は透明、いちばん上の階調が文字の色。乗算済みのアルファの RGBA
    public static func make(_ glyph: CaptionDRCSGlyph, color: CaptionColor) -> CGImage? {
        guard glyph.width > 0, glyph.height > 0, glyph.bitmap.count >= glyph.width * glyph.height else { return nil }
        let top = Double(max(glyph.levels - 1, 1))
        var pixels = [UInt8]()
        pixels.reserveCapacity(glyph.width * glyph.height * 4)
        for level in glyph.bitmap.prefix(glyph.width * glyph.height) {
            let alpha = min(Double(level) / top, 1) * Double(color.a) / 255
            pixels += [UInt8(Double(color.r) * alpha), UInt8(Double(color.g) * alpha), UInt8(Double(color.b) * alpha), UInt8(alpha * 255)]
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: glyph.width, height: glyph.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: glyph.width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
