import SwiftUI

extension MainWindowLayout {
    /// これより狭いと、ツールバーの「設定」と切り替えを文字なしのシンボルだけにする（iPad 版。縦向きでも文字を出し、
    /// 画面の分割で半分より狭くしたときだけシンボルにする。体感の値。画面を見て決める）
    static let compactToolbarWidth: CGFloat = 600
}

extension View {
    /// シートの中身の幅（iPad 版：シートの幅は OS が決めるので、その幅いっぱいに広げる）
    func sheetContentWidth(_ width: CGFloat) -> some View {
        frame(maxWidth: .infinity)
    }

    /// シートの高さを中身に合わせる（iPad 版：既定のフォームのシートは中身が少なくても縦に大きく、下に広い余白が残った。2026-11-22）。
    /// 中の Form には `formFitsContentHeight()` を付ける（Form は自分の高さを持たず、付けないとシートが潰れた）
    func sheetFitsContentHeight() -> some View {
        presentationSizing(.form.fitted(horizontal: false, vertical: true))
    }

    /// Form の高さを中身の高さにする（iPad 版。スクロールの中身の高さを測って当てる）
    func formFitsContentHeight() -> some View {
        scrollFitsContentHeight()
    }
}

/// シートの「閉じる」の置き場
enum SheetCloseLayout {
    /// 「閉じる」を左上の × にするか（iPad 版：左上の ×。再生の画面と揃える）。「キャンセル」と「予約する」のように対になるシートは、どちらの OS も下の帯のまま
    static let closesAtTop = true
    /// × の大きさ・余白（体感の値。画面で見て決める）
    static let buttonSize: CGFloat = 28
    static let horizontalPadding: CGFloat = 16
    static let topPadding: CGFloat = 16
}

/// 何かを作る・変えるシートの下の帯のボタンの並び
enum SheetActionLayout {
    /// 「キャンセル」を左端、確定のボタンを右端に分けるか（iPad 版：左に「キャンセル」、右に確定のボタン〔太字〕。上の帯に置いたときの並びを下の帯で使う）
    static let splitsCancelAndConfirm = true
}
