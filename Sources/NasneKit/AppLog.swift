import Foundation

// ログの出どころ（os.Logger の subsystem）と、ログ・計測に出す時間の形。
//
// subsystem はアプリの Bundle ID。計測コマンドと試験から出すログも同じ subsystem にして、`log stream` の 1 つの条件で読む。
// 前は NasneKit・DTCPKit にそれぞれ定数があり、ほかの 20 余りのファイルは文字列を直に書いていた（2026-11-21 にここへ集めた）

/// ログの決まり
enum AppLog {
    /// os.Logger の subsystem（Bundle ID）
    static let subsystem = "com.slack-kingdom.mirne-mobile"
}

extension Duration {
    /// ログ・計測に出すミリ秒（端数は切り捨て）
    var wholeMilliseconds: Int {
        Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}

extension ContinuousClock.Instant {
    /// この時刻から今までのミリ秒（ログ・計測用。端数は切り捨て）
    var elapsedMilliseconds: Int {
        (ContinuousClock.now - self).wholeMilliseconds
    }
}
