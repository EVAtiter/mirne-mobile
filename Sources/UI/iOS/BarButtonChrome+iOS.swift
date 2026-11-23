import SwiftUI

// 各画面の帯のボタンの見た目（iOS 版）：「ライブ」「設定」「現在」「新規予約」と番組表の日付・録画の絞り込みを、iPhone のナビゲーションの帯の
// ボタンと同じ形（ガラスの丸い板に黒い絵・文字）にする（2026-11-23。Mac の枠付きのボタンとも近い見た目になる）。
// ガラスは iOS 26 から。それより前の版は枠付き（灰色の地）にする

extension View {
    /// 帯の 1 つのボタン（「現在」など）
    @ViewBuilder
    func barButtonChrome() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass).foregroundStyle(.primary)
        } else {
            buttonStyle(.bordered).tint(.primary)
        }
    }

    /// 帯のボタンのまとまり（「ライブ」「設定」）：1 つの丸い板に並べる（ナビゲーションの帯のボタンのまとまりと同じ形）
    @ViewBuilder
    func barButtonGroupChrome() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(BarGroupItemButtonStyle())
                .padding(.horizontal, BarButtonChromeLayout.groupHorizontalPadding)
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            buttonStyle(BarGroupItemButtonStyle())
                .padding(.horizontal, BarButtonChromeLayout.groupHorizontalPadding)
                .background(.fill.tertiary, in: Capsule())
        }
    }

    /// 帯の切り替えのボタン（録画の「番組名でまとめる」）：入っている間は色の付いた板にする
    @ViewBuilder
    func barToggleChrome(isOn: Bool) -> some View {
        if #available(iOS 26.0, *) {
            if isOn { buttonStyle(.glassProminent) } else { buttonStyle(.glass).foregroundStyle(.primary) }
        } else {
            if isOn { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered).tint(.primary) }
        }
    }

    /// 帯のメニューの選択（番組表の日付・録画の絞り込みと並べ替え）
    @ViewBuilder
    func barMenuChrome() -> some View {
        if #available(iOS 26.0, *) {
            tint(.primary)
                .padding(.horizontal, BarButtonChromeLayout.menuHorizontalPadding)
                .padding(.vertical, BarButtonChromeLayout.menuVerticalPadding)
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            tint(.primary)
                .padding(.horizontal, BarButtonChromeLayout.menuHorizontalPadding)
                .padding(.vertical, BarButtonChromeLayout.menuVerticalPadding)
                .background(.fill.tertiary, in: Capsule())
        }
    }
}

/// まとまりの中の 1 つのボタン（地は描かず、押せる範囲を広げる。押している間と押せないときは薄くする）
private struct BarGroupItemButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BarGroupItem(configuration: configuration)
    }

    private struct BarGroupItem: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(.primary)
                .frame(minWidth: BarButtonChromeLayout.groupItemMinWidth, minHeight: BarButtonChromeLayout.groupItemMinHeight)
                .contentShape(Rectangle())
                .opacity(!isEnabled ? BarButtonChromeLayout.disabledOpacity
                         : configuration.isPressed ? BarButtonChromeLayout.pressedOpacity : 1)
        }
    }
}

/// 帯のボタンの見た目の寸法（体感の値。画面で見て決める）
private enum BarButtonChromeLayout {
    /// まとまりの板の左右の余白と、中の 1 つのボタンの押せる範囲
    static let groupHorizontalPadding: CGFloat = 6
    static let groupItemMinWidth: CGFloat = 40
    static let groupItemMinHeight: CGFloat = 36
    /// メニューの選択の板の余白
    static let menuHorizontalPadding: CGFloat = 6
    static let menuVerticalPadding: CGFloat = 2
    /// 押している間と、押せないときの濃さ
    static let pressedOpacity: Double = 0.4
    static let disabledOpacity: Double = 0.3
}
