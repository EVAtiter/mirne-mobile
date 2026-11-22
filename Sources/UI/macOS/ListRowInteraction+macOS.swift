/// 一覧の行の操作（macOS 版）：行のダブルクリック・Return で再生（一覧の primaryAction）
enum ListRowInteraction {
    /// 一覧の primaryAction（ダブルクリック・Return）を使うか
    static let usesPrimaryAction = true
    /// 行ごとにダブルタップを受けて再生するか（primaryAction を使わない OS のため）
    static let playsOnRowDoubleTap = false
}
