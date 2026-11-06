import Foundation
import Observation
import os
import SwiftUI

/// 字幕の重ね描きの決まり。
enum CaptionOverlayTiming {
    /// 再生の時計を見て、出す字幕を決め直す間隔。字幕は映像と 0.2 秒以内に合えばよい（完了の判定）ので、
    /// 毎フレームではなくこの間隔で見る（出す字幕が変わったときだけ SwiftUI が描き直す）
    static let pollInterval: Duration = .milliseconds(30)
}

/// 字幕の文字の見え方
enum CaptionAppearance {
    /// 文字の縁（影を重ねて縁取りに見せる）の太さ（字幕の画面の画素）
    static let edgeRadius: CGFloat = 1.5
    /// 縁の影を重ねる回数（1 回だと薄い）
    static let edgeLayers = 3
    /// 縁取り（ORN）の指定が無いときの縁の色。放送の指定どおり縁を付けないと、白い文字が明るい映像に埋もれるので、
    /// 受信機の多くと同じく黒い縁を付ける
    static let defaultEdgeColor = CaptionColor.black
    /// 囲み（HLC）の線の太さ（字幕の画面の画素）
    static let enclosureLineWidth: CGFloat = 2
}

/// 出す字幕を再生の時計で決める。
///
/// 再生系が PTS で並べた字幕（`CaptionTimeline`）を、映像と同じ「描いてから画面に出るまでの遅れ」を足した時刻で読む。
/// 出す字幕が変わったときに、出し始めの遅れ（その時刻 − 出すべき時刻）を記録する（検証用）
@MainActor
@Observable
final class CaptionOverlayModel {
    /// 字幕を出すか
    var isEnabled: Bool
    /// いま出している字幕（`isEnabled` でなくても、決めておく）
    private(set) var cues: [CaptionCue] = []
    /// いまのサービスに字幕の ES があるか（オーバーレイの表示用）
    private(set) var isAvailable = false
    /// 映像の表示アスペクト比（字幕の画面を映像の矩形に重ねる）
    private(set) var displayAspectRatio: Double = PlayerWindowLayout.aspectRatio
    /// 点滅（FLC）で、いま消えている字幕（`CaptionCue.id`）
    private(set) var hiddenByFlash: Set<Int> = []

    /// 出し始めの遅れ（ミリ秒）の記録（検証用）
    @ObservationIgnored private(set) var lateness: [Double] = []
    @ObservationIgnored private let engine: PlayerEngine
    @ObservationIgnored private weak var renderer: VideoRenderer?
    @ObservationIgnored private var polling: Task<Void, Never>?
    /// 字幕を出した時刻の記録（実放送で字幕が遅れるときの切り分け用。本文の文字は出さない）
    @ObservationIgnored private let logger = Logger(subsystem: "com.slack-kingdom.mirne", category: "caption")

    init(engine: PlayerEngine, renderer: VideoRenderer?, isEnabled: Bool) {
        self.engine = engine
        self.renderer = renderer
        self.isEnabled = isEnabled
        polling = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: CaptionOverlayTiming.pollInterval)
            }
        }
    }

    isolated deinit {
        polling?.cancel()
    }

    private func refresh() {
        let available = engine.hasCaptionStream
        if available != isAvailable { isAvailable = available }
        if let aspect = renderer?.displayAspectRatio, aspect != displayAspectRatio { displayAspectRatio = aspect }
        guard let now = engine.presentationTime() else {
            if !cues.isEmpty { cues = [] }
            return
        }
        let time = now + (renderer?.presentationDelayTicks ?? 0)
        let visible = engine.captions.visible(at: time)
        if visible.map(\.id) != cues.map(\.id) {
            let shown = Set(cues.map(\.id))
            for cue in visible where !shown.contains(cue.id) {
                let late = Double(time - cue.showAt) / 90
                lateness.append(late)
                logger.info("字幕を出した: 出すべき時刻からの遅れ \(String(format: "%.0f ms", late), privacy: .public)・文字 \(cue.text.text.unicodeScalars.count, privacy: .public)")
            }
            cues = visible
        }
        let hidden = Set(visible.filter { $0.isHiddenByFlash(at: time) }.map(\.id))
        if hidden != hiddenByFlash { hiddenByFlash = hidden }
    }

    func resetStatistics() {
        lateness.removeAll()
    }
}

