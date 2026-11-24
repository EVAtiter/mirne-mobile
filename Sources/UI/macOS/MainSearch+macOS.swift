import SwiftUI

/// 画面の検索の欄（録画・番組表）の置き場（macOS 版：窓のタイトルの帯の右。2026-11-24 の試作。画面の帯には置かない）
enum MainSearchPlacement {
    static let inScreenBar = false
}

extension View {
    /// 検索の欄を窓のタイトルの帯の右に置く（macOS 版。その画面を出している間だけ出る）
    func mainToolbarSearch(text: Binding<String>, focused: FocusState<Bool>.Binding, prompt: String) -> some View {
        searchable(text: text, placement: .toolbar, prompt: Text(prompt))
            .searchFocused(focused)
    }
}
