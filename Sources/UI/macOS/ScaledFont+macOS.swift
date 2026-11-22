import AppKit
import SwiftUI

extension ScaledFont {
    /// 文字の形の大きさ（macOS の既定。body 13・callout 12・caption 10 など）と、既定で太字か
    static func base(_ style: Font.TextStyle) -> (size: CGFloat, bold: Bool) {
        let font = NSFont.preferredFont(forTextStyle: nsStyle(style))
        return (font.pointSize, font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    private static func nsStyle(_ style: Font.TextStyle) -> NSFont.TextStyle {
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
