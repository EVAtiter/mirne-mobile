import SwiftUI

/// 画面の検索の欄（録画・番組表）の置き場（iOS 版：画面の帯の中）
enum MainSearchPlacement {
    static let inScreenBar = true
}

extension View {
    /// 検索の欄を窓のタイトルの帯に置く（iOS 版：画面の帯の中に置くので何もしない）
    func mainToolbarSearch(text: Binding<String>, focused: FocusState<Bool>.Binding, prompt: String) -> some View {
        self
    }
}
