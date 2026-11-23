import SwiftUI

/// 主画面の切り替えの置き場を決めて中身に渡す（macOS 版：いつもツールバーの中央）
struct MainSectionPlacementReader<Content: View>: View {
    @ViewBuilder let content: (MainSectionPlacement) -> Content

    var body: some View {
        content(.toolbar)
    }
}

extension View {
    /// ナビゲーションの帯を隠す（macOS 版：下のタブバーにならないので使わない）
    func hidesNavigationBar(_ hidden: Bool) -> some View {
        self
    }
}
