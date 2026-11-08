import SwiftUI

/// mirne のエントリポイント。
///
/// 視聴ウィンドウを 1 つ開く。環境変数 `MIRNE_LAB_FILE`・`MIRNE_LAB_FREQ` があるときは、
/// 再生系の計測用の画面（PlaybackLab）を開く（再生系の計測に使う）。
@main
struct MirneApp: App {
    @State private var model: ViewerModel?

    private static let usesLab: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["MIRNE_LAB_FILE"] != nil || environment["MIRNE_LAB_FREQ"] != nil
    }()

    init() {
        if !Self.usesLab {
            _model = State(initialValue: ViewerModel())
        }
    }

    var body: some Scene {
        Window("mirne", id: "viewer") {
            if let model {
                ViewerView(model: model)
            } else {
                PlayerWindowView()
            }
        }
        .defaultSize(PlayerWindowLayout.defaultSize)
        .commands {
            if let model {
                ViewerCommands(model: model)
            }
        }
        Window("番組表", id: WindowID.guide) {
            if let model {
                GuideView(model: model)
                    .background(WindowAccessor { model.guideWindowController.attach($0) })
            }
        }
        .defaultSize(GuideLayout.windowSize)
        Settings {
            if let model {
                SettingsView(model: model)
            }
        }
    }
}
