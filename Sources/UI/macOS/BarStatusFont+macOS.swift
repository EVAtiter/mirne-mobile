import AppKit
import SwiftUI

extension BarStatusText {
    /// SwiftUI の部品の大きさを AppKit の大きさへ
    static func appKitSize(_ size: ControlSize) -> NSControl.ControlSize {
        switch size {
        case .mini: .mini
        case .small: .small
        // extraLarge は macOS 26 から（最低の版は 15）なので large として扱う
        case .large, .extraLarge: .large
        default: .regular
        }
    }
}

extension View {
    /// 帯の状態の文字の大きさ（macOS 版）：帯のボタンと同じ、部品の大きさの macOS の文字の大きさ
    func barStatusFont(_ controlSize: ControlSize) -> some View {
        font(.system(size: NSFont.systemFontSize(for: BarStatusText.appKitSize(controlSize))))
    }
}
