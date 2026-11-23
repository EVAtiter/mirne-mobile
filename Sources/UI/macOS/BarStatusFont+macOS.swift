import AppKit
import SwiftUI

/// 各画面の上の帯の OS ごとの決まり（macOS 版）
enum ScreenActionBarPlatform {
    /// 帯の段の高さを、いちばん高い部品の見本で揃えるか（macOS 版：揃えない。部品の高さがほぼ同じで、
    /// ボタンの形の切り替えのある帯だけ 1pt 高いが見て分かる差ではない。2026-11-23）
    static let alignsRowHeight = false
}

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

extension View {
    /// 窓を操作するボタンの場所を避ける（macOS 版：窓のボタンはタイトルバーにあり、帯には重ならないので何もしない）
    func avoidsWindowControls() -> some View {
        self
    }
}
