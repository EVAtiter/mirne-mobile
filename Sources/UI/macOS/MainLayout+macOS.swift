import SwiftUI

/// 主画面の形を決めて中身に渡す（macOS 版：いつも上端にタイトル・各画面は広い幅の形）
struct MainLayoutReader<Content: View>: View {
    @ViewBuilder let content: (MainLayout) -> Content

    var body: some View {
        content(MainLayout(showsTitleBar: true, showsBarTitle: false, usesCompactLayout: false,
                           showsAccessoriesInTitleBar: false))
    }
}

/// 画面の切り替えの器（macOS 版）：選んでいる画面を出し、窓の下端の中央に自前の切り替え（`MainTabBar`）と、そのすぐ上に知らせの板を重ねて浮かべる。
/// macOS の SwiftUI には下のタブバーの部品が無い（TabView は上に出る）。
/// 切り替えと知らせは重ねるだけで、中身・スクロールバーの位置にも、送れる範囲にも影響させない（2026-11-23）。
/// 前は切り替えの高さを余白（`safeAreaInset`）にしていて、スクロールバーがその余白の上端（窓の下端から約 60pt 上）に浮いて見えた。
/// いちばん下まで送っても、最後の行の真ん中は切り替えに隠れたまま
struct MainTabContainer<Notice: View, Content: View>: View {
    @Binding var selection: MainSection
    @ViewBuilder let notice: () -> Notice
    @ViewBuilder let content: (MainSection) -> Content

    var body: some View {
        content(selection)
            .overlay(alignment: .bottom) {
                // 知らせの板は切り替えのすぐ上（切り替えの高さを決め打ちしない）
                VStack(spacing: MainNoticeLayout.gapAboveTabBar) {
                    notice()
                    MainTabBar(selection: $selection)
                }
            }
    }
}

extension View {
    /// ナビゲーションの帯を隠す（macOS 版：上端はいつも窓のタイトルなので使わない）
    func hidesNavigationBar(_ hidden: Bool) -> some View {
        self
    }
}
