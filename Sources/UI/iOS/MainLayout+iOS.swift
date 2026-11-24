import SwiftUI

/// 主画面の形を決めて中身に渡す（iOS 版）。機種ではなく大きさの区分で分ける。
/// - 上の帯（画面の名前）：縦の大きさの区分が compact（iPhone の横向き。Max も含む）なら隠し、名前は各画面の帯の中央に出す。
///   縦も横も regular（iPad の広い幅）なら、名前は要らないので隠す（2026-11-23）。残るのは横が compact で縦が regular（iPhone の縦向き・iPad の狭い分割）
/// - 「ライブ」「設定」：上の帯を出すときは上の帯の右端（各画面の帯では幅が足りない。2026-11-23）、それ以外は各画面の帯の右端
/// - 狭い幅の形：横の大きさの区分が compact（iPhone の縦向き・iPad の狭い分割）か、iPhone の横向きのとき
struct MainLayoutReader<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ViewBuilder let content: (MainLayout) -> Content

    var body: some View {
        let landscapePhone = verticalSizeClass == .compact
        let compactWidth = sizeClass == .compact
        let showsTitleBar = !landscapePhone && compactWidth
        content(MainLayout(showsTitleBar: showsTitleBar, showsBarTitle: landscapePhone,
                           usesCompactLayout: landscapePhone || compactWidth,
                           showsAccessoriesInTitleBar: showsTitleBar))
    }
}

/// 画面の切り替えの器（iOS 版）：OS のタブバー。知らせの板は各タブの中身に重ね、タブバーのすぐ上に浮かべる。
/// OS のタブバーは横の大きさの区分が regular（iPad の広い幅）だと画面の上に出るので、器にだけ compact を渡して下に出させ、
/// 中身には元の区分を渡し直す（iPad の広い幅でも下のタブにする。2026-11-23）
struct MainTabContainer<Notice: View, Content: View>: View {
    @Binding var selection: MainSection
    @ViewBuilder let notice: () -> Notice
    @ViewBuilder let content: (MainSection) -> Content
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// nasne に届くか（オフラインなら「情報」のタブにバッジ）
    @Environment(\.nasneLink) private var link

    var body: some View {
        TabView(selection: $selection) {
            ForEach(MainSection.allCases) { section in
                Tab(section.title, systemImage: section.symbol, value: section) {
                    content(section)
                        // 中身が安全領域の外まで広がっても（番組表）、知らせの板はタブバーの上（安全領域の下端）にそろえる
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottom) {
                            notice().padding(.bottom, MainNoticeLayout.gapAboveTabBar)
                        }
                        .environment(\.horizontalSizeClass, sizeClass)
                }
                .badge(section.showsOfflineBadge(link) ? Text(OfflineBadge.text) : nil)
            }
        }
        .environment(\.horizontalSizeClass, .compact)
    }
}

extension View {
    /// ナビゲーションの帯を隠す（iOS 版）
    func hidesNavigationBar(_ hidden: Bool) -> some View {
        toolbar(hidden ? .hidden : .automatic, for: .navigationBar)
    }
}
