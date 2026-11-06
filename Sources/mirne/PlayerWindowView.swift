import SwiftUI
import UniformTypeIdentifiers

/// 視聴ウィンドウの寸法。
enum PlayerWindowLayout {
    /// 放送の表示アスペクト比（16:9）
    static let aspectRatio: CGFloat = 16.0 / 9.0
    /// 初回に開くときの大きさ（16:9 の 960×540）
    static let defaultSize = CGSize(width: 960, height: 540)
}

/// 再生系の計測用のウィンドウ（PlaybackLab）。
///
/// 環境変数 `MIRNE_LAB_FILE`・`MIRNE_LAB_FREQ` を付けて起動したときだけ開く（MirneApp）。ふだんは ViewerView。
struct PlayerWindowView: View {
    @State private var lab = PlaybackLab()
    @State private var choosingFile = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let renderer = lab.renderer {
                MetalVideoView(renderer: renderer)
            } else {
                Text("Metal を使えません").foregroundStyle(.secondary)
            }
            CaptionOverlayView(model: lab.captions)
            Text(lab.statusText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.55))
                .padding(8)
        }
        .toolbar {
            Button("TS を開く…") { choosingFile = true }
            Picker("デインターレース", selection: $lab.deinterlace) {
                Text("動き適応").tag(DeinterlaceMode.adaptive)
                Text("bob").tag(DeinterlaceMode.bob)
                Text("weave").tag(DeinterlaceMode.weave)
            }
            .pickerStyle(.segmented)
            Button("止める") { lab.stop() }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.mpeg2TransportStream, .data]) { result in
            if case let .success(url) = result { lab.open(url) }
        }
    }
}
