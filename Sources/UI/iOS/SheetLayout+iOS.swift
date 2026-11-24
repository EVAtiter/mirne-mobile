import SwiftUI

extension View {
    /// シートの中身の幅（iPad 版：シートの幅は OS が決めるので、その幅いっぱいに広げる）
    func sheetContentWidth(_ width: CGFloat) -> some View {
        frame(maxWidth: .infinity)
    }

    /// 大きさを変えられるシートの最小と最初の大きさ（iOS 版：シートの大きさは OS が決めるので何もしない。
    /// 前は Mac の最小の幅〔480pt〕を iOS にも当てていて、iPhone では設定のシートの中身が画面の幅からはみ出した。2026-11-23）
    func sheetResizableSize(minimum: CGSize, ideal: CGSize) -> some View {
        self
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

/// 何かを作る・変えるシート（予約のシート）のボタンの置き場
enum SheetActionLayout {
    /// 上のナビゲーションの帯に置くか（iOS 版：iOS の標準の形。左に「キャンセル」、右に確定のボタン、削除は中身のいちばん下の赤い行。
    /// 2026-11-24。前は下の帯に置いていて、iPhone の縦向きではボタンが画面の下端に寄りすぎ、横向きでは中身がスクロールできず押せなかった）
    static let usesNavigationBar = true
}

extension View {
    /// ナビゲーションの帯の題を小さく 1 行で出す（iOS 版）
    func inlineNavigationTitle() -> some View {
        navigationBarTitleDisplayMode(.inline)
    }

    /// 予約のシートのフォームの高さ（iOS 版：決めない。中身はシートの中でスクロールする。
    /// 横向きの iPhone でシートが中身より低くなっても下まで届く）
    func scheduleSheetFormHeight() -> some View {
        self
    }

    /// 予約のシートの大きさ（iOS 版）：狭い幅（iPhone）は中くらい・大きいの 2 段、広い幅（iPad）は OS の標準のフォームのシート。
    /// 中身の高さに合わせる形（`sheetFitsContentHeight`）は、上のナビゲーションの帯を持つシートでは高さを測れず、
    /// iPad でシートがごく低くなって中身が見えなかった（2026-11-24）
    func scheduleSheetSizing() -> some View {
        modifier(ScheduleSheetSizing())
    }
}

/// 予約のシートの大きさ（狭い幅かは主画面の印で見る。`SheetFitsContentHeight` と同じ）
private struct ScheduleSheetSizing: ViewModifier {
    @Environment(\.usesCompactLayout) private var compact

    func body(content: Content) -> some View {
        if compact {
            content.presentationDetents([.medium, .large])
        } else {
            content.presentationSizing(.form)
        }
    }
}

extension View {
    /// シートの外を押したら閉じる（iOS 版：OS のシートが元から外を押すと閉じるので何もしない）
    func closesOnOutsideClick(_ close: @escaping () -> Void) -> some View {
        self
    }
}
