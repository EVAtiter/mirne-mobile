import SwiftUI

extension View {
    /// スクロールする枠（ScrollView・Form）の高さを、中身の高さに合わせる。中身が `maxHeight` より高ければ、その高さで送る。
    /// スクロールする枠は自分の高さを持たず、置いた所の高さいっぱいに広がる（シートの高さを中身に合わせられず、上下に空きが残った）
    func scrollFitsContentHeight(maxHeight: CGFloat = .infinity) -> some View {
        modifier(ScrollContentHeight(maxHeight: maxHeight))
    }
}

/// スクロールの中身の高さを測って、枠の高さに当てる（測れるまでは高さを決めない）
private struct ScrollContentHeight: ViewModifier {
    let maxHeight: CGFloat
    @State private var contentHeight: CGFloat?

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, new in
                if new > 0 { contentHeight = new }
            }
            .frame(height: contentHeight.map { min($0, maxHeight) })
    }
}
