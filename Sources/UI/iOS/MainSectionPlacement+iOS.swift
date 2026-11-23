import SwiftUI

/// 主画面の切り替えの置き場を決めて中身に渡す（iOS 版）。
/// 横の大きさの区分が compact（iPhone の縦向きと Max 以外の横向き・iPad の狭い分割）なら下のタブバー、
/// それ以外はナビゲーションの帯の中央の切り替え（2026-11-23）。機種ではなく幅で分けるので、iPad の狭い分割でも下のタブバーになる。
/// 下のタブバーで縦の大きさの区分も compact（iPhone の横向き）なら、ナビゲーションの帯を隠して各画面の帯 1 段にする
struct MainSectionPlacementReader<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ViewBuilder let content: (MainSectionPlacement) -> Content

    var body: some View {
        content(placement)
    }

    private var placement: MainSectionPlacement {
        guard sizeClass == .compact else { return .toolbar }
        return verticalSizeClass == .compact ? .tabBarWithoutNavigationBar : .tabBar
    }
}

extension View {
    /// ナビゲーションの帯を隠す（iOS 版）
    func hidesNavigationBar(_ hidden: Bool) -> some View {
        toolbar(hidden ? .hidden : .automatic, for: .navigationBar)
    }
}
