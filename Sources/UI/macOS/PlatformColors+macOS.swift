import AppKit
import SwiftUI

extension Color {
    /// 窓の背景の色（macOS 版。白黒を反転させたボタンの文字・番組表の枠に使う）
    static var windowBackground: Color { Color(nsColor: .windowBackgroundColor) }
    /// 副次の文字の色（macOS 版。番組表の日の境目の線に使う）
    static var secondaryLabelText: Color { Color(nsColor: .secondaryLabelColor) }
    /// 区切り線の色（macOS 版。番組表の区切り線に使う）
    static var separatorLine: Color { Color(nsColor: .separatorColor) }
    /// 一覧の行のもとの背景（macOS 版。行は透明で一覧の地が見えるので、重ねる下地は要らない）
    static var listRowBase: Color { .clear }

    /// 「#RRGGBB」（sRGB）。色の選択で別の色空間の色が来ても sRGB に直してから書く
    var hexString: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        func component(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", component(color.redComponent), component(color.greenComponent), component(color.blueComponent))
    }
}
