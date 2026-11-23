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
        modifier(SheetFitsContentHeight())
    }

    /// Form の高さを中身の高さにする（iPad 版。スクロールの中身の高さを測って当てる）
    func formFitsContentHeight() -> some View {
        scrollFitsContentHeight()
    }
}

/// シートの高さを中身に合わせる。狭い幅の画面（iPhone の縦向きなど）から出したシートは、中くらい・大きいの 2 段にし、中身を上に寄せる
/// （2026-11-23。フォームの大きさは iPhone では画面いっぱいになり、中身が真ん中に浮いて上下に大きな空きが出た）。
/// 狭い幅かは、シートの中の大きさの区分ではなく主画面の印で見る（iPad のフォームのシートの中も横は compact になるため）
private struct SheetFitsContentHeight: ViewModifier {
    @Environment(\.usesCompactLayout) private var compact

    func body(content: Content) -> some View {
        if compact {
            content
                // シートの角は丸みが大きいので、中身を少し下げる（2026-11-23。録画・予約のカードのシートと同じ考え）
                .padding(.top, CompactSheetLayout.topInset)
                .frame(maxHeight: .infinity, alignment: .top)
                .presentationDetents([.medium, .large])
        } else {
            content.presentationSizing(.form.fitted(horizontal: false, vertical: true))
        }
    }
}

/// 狭い幅の画面から出したシートの寸法（体感の値。iPhone の実機で見て決める）
enum CompactSheetLayout {
    /// 中身の上に足す間
    static let topInset: CGFloat = 16
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
