import SwiftUI

extension MainWindowLayout {
    /// これより狭いと、ツールバーの「ライブ」「設定」と切り替えを文字なしのシンボルだけにする（macOS 版。体感の値。画面を見て決める）
    static let compactToolbarWidth: CGFloat = 860
}

extension View {
    /// シートの中身の幅（macOS 版：渡した幅に決める）
    func sheetContentWidth(_ width: CGFloat) -> some View {
        frame(width: width)
    }

    /// シートの高さを中身に合わせる（macOS 版：シートは元から中身の高さなので何もしない）
    func sheetFitsContentHeight() -> some View {
        self
    }

    /// Form の高さを中身の高さにする（macOS 版：何もしない）
    func formFitsContentHeight() -> some View {
        self
    }
}

/// シートの「閉じる」の置き場
enum SheetCloseLayout {
    /// 「閉じる」を左上の × にするか（macOS 版：下の帯の「閉じる」）。「キャンセル」と「予約する」のように対になるシートは、どちらの OS も下の帯のまま
    static let closesAtTop = false
    /// × の大きさ・余白（体感の値。画面で見て決める）
    static let buttonSize: CGFloat = 28
    static let horizontalPadding: CGFloat = 16
    static let topPadding: CGFloat = 16
}

/// 何かを作る・変えるシートの下の帯のボタンの並び
enum SheetActionLayout {
    /// 「キャンセル」を左端、確定のボタンを右端に分けるか（macOS 版：右に「キャンセル」「確定」を並べる〔作法どおり〕）
    static let splitsCancelAndConfirm = false
}