/// 字幕を映像の矩形に重ねて描く。字幕を出さない設定なら何も描かない
struct CaptionOverlayView: View {
    let model: CaptionOverlayModel

    var body: some View {
        if model.isEnabled {
            CaptionLayer(cues: model.cues, displayAspectRatio: model.displayAspectRatio, hiddenByFlash: model.hiddenByFlash)
        }
    }
}

/// 字幕の文字を置く。字幕の画面（960×540 など）の画素を、映像の矩形へ拡大する
struct CaptionLayer: View {
    let cues: [CaptionCue]
    let displayAspectRatio: Double
    /// 点滅で消えている字幕
    var hiddenByFlash: Set<Int> = []

    var body: some View {
        GeometryReader { geometry in
            let rect = Self.videoRect(in: geometry.size, aspect: displayAspectRatio)
            ForEach(cues) { cue in
                CaptionCueView(cue: cue, rect: rect, showsGlyphs: !hiddenByFlash.contains(cue.id))
            }
        }
        .allowsHitTesting(false)
    }

    /// 表示アスペクト比を保って、ウィンドウの中に収めた映像の矩形（描画側の letterboxScale と同じ）
    static func videoRect(in size: CGSize, aspect: Double) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let viewAspect = size.width / size.height
        if viewAspect > aspect {
            let width = size.height * aspect
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        }
        let height = size.width / aspect
        return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
    }
}

/// 字幕の文字の並び 1 つ。1 文字ずつ升目に置く（全角・半角で字送りがずれないように）。
/// 升目の数え方は `CaptionPresenter` と同じく、Unicode のスカラー値 1 つが 1 升目
private struct CaptionCueView: View {
    let cue: CaptionCue
    let rect: CGRect
    /// 文字を描くか（点滅で消えている間は false。背景と囲みは残す）
    let showsGlyphs: Bool

    var body: some View {
        let scaleX = rect.width / CGFloat(max(cue.screenWidth, 1))
        let scaleY = rect.height / CGFloat(max(cue.screenHeight, 1))
        let text = cue.text
        let scalars = Array(text.text.unicodeScalars)
        let cellSize = CGSize(width: CGFloat(text.cellWidth) * scaleX, height: CGFloat(text.cellHeight) * scaleY)
        let glyphSize = CGSize(width: CGFloat(text.glyphWidth) * scaleX, height: CGFloat(text.glyphHeight) * scaleY)
        let origin = CGPoint(x: rect.minX + CGFloat(text.x) * scaleX, y: rect.minY + CGFloat(text.y) * scaleY)
        ForEach(Array(scalars.enumerated()), id: \.offset) { index, scalar in
            // 升目の枠を先に置き、背景と文字をそれに重ねる。文字の自然な幅は升目より広いことがある（中型の全角の文字は、
            // 縮める前の幅で並べられる）ので、背景を文字と同じ ZStack に置くと背景まで広がり、隣の升目の半透明の背景と重なって濃い帯になる。
            // 空白の升目は文字を描かないので、枠を文字に持たせると背景ごと消える
            Color.clear
                .frame(width: cellSize.width, height: cellSize.height)
                .background { CaptionCellBackground(color: text.background) }
                .overlay {
                    CaptionCell(scalar: scalar, text: text, glyphs: cue.drcs[scalar], glyphSize: glyphSize,
                                glyphPixels: (text.glyphWidth, text.glyphHeight), scale: scaleY, showsGlyph: showsGlyphs)
                }
                .position(x: origin.x + cellSize.width * (CGFloat(index) + 0.5), y: origin.y + cellSize.height / 2)
        }
        if text.enclosure != 0 {
            // 囲み（HLC）は文字の塊を囲む：上下は並び全体、左は先頭、右は最後の升目にだけ引く
            let runSize = CGSize(width: cellSize.width * CGFloat(scalars.count), height: cellSize.height)
            CaptionEnclosure(sides: text.enclosure)
                .stroke(Color(caption: text.foreground), lineWidth: CaptionAppearance.enclosureLineWidth * scaleY)
                .frame(width: runSize.width, height: runSize.height)
                .position(x: origin.x + runSize.width / 2, y: origin.y + runSize.height / 2)
        }
    }
}

