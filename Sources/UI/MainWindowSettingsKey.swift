import Foundation

// 主ウインドウの設定の鍵（UserDefaults。macOS の主ウインドウと iPad の主画面で共通）

/// 主ウィンドウの設定の鍵（UserDefaults）
enum MainWindowSettingsKey {
    /// 最後に選んだ切り替えの項目（`MainSection` の rawValue）。鍵の名前はサイドバーだったときのまま
    static let section = "mainSidebarSection"
    /// 文字の大きさ（`MainTextSize` の rawValue。未設定なら標準）
    static let textSize = "mainTextSize"
}
