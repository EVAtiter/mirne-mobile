import AppKit
import SwiftUI

/// 主画面の形を決めて中身に渡す（macOS 版：いつも上端にタイトル・各画面は広い幅の形）
struct MainLayoutReader<Content: View>: View {
    @ViewBuilder let content: (MainLayout) -> Content

    var body: some View {
        content(MainLayout(showsTitleBar: true, showsBarTitle: false, usesCompactLayout: false,
                           showsAccessoriesInTitleBar: false))
    }
}

/// 画面の切り替えの器（macOS 版）：選んでいる画面を出し、1 行の切り替え（`MainTabBar` の `inline`）を各画面の帯の中央に置かせ
/// （`mainBarSwitcher` で配る）、窓の下端の中央に知らせの板を重ねて浮かべる（2026-11-24 の試作。縦を増やさずに切り替えを上へ戻す。
/// 先に窓のタイトルの帯の中央に置いてみたが、もう一段下〔各画面の帯〕がよいとのことで移した）。
/// 1.3.0〜1.5.0 は窓の下端に 2 段の切り替えを浮かべ、そのすぐ上に知らせの板を出していた。
/// 知らせは重ねるだけで、中身・スクロールバーの位置にも、送れる範囲にも影響させない（2026-11-23）
struct MainTabContainer<Notice: View, Content: View>: View {
    @Binding var selection: MainSection
    @ViewBuilder let notice: () -> Notice
    @ViewBuilder let content: (MainSection) -> Content

    var body: some View {
        content(selection)
            .overlay(alignment: .bottom) {
                notice().padding(.bottom, MainNoticeLayout.bottomMargin)
            }
            .environment(\.mainBarSwitcher, $selection)
            // 窓のタイトルの帯の高さを、どの画面も録画の画面（右に検索の欄）と同じにする（2026-11-24）
            .toolbar { MainToolbarHeightKeeper() }
    }
}

extension MainNoticeLayout {
    /// 板と窓の下端の間（macOS 版）：番組表の横スクロールバーに重ならないよう、常に出すスクロールバーの太さぶん上げる
    /// （2026-11-24。下端から 10pt では番組表の横スクロールバーに板の下側が重なった）
    @MainActor static var bottomMargin: CGFloat {
        NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) + gapAboveScroller
    }
}

/// 窓のタイトルの帯をツールバーの高さに保つ見えない項目（macOS 版）。
/// 項目が 1 つも無い画面ではタイトルの帯が低くなり、検索の欄を出す録画の画面と切り替えたときに、下の帯と中身が上下に動いて見えた
private struct MainToolbarHeightKeeper: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            // macOS 26 はツールバーの項目にガラスの板を付けるので、見えない項目には付けない
            item.sharedBackgroundVisibility(.hidden)
        } else {
            item
        }
    }

    private var item: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// ナビゲーションの帯を隠す（macOS 版：上端はいつも窓のタイトルなので使わない）
    func hidesNavigationBar(_ hidden: Bool) -> some View {
        self
    }
}
