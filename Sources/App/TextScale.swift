import AppKit
import SwiftUI

// 主ウインドウの文字の大きさ。
// macOS の SwiftUI では Dynamic Type が効かないので、アプリで倍率を持ち、文字の指定（`scaledFont`）に掛ける。
// 視聴ウィンドウと字幕は対象にしない（ViewerView・CaptionOverlay は `.font` のまま）

/// 主ウインドウの文字の大きさ（設定の「表示」）
enum MainTextSize: String, CaseIterable, Identifiable {
    case standard
    case large

    var id: String { rawValue }

    /// 設定の既定
    static let initial = MainTextSize.standard

    /// 「標準」の倍率（macOS の既定の文字に対して。初めは 1 だったが、画面を見て 1.15 にした。2026-11-20）
    static let standardScale: CGFloat = 1.15
    /// 「大きい」の倍率（1.15 から始め、標準を 1.15 にしたのに合わせて 1.4 にした。2026-11-20）
    static let largeScale: CGFloat = 1.4

    var label: String {
        switch self {
        case .standard: "標準"
        case .large: "大きい"
        }
    }

    /// 文字に掛ける倍率
    var scale: CGFloat {
        switch self {
        case .standard: Self.standardScale
        case .large: Self.largeScale
        }
    }

    /// 部品（ボタン・トグル）の大きさ。「大きい」では一回り大きくする
    var controlSize: ControlSize {
        switch self {
        case .standard: .regular
        case .large: .large
        }
    }

    /// 保存した値（知らない値・未設定なら既定）
    static func saved(_ value: String?) -> MainTextSize {
        value.flatMap(MainTextSize.init(rawValue:)) ?? initial
    }
}

extension EnvironmentValues {
    /// 主ウインドウの文字の倍率（`scaledFont` が掛ける。配られていない所では標準）
    @Entry var textScale: CGFloat = MainTextSize.standardScale
}

/// 文字の形（大きさは macOS の文字の形の大きさ × 倍率）
enum ScaledFont {
    /// 文字の形の大きさ（macOS の既定。body 13・callout 12・caption 10 など）と、既定で太字か
    static func base(_ style: Font.TextStyle) -> (size: CGFloat, bold: Bool) {
        let font = NSFont.preferredFont(forTextStyle: nsStyle(style))
        return (font.pointSize, font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    static func font(_ style: Font.TextStyle, scale: CGFloat, weight: Font.Weight?, design: Font.Design?, monospacedDigit: Bool) -> Font {
        let base = base(style)
        let font = Font.system(size: base.size * scale, weight: weight ?? (base.bold ? .bold : .regular), design: design ?? .default)
        return monospacedDigit ? font.monospacedDigit() : font
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

private struct ScaledFontModifier: ViewModifier {
    @Environment(\.textScale) private var scale
    let style: Font.TextStyle
    let weight: Font.Weight?
    let design: Font.Design?
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        content.font(ScaledFont.font(style, scale: scale, weight: weight, design: design, monospacedDigit: monospacedDigit))
    }
}

extension View {
    /// 主ウインドウの文字の倍率を掛けた文字の形（`.font(.caption)` の代わり）
    func scaledFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design? = nil,
                    monospacedDigit: Bool = false) -> some View {
        modifier(ScaledFontModifier(style: style, weight: weight, design: design, monospacedDigit: monospacedDigit))
    }

    /// 主ウインドウの文字の大きさを配る（倍率・指定の無い文字の既定・部品の大きさ）
    func mainTextSize(_ size: MainTextSize) -> some View {
        environment(\.textScale, size.scale)
            .scaledFont(.body)
            .controlSize(size.controlSize)
    }
}
