import AppKit
import SwiftUI

extension SettingsSheetLayout {
    /// 右に足す余白：「スクロールバーを常に表示」のとき、スクロールバーが Form（grouped）の右の余白（左と同じ 20pt）の中に
    /// 重なって描かれ、中身の端からスクロールバーまで約 2pt しか空かなかった（2026-11-21・AX で測った）。そのときはスクロールバーの幅を足す。
    /// `contentMargins` は Form がもともと持つ余白に足し算で効く（AX で測った。`for: .scrollContent` は効かなかった）ので、足す分だけを返す
    /// `NSScroller` は main actor の上でしか読めないので、これも main actor に置く（画面の中からしか読まない）
    @MainActor static func extraTrailingMargin(scrollerStyle: NSScroller.Style) -> CGFloat {
        scrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }
}

/// 設定の Form の右の余白（macOS 版）。スクロールバーを常に表示するときは、スクロールバーの幅を足す
private struct SettingsScrollerMargins: ViewModifier {
    /// スクロールバーの出し方（「常に表示」のときは右の余白にスクロールバーの幅を足す）
    @State private var scrollerStyle = NSScroller.preferredScrollerStyle

    func body(content: Content) -> some View {
        content
            .contentMargins(.trailing, SettingsSheetLayout.extraTrailingMargin(scrollerStyle: scrollerStyle))
            .contentMargins(.trailing, 0, for: .scrollIndicators)
            .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
                scrollerStyle = NSScroller.preferredScrollerStyle
            }
    }
}

extension View {
    /// 設定の Form の右の余白をスクロールバーに合わせる
    func settingsScrollerMargins() -> some View {
        modifier(SettingsScrollerMargins())
    }
}
