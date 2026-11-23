import SwiftUI

extension View {
    /// メディアの画面から開く画面（写真。動画・音楽は再生の窓を共有する）。Mac：値ごとの別の窓（`windowID` の `WindowGroup`）を開き、
    /// 開いたら値を空に戻す。同じ値なら開いている窓を前へ出す。中身は窓の側（`WindowGroup`）が作るので `content` は使わない
    func mediaPresentation<Value: Codable & Hashable & Identifiable, Content: View>(
        _ item: Binding<Value?>, windowID: String,
        @ViewBuilder content: @escaping (Value) -> Content) -> some View {
        modifier(MediaWindowOpener(item: item, windowID: windowID))
    }
}

private struct MediaWindowOpener<Value: Codable & Hashable>: ViewModifier {
    @Binding var item: Value?
    let windowID: String
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: item) {
            guard let value = item else { return }
            openWindow(id: windowID, value: value)
            item = nil
        }
    }
}
