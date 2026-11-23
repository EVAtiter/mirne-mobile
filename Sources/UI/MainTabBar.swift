import SwiftUI

/// 画面の下端の中央に浮かべる切り替え（番組表・予約・録画・情報）。iPhone のタブバーに寄せた形：
/// 丸い板の上に、絵（上）と文字（下）の項目を並べ、選んだ項目は丸い地で示す（2026-11-23）。
/// macOS には下のタブバーの部品が無いので、これを使う。項目の並び・絵・名前は iOS の OS のタブバーと同じ `MainSection` から引く
struct MainTabBar: View {
    @Binding var selection: MainSection

    var body: some View {
        HStack(spacing: MainTabBarLayout.itemSpacing) {
            ForEach(MainSection.allCases) { section in
                item(section)
            }
        }
        .padding(MainTabBarLayout.barPadding)
        .mainFloatingBackground(Capsule())
        .padding(.bottom, MainTabBarLayout.bottomMargin)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("画面")
    }

    private func item(_ section: MainSection) -> some View {
        let selected = section == selection
        return Button {
            selection = section
        } label: {
            VStack(spacing: MainTabBarLayout.iconTitleSpacing) {
                Image(systemName: section.symbol)
                    .font(.system(size: MainTabBarLayout.iconSize))
                    .frame(height: MainTabBarLayout.iconHeight)
                Text(section.title)
                    .font(.system(size: MainTabBarLayout.titleSize, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .frame(minWidth: MainTabBarLayout.itemMinWidth)
            .padding(.horizontal, MainTabBarLayout.itemHorizontalPadding)
            .padding(.vertical, MainTabBarLayout.itemVerticalPadding)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background {
                if selected {
                    Capsule().fill(Color.primary.opacity(MainTabBarLayout.selectedFillOpacity))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(section.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 下の切り替えの寸法（体感の値。画面で見て決める）
enum MainTabBarLayout {
    /// 項目の間
    static let itemSpacing: CGFloat = 2
    /// 板の縁と項目の間
    static let barPadding: CGFloat = 4
    /// 板と窓の下端の間
    static let bottomMargin: CGFloat = 10
    /// 項目の絵の大きさと、絵の欄の高さ（絵の形によらず文字の位置を揃える）
    static let iconSize: CGFloat = 17
    static let iconHeight: CGFloat = 22
    static let iconTitleSpacing: CGFloat = 1
    /// 項目の文字の大きさ
    static let titleSize: CGFloat = 10
    /// 項目の最小の幅と余白（選んだ項目の丸い地の大きさになる）
    static let itemMinWidth: CGFloat = 56
    static let itemHorizontalPadding: CGFloat = 8
    static let itemVerticalPadding: CGFloat = 5
    /// 選んだ項目の丸い地の濃さ
    static let selectedFillOpacity: Double = 0.1
    /// ガラスの見た目が無い版（macOS 15・iOS 18）の板の影
    static let shadowOpacity: Double = 0.15
    static let shadowRadius: CGFloat = 6
}

extension View {
    /// 中身に重ねて浮かべる板（下の切り替え・知らせ）の地：OS のガラスの見た目（macOS 26・iOS 26 から）。無い版ではすりガラスと影
    @ViewBuilder
    func mainFloatingBackground<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(MainTabBarLayout.shadowOpacity), radius: MainTabBarLayout.shadowRadius)
        }
    }
}
