import SwiftUI

/// 各画面の上の帯の OS ごとの決まり（iOS 版）
enum ScreenActionBarPlatform {
    /// 帯の段の高さを、いちばん高い部品の見本で揃えるか（iOS 版：揃える。iPad の 4 つの画面で「更新」の位置がずれた。2026-11-23）
    static let alignsRowHeight = true
}

extension View {
    /// 帯の状態の文字の大きさ（iPad 版）：iPad のボタンは配られた文字（主画面の倍率を掛けた本文）で描かれるので、同じく配られた文字のまま
    func barStatusFont(_ controlSize: ControlSize) -> some View {
        self
    }
}
