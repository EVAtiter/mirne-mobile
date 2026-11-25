import SwiftUI

extension View {
    /// アドレスの入力欄のキーボード（macOS 版：画面のキーボードは無い。自動修正だけ止める）
    func addressEntryKeyboard() -> some View {
        autocorrectionDisabled()
    }
}
