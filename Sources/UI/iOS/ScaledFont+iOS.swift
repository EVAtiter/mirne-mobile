import SwiftUI
import UIKit

extension ScaledFont {
    /// 文字の形の大きさと、既定で太字か。
    ///
    /// iPad の文字は macOS より大きく、端末の設定（文字を大きく）でも変わるので、文字の大きさの「標準」は端末の大きさのままにする。
    /// 掛ける倍率（`MainTextSize.scale`）は macOS の既定の文字に合わせた値なので、ここで「標準」の倍率で割っておく
    /// （「標準」は端末の大きさ、「大きい」はその「大きい」÷「標準」倍＝約 1.2 倍）
    static func base(_ style: Font.TextStyle) -> (size: CGFloat, bold: Bool) {
        let font = UIFont.preferredFont(forTextStyle: uiStyle(style))
        return (font.pointSize / MainTextSize.standardScale, font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    private static func uiStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}
