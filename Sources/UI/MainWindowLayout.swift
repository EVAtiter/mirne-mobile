import SwiftUI

/// 主ウィンドウの大きさ
enum MainWindowLayout {
    /// 初めて開くときの大きさ
    static let defaultSize = CGSize(width: 960, height: 640)
    /// これより小さくできない大きさ
    static let minimumSize = CGSize(width: 640, height: 420)
}
