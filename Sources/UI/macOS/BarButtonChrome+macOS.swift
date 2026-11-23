import SwiftUI

// 各画面の帯のボタンの見た目（macOS 版：変えない。macOS の帯のボタンは元から枠付き）

extension View {
    /// 帯の 1 つのボタン（「更新」「現在」）
    func barButtonChrome() -> some View { self }
    /// 帯のボタンのまとまり（「ライブ」「設定」）
    func barButtonGroupChrome() -> some View { self }
    /// 帯のメニューの選択（番組表の日付）
    func barMenuChrome() -> some View { self }
}
