/// 一覧の行の操作（iPad 版）：1 回のタップで行を選ぶ（情報のカードが出る）・ダブルタップで再生・長押しでメニュー。
/// 一覧の primaryAction は iPad では 1 回のタップで動き、行を選ぶ前に再生が始まってしまうので使わない（試作で確かめた）
enum ListRowInteraction {
    static let usesPrimaryAction = false
    static let playsOnRowDoubleTap = true
}
