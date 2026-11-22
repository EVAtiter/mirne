// アイコンの PNG を、面積平均（box フィルター）で整数分の 1 に縮めて書き出す。
//
// 使い方: swift scripts/area-downscale.swift <入力.png> <出力の一辺 px> <出力.png>
//         （入力の一辺は出力の一辺で割り切れること。ふつうは 1024 → 16）
//
// なぜ sips で縮めないか（scripts/make-icon.sh から 16×16 の 1 枚だけに使う）:
//   macOS 27 の IconServices（ISShapeDetection）は、画像だけのアイコンをサイズごとに調べ、
//   中央の行と列で「不透明度が 253 以上の最初の画素」を板の端とし、板の四隅から斜めに
//   253 以上になるまでの距離で角丸を見積もる。角丸が 0（四角）や大きすぎる（円）と判定された
//   サイズは、縮めて灰色の箱に入れられる。
//   sips（や lanczos）で 16px に縮めると板の縁がぼやけ、端の列が 240 前後で 253 に届かない。
//   板が 1 画素内側（幅 10px）と判定され、その角は 255 なので角丸 0 = 四角となって箱に入る。
//   面積平均なら板の内側の列は 255 になり、幅 12px・角丸 3 と判定されて箱に入らない。
//   32px 以上は sips のままで通るので、この縮め方を使うのは 16×16（1x）の 1 枚だけ。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 画素の並び（sRGB・8 bit・乗算済みアルファ・RGBA）
enum PixelFormat {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    static let bytesPerPixel = 4
    static let bitsPerComponent = 8
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 4, let outSize = Int(args[2]), outSize > 0 else {
    fail("使い方: area-downscale.swift <入力.png> <出力の一辺 px> <出力.png>")
}
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let input = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("入力を読めません: \(args[1])")
}
let inSize = input.width
guard input.height == inSize, inSize % outSize == 0 else {
    fail("入力は正方形で、一辺が \(outSize) で割り切れること（入力 \(input.width)x\(input.height)）")
}
let factor = inSize / outSize

/// 画像を指定の一辺で RGBA の画素列にする
func makeContext(size: Int) -> CGContext {
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: PixelFormat.bitsPerComponent,
                              bytesPerRow: size * PixelFormat.bytesPerPixel,
                              space: PixelFormat.colorSpace, bitmapInfo: PixelFormat.bitmapInfo) else {
        fail("コンテキストを作成できません")
    }
    return ctx
}

// 入力を等倍で画素列へ（縮小はここでは行わない）
let inCtx = makeContext(size: inSize)
inCtx.draw(input, in: CGRect(x: 0, y: 0, width: inSize, height: inSize))
let inPixels = inCtx.data!.bindMemory(to: UInt8.self, capacity: inSize * inSize * PixelFormat.bytesPerPixel)

// factor × factor の区画ごとに、乗算済みの成分を平均する（= 面積平均）
let outCtx = makeContext(size: outSize)
let outPixels = outCtx.data!.bindMemory(to: UInt8.self, capacity: outSize * outSize * PixelFormat.bytesPerPixel)
let samplesPerBlock = factor * factor
for oy in 0..<outSize {
    for ox in 0..<outSize {
        var sums = [Int](repeating: 0, count: PixelFormat.bytesPerPixel)
        for iy in (oy * factor)..<((oy + 1) * factor) {
            for ix in (ox * factor)..<((ox + 1) * factor) {
                let base = (iy * inSize + ix) * PixelFormat.bytesPerPixel
                for c in 0..<PixelFormat.bytesPerPixel { sums[c] += Int(inPixels[base + c]) }
            }
        }
        let base = (oy * outSize + ox) * PixelFormat.bytesPerPixel
        for c in 0..<PixelFormat.bytesPerPixel {
            // 四捨五入（区画の画素数の半分を足して割る）
            outPixels[base + c] = UInt8((sums[c] + samplesPerBlock / 2) / samplesPerBlock)
        }
    }
}

guard let output = outCtx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else {
    fail("PNG を作成できません")
}
CGImageDestinationAddImage(dest, output, nil)
guard CGImageDestinationFinalize(dest) else { fail("PNG の書き出しに失敗しました") }
