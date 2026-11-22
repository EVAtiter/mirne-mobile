import Foundation

// 番組表の設定の鍵（UserDefaults。macOS と iPad の番組表で共通）

/// 番組表の設定の鍵（UserDefaults）
enum GuideSettingsKey {
    /// サブチャンネルも並べるか（既定は false）
    static let showsSubchannels = "guideShowsSubchannels"
}
