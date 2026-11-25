import SwiftUI

extension View {
    /// 設定の Form の右の余白（iPad 版）。スクロールバーは中身に重ねて出るので、余白は足さない
    func settingsScrollerMargins() -> some View {
        self
    }
}

/// 設定の節の、足す・外す（取り込む・削除）の置き方（iOS 版：設定アプリと同じ形。「nasne」の節は一覧のすぐ下に「nasne を追加…」の行、
/// 節の最後に「登録を外す…」の赤い行。資格情報の節は今までの段のまま。2026-11-25 に決めた）
enum SettingsActionLayout {
    /// 節の行として置くか（偽なら右寄せのボタンの段）
    static let usesRows = true
}
