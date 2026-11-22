import SwiftUI
import UIKit

extension Color {
    /// 画面の背景の色（iPad 版。白黒を反転させたボタンの文字・番組表の枠に使う）
    static var windowBackground: Color { Color(uiColor: .systemBackground) }
    /// 副次の文字の色（iPad 版。番組表の日の境目の線に使う）
    static var secondaryLabelText: Color { Color(uiColor: .secondaryLabel) }
    /// 区切り線の色（iPad 版。番組表の区切り線に使う）
    static var separatorLine: Color { Color(uiColor: .separator) }
    /// 一覧の行のもとの背景（iPad 版。角丸の区画の行の色）。行を塗り分けるとき、この上に淡い色を重ねる
    /// （重ねずに淡い色だけにすると、下の灰色の地が透けて色が濃く見えた）
    static var listRowBase: Color { Color(uiColor: .secondarySystemGroupedBackground) }

    /// 「#RRGGBB」（sRGB）。別の色空間の色が来ても sRGB に直してから書く
    var hexString: String {
        let color = UIColor(self).resolvedColor(with: UITraitCollection.current)
        // 直せなければ灰色（macOS 版の `.gray` と同じ）
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let parts = color.cgColor.converted(to: space, intent: .defaultIntent, options: nil)?.components,
              parts.count >= 3 else { return "#808080" }
        func component(_ index: Int) -> Int { Int((min(max(parts[index], 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", component(0), component(1), component(2))
    }
}
