import SwiftUI

/// 主ウィンドウの大きさ
enum MainWindowLayout {
    /// 初めて開くときの大きさ
    static let defaultSize = CGSize(width: 960, height: 640)
    /// これより小さくできない大きさ
    static let minimumSize = CGSize(width: 640, height: 420)
    // これより狭いと各画面の帯の「ライブ」「設定」を文字なしの絵だけにする幅（`accessoryTitlesWidth`）は OS ごと
}