/// 字幕の 1 升目の背景（空白の升目も塗る）
private struct CaptionCellBackground: View {
    let color: CaptionColor

    var body: some View {
        if color.a > 0 {
            Rectangle().fill(Color(caption: color))
        }
    }
}

/// 字幕の 1 升目の文字（外字なら図形）。背景は `CaptionCellBackground`
private struct CaptionCell: View {
    let scalar: Unicode.Scalar
    let text: CaptionText
    let glyphs: [CaptionDRCSGlyph]?
    let glyphSize: CGSize
    /// 文字の大きさ（字幕の画面の画素）。外字の形を選ぶのに使う
    let glyphPixels: (width: Int, height: Int)
    let scale: CGFloat
    let showsGlyph: Bool

    var body: some View {
        if showsGlyph {
            glyph
        }
    }

    @ViewBuilder private var glyph: some View {
        if CaptionDRCS.contains(scalar) {
            if let glyph = glyphs.flatMap({ CaptionGlyphShape.closest($0, width: glyphPixels.width, height: glyphPixels.height) }),
               let image = CaptionDRCSImage.make(glyph, color: text.foreground) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: glyphSize.width, height: glyphSize.height)
                    .modifier(CaptionEdge(color: text.outline ?? CaptionAppearance.defaultEdgeColor,
                                          radius: CaptionAppearance.edgeRadius * scale))
            }
        } else if scalar != " " {
            let (character, widthScale) = CaptionGlyphShape.shape(scalar, glyphWidth: glyphSize.width, glyphHeight: glyphSize.height)
            Text(String(character))
                .font(.system(size: glyphSize.height, weight: .medium))
                .foregroundStyle(Color(caption: text.foreground))
                .modifier(CaptionEdge(color: text.outline ?? CaptionAppearance.defaultEdgeColor,
                                      radius: CaptionAppearance.edgeRadius * scale))
                .fixedSize()
                .scaleEffect(x: widthScale, y: 1)
        }
    }
}

/// 囲み（HLC）の線。ビット 1 が右・2 が下・4 が左・8 が上
private struct CaptionEnclosure: Shape {
    let sides: UInt8

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if sides & 0x1 != 0 { path.move(to: CGPoint(x: rect.maxX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)) }
        if sides & 0x2 != 0 { path.move(to: CGPoint(x: rect.minX, y: rect.maxY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)) }
        if sides & 0x4 != 0 { path.move(to: CGPoint(x: rect.minX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)) }
        if sides & 0x8 != 0 { path.move(to: CGPoint(x: rect.minX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)) }
        return path
    }
}

/// 影を何回か重ねて、文字の縁取りに見せる
private struct CaptionEdge: ViewModifier {
    let color: CaptionColor
    let radius: CGFloat

    func body(content: Content) -> some View {
        (0..<CaptionAppearance.edgeLayers).reduce(AnyView(content)) { view, _ in
            AnyView(view.shadow(color: Color(caption: color), radius: radius))
        }
    }
}

extension Color {
    /// 字幕の色（CLUT の値は sRGB）
    init(caption color: CaptionColor) {
        self.init(.sRGB, red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255,
                  opacity: Double(color.a) / 255)
    }
}
