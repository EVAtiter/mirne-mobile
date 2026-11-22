import Foundation

/// 再生の位置の書き方（視聴の画面の時刻と、録画一覧の「続きから再生」の説明で同じものを使う）
enum PlaybackTimeFormat {
    /// 秒を「1:02:03」「12:34」に（分からなければ「--:--」）
    static func text(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "--:--" }
        let total = Int(seconds)
        let hours = total / 3600, minutes = total % 3600 / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}
