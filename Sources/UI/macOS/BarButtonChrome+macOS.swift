import SwiftUI

// 各画面の帯のボタンの見た目（macOS 版：変えない。macOS の帯のボタンは元から枠付き）

extension View {
    /// 帯の 1 つのボタン（「現在」など）
    func barButtonChrome() -> some View { self }
    /// 帯のボタンのまとまり（「ライブ」「設定」）
    func barButtonGroupChrome() -> some View { self }
    /// 帯の切り替えのボタン（録画の「番組名でまとめる」）
    func barToggleChrome(isOn: Bool) -> some View { self }
    /// 帯のメニューの選択（番組表の日付・録画の絞り込みと並べ替え）
    func barMenuChrome() -> some View { self }
}
