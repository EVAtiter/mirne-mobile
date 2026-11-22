import CoreGraphics

/// 一覧に重ねるカードの OS ごとの寸法（macOS 版）
enum SelectionCardPlatform {
    /// カードの幅。窓の幅に余裕があるので iPad より広くし、ボタンを 1 段に・題をなるべく少ない行に収める（体感の値）
    static let width: CGFloat = 460
}
