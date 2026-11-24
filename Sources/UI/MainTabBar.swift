import SwiftUI

/// Mac の画面の切り替え（番組表・予約・録画・メディア・情報）。項目の並び・絵・名前は iOS の OS のタブバーと同じ `MainSection` から引く。
/// 2026-11-24 の試作から、1 行の形（`inline`。絵と文字を横に並べ、選んだ項目は丸い地）を各画面の帯の中央に置く。
/// 2 段の形（丸い板の上に絵〔上〕と文字〔下〕。iPhone のタブバーに寄せた形）は 1.3.0〜1.5.0 で窓の下端に浮かべていたもので、今は使っていない
struct MainTabBar: View {
    @Binding var selection: MainSection
    /// nasne に届くか（オフラインなら「情報」の絵に赤いバッジ）
    @Environment(\.nasneLink) private var link
    /// 1 行の形（絵と文字を横に並べる。Mac の各画面の帯の中央に置く。2026-11-24 の試作）。板の代わりに薄い丸い地を敷く
    var inline = false
    /// 1 行の形で文字も出すか（帯に入らなければ絵だけにする）
    var showsTitles = true

    var body: some View {
        if inline {
            HStack(spacing: MainTabBarLayout.itemSpacing) {
                ForEach(MainSection.allCases) { section in
                    inlineItem(section)
                }
            }
            .padding(MainTabBarLayout.inlineBarPadding)
            .background(Capsule().fill(Color.primary.opacity(MainTabBarLayout.inlineBarFillOpacity)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("画面")
        } else {
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
    }

    /// 1 行の形の項目（絵と文字を横に並べる。選んだ項目は丸い地と色）
    private func inlineItem(_ section: MainSection) -> some View {
        let selected = section == selection
        return Button {
            selection = section
        } label: {
            HStack(spacing: MainTabBarLayout.inlineIconTitleSpacing) {
                Image(systemName: section.symbol)
                    .overlay(alignment: .topTrailing) {
                        if section.showsOfflineBadge(link) { OfflineBadgeMark() }
                    }
                if showsTitles {
                    Text(section.title)
                        .fontWeight(selected ? .semibold : .regular)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, MainTabBarLayout.inlineItemHorizontalPadding)
            .padding(.vertical, MainTabBarLayout.inlineItemVerticalPadding)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background {
                if selected {
                    Capsule().fill(Color.primary.opacity(MainTabBarLayout.selectedFillOpacity))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(section.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

/// オフラインの印（Mac の切り替えの絵の右上に重ねる赤い丸と白い「!」。iOS の OS のタブのバッジに寄せた形）
private struct OfflineBadgeMark: View {
    var body: some View {
        Text(OfflineBadge.text)
            .font(.system(size: MainTabBarLayout.badgeFontSize, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: MainTabBarLayout.badgeDiameter, height: MainTabBarLayout.badgeDiameter)
            .background(Circle().fill(Color.red))
            .offset(x: MainTabBarLayout.badgeOffset.width, y: MainTabBarLayout.badgeOffset.height)
            .accessibilityLabel("nasne が見つかりません")
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
    /// 1 行の形の項目の絵と文字の間・余白（体感の値。画面で見て決める）
    static let inlineIconTitleSpacing: CGFloat = 4
    static let inlineItemHorizontalPadding: CGFloat = 10
    static let inlineItemVerticalPadding: CGFloat = 4
    /// 1 行の形の全体に敷く薄い丸い地の濃さと、地の縁と項目の間（2026-11-24 の試し。帯になじむようガラスより控えめにする。
    /// 選んだ項目の丸い地はこの上に重なる。体感の値。画面で見て決める）
    static let inlineBarFillOpacity: Double = 0.05
    static let inlineBarPadding: CGFloat = 2
    /// オフラインの印の大きさと、絵の右上からのずれ（体感の値。画面で見て決める）
    static let badgeDiameter: CGFloat = 12
    static let badgeFontSize: CGFloat = 9
    static let badgeOffset = CGSize(width: 6, height: -5)
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
