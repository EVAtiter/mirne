// アプリアイコンのマスター PNG（1024×1024・8-bit・sRGB）を描く。
// 使い方: swift scripts/make-icon.swift <出力.png> [standard|small]（scripts/make-icon.sh から呼ばれる）
//
// 図柄：淡い地に濃紺のテレビ（角丸の画面の枠と台）を置き、
// 白い画面の中央に青い「mirne」の文字。テレビの形は SF Symbols の tv と同じ形を自前で描く（SF Symbols は
// アプリのアイコンに使えない決まりのため）。
// macOS 標準のタイル（余白 100px・ベース 824px・連続角丸 = ベース × 0.2247）の内側に描く。small は 16×16（1x）専用の
// 余白の狭い絵（macOS 27 は標準の余白の 16px を灰色の箱に入れることがある。使うかは make-icon.sh を参照）。
// 色は CGColor(srgbRed:) で起こす（CGColor(red:) は Generic RGB で、焼いた画素が指定より明るくなる）
import AppKit
import SwiftUI

let canvas: CGFloat = 1024
/// macOS 標準の連続角丸の比（ベースに対する半径）
let cornerRatio: CGFloat = 0.2247
/// 標準の余白（macOS のアイコングリッド）
let standardMargin: CGFloat = 100
/// 16×16 専用の絵の余白（SendBlocker・Claude Meter で 16px が通った値）
let smallIconMargin: CGFloat = 64

let arguments = CommandLine.arguments
guard arguments.count > 1 else { fputs("使い方: make-icon.swift <出力.png> [standard|small]\n", stderr); exit(64) }
let out = arguments[1]
let variant = arguments.count > 2 ? arguments[2] : "standard"
let margin = variant == "small" ? smallIconMargin : standardMargin
let base = canvas - margin * 2
/// 絵柄の寸法は標準のベース（824px）で決めてあり、ベースの大きさに比例させる
let k = base / (canvas - standardMargin * 2)

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// 地（上 → 下の縦グラデーション）
let tileTop = color(0xF4F8FC), tileBottom = color(0xD5E2EF)
/// テレビの枠と台
let frameColor = color(0x1B2A4A)
/// 画面
let screenColor = color(0xFFFFFF)
/// 文字
let labelColor = color(0x1C6FE0)
let labelText = "mirne"

/// テレビの寸法（標準のベース 824px のとき）。画面の枠は 16:9
let frameWidth: CGFloat = 620 * k, frameStroke: CGFloat = 46 * k, frameCorner: CGFloat = 64 * k
let standWidth: CGFloat = 340 * k, standHeight: CGFloat = 40 * k, standGap: CGFloat = 42 * k
/// 文字の字面の幅
let labelWidth: CGFloat = 400 * k

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let n = Int(canvas)
let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                    space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

/// 文字を、字面の幅が width になる大きさで、字面の中心が point に来るように描く（SF Pro Rounded の Bold）
func drawLabel(_ text: String, color textColor: CGColor, centeredAt point: CGPoint, width: CGFloat) {
    func font(size: CGFloat) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: .bold)
        return system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? system
    }
    func line(size: CGFloat) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font(size: size), .foregroundColor: NSColor(cgColor: textColor)!,
        ]))
    }
    let reference: CGFloat = 100
    let measured = CTLineGetImageBounds(line(size: reference), ctx).width
    let typeset = line(size: reference * width / measured)
    let bounds = CTLineGetImageBounds(typeset, ctx)
    ctx.textPosition = CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
    CTLineDraw(typeset, ctx)
}

// タイル（連続角丸・縦のグラデーション）
let tile = CGRect(x: margin, y: margin, width: base, height: base)
ctx.saveGState()
ctx.addPath(roundedPath(tile, radius: base * cornerRatio))
ctx.clip()
let gradient = CGGradient(colorsSpace: srgb, colors: [tileTop, tileBottom] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
ctx.restoreGState()

// テレビ（枠と台をひとまとまりにして、タイルの上下の中央に置く）
let center = CGPoint(x: canvas / 2, y: canvas / 2)
let frameHeight = frameWidth * 9 / 16
let groupHeight = frameHeight + standGap + standHeight
let frame = CGRect(x: center.x - frameWidth / 2, y: center.y + groupHeight / 2 - frameHeight, width: frameWidth, height: frameHeight)
let framePath = roundedPath(frame.insetBy(dx: frameStroke / 2, dy: frameStroke / 2), radius: frameCorner)
ctx.addPath(framePath)
ctx.setFillColor(screenColor)
ctx.fillPath()
ctx.addPath(framePath)
ctx.setStrokeColor(frameColor)
ctx.setLineWidth(frameStroke)
ctx.strokePath()
let stand = CGRect(x: center.x - standWidth / 2, y: frame.minY - standGap - standHeight, width: standWidth, height: standHeight)
ctx.addPath(roundedPath(stand, radius: standHeight / 2))
ctx.setFillColor(frameColor)
ctx.fillPath()

// 画面の中央の文字
drawLabel(labelText, color: labelColor, centeredAt: CGPoint(x: center.x, y: frame.midY), width: labelWidth)

let image = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
