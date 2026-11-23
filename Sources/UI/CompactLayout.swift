import SwiftUI

// 狭い幅（iPhone の縦向きなど。主画面の切り替えが下のタブバーのとき）の形。
// 主画面が環境で配り、各画面はこれを見て形を変える（帯のボタンを絵だけにする・行を短くする・カードをシートにする）。
// 文字を絵に替えても、ボタンとメニューの項目は減らさない（2026-11-23）

extension EnvironmentValues {
    /// 狭い幅の形で出すか（主画面が下のタブバーのときに立てる。macOS と iPad の広い幅では立たない）
    @Entry var usesCompactLayout = false
}

/// カードの「削除…」の絵（録画と予約のカードで同じ。どの OS・幅でも）
enum CardDeleteSymbol {
    static let name = "trash"
}

/// 狭い幅の一覧の上端の余白（一覧の既定の上の余白は、上の帯の下で空きすぎて見えた。2026-11-23。体感の値）
enum CompactListLayout {
    static let topMargin: CGFloat = 8
}

extension View {
    /// 狭い幅では、一覧の上端の余白を詰める（録画と予約の一覧）
    func compactListTopMargin() -> some View {
        modifier(CompactListTopMargin())
    }
}

private struct CompactListTopMargin: ViewModifier {
    @Environment(\.usesCompactLayout) private var compact

    func body(content: Content) -> some View {
        if compact {
            content.contentMargins(.top, CompactListLayout.topMargin, for: .scrollContent)
        } else {
            content
        }
    }
}

/// 狭い幅の行に出す短い日時の書式
enum CompactDateText {
    private static let format = Date.FormatStyle(locale: Locale(identifier: "ja_JP"), calendar: Calendar(identifier: .gregorian))
        .month(.defaultDigits).day(.defaultDigits).weekday(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
    private static let timeFormat = Date.FormatStyle(locale: Locale(identifier: "ja_JP"), calendar: Calendar(identifier: .gregorian))
        .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)

    /// 「11/22(土) 23:30」
    static func dateTime(_ date: Date) -> String {
        date.formatted(format)
    }

    /// 「23:30」
    static func time(_ date: Date) -> String {
        date.formatted(timeFormat)
    }
}
