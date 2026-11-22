import AppKit

/// アプリが窓の大きさを変えたことを、AppKit に「利用者が決めた大きさ」として覚えさせるための決まり
enum WindowUserSizeTiming {
    /// zoom の間だけ使う、窓の大きさを変える動きの長さ（AppKit の設定 NSWindowResizeTime。既定は 0.2 秒）。
    /// zoom は動きを付けるので、ほぼ 0 にして、`setFrame(_:display:animate: false)` と同じく動きなしにする
    static let zoomResizeTime: TimeInterval = 0.0001
    /// AppKit が読む設定の名前（文書に無い。`animationResizeTime(_:)` の既定が使う）
    static let resizeTimeDefaultsKey = "NSWindowResizeTime"
}

extension NSWindow {
    /// 位置と大きさを当て、その大きさを AppKit に「利用者が決めた大きさ」として覚えさせる。
    ///
    /// AppKit は窓ごとに、利用者が最後に決めた大きさ（手で変えた・zoom した）を画面ごとに覚え（`_lastUserWindowLayoutsByScreenUUID`）、
    /// 窓を別の画面へドラッグし終えたとき、その画面での配置が最後に利用者が大きさを変えた後のものでなければ、覚えた大きさを当て直す
    /// （`-[NSWindow(NSScreenLayout) _setFrame:fromAdjustmentToScreen:anchor:animate:]`）。
    /// `setFrame` で変えた大きさは覚えないので、手で大きくした後に「標準の大きさに戻す」と、ほかの画面へ移すたびに手で決めた大きさへ戻った
    /// （2026-11-22 に実測。macOS 27.2）。公開の操作で覚えさせられるのは zoom だけだったので、最大の大きさを一時的に目標へ絞って zoom する
    func setFrameAsUserSize(_ frame: CGRect) {
        guard frame.size != self.frame.size else {
            setFrame(frame, display: true, animate: false)
            return
        }
        let previousMaximum = contentMaxSize
        contentMaxSize = contentRect(forFrameRect: frame).size
        withoutResizeAnimation { zoom(nil) }
        contentMaxSize = previousMaximum
        // zoom は左上を保つが、画面に収まらないときなどは位置が違うので、最後に目標どおりに当てる（大きさが同じなら覚えた大きさは変わらない）
        if self.frame != frame {
            setFrame(frame, display: true, animate: false)
        }
    }

    /// 窓の大きさを変える動きを、間だけほぼ 0 にする（設定の登録の段に置き、終わったら元に戻す。保存はしない）
    private func withoutResizeAnimation(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let registered = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        var shortened = registered
        shortened[WindowUserSizeTiming.resizeTimeDefaultsKey] = WindowUserSizeTiming.zoomResizeTime
        defaults.setVolatileDomain(shortened, forName: UserDefaults.registrationDomain)
        body()
        defaults.setVolatileDomain(registered, forName: UserDefaults.registrationDomain)
    }
}
