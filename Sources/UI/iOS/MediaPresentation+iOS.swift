import SwiftUI

extension View {
    /// メディアの画面から開く画面（写真。動画・音楽は再生の窓を共有する）。iPhone・iPad：全画面で開き、左上の × で閉じる
    func mediaPresentation<Value: Codable & Hashable & Identifiable, Content: View>(
        _ item: Binding<Value?>, windowID: String,
        @ViewBuilder content: @escaping (Value) -> Content) -> some View {
        fullScreenCover(item: item) { value in
            content(value)
                .ignoresSafeArea()
                .overlay(alignment: .topLeading) {
                    SheetTopCloseBar { item.wrappedValue = nil }
                }
        }
    }
}
