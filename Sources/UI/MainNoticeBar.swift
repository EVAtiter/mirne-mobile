import SwiftUI

/// 主ウインドウの上の知らせの帯（nasne を探している帯を、全部の画面の読み込み中・誤り・操作の結果の知らせに広げた）。
/// 知らせを 1 行ずつ並べる。誤りとうまくいった知らせは閉じられる。窓の下端に置くので、線は各行の上に引く（2026-11-21 に上から下端へ移した）。
/// iPad でも同じ形にできる部品だけ
struct MainNoticeBar: View {
    let notices: [MainNotice]
    let perform: (MainNoticeAction) -> Void
    let dismiss: (MainNotice) -> Void

    var body: some View {
        if !notices.isEmpty {
            VStack(spacing: 0) {
                ForEach(notices) { notice in
                    Divider()
                    MainNoticeRow(notice: notice, perform: perform, dismiss: dismiss)
                }
            }
            .background(.bar)
        }
    }
}

/// 知らせの 1 行：印・題・説明（1 行。マウスを載せると全部）・ボタン・閉じる
private struct MainNoticeRow: View {
    let notice: MainNotice
    let perform: (MainNoticeAction) -> Void
    let dismiss: (MainNotice) -> Void

    var body: some View {
        HStack(spacing: MainNoticeLayout.spacing) {
            switch notice.kind {
            case .progress:
                ProgressView().controlSize(.small)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text(notice.title)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail = notice.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if let action = notice.action {
                Button(action.title) { perform(action) }
            }
            if notice.isDismissible {
                Button { dismiss(notice) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("この知らせを閉じる")
            }
        }
        .help(notice.detail.map { notice.title + "\n" + $0 } ?? notice.title)
        .padding(.horizontal, MainNoticeLayout.horizontalPadding)
        .padding(.vertical, MainNoticeLayout.verticalPadding)
    }
}

/// 知らせの帯の寸法（左右は画面の上の帯と同じ）
enum MainNoticeLayout {
    static let spacing: CGFloat = 8
    static let horizontalPadding: CGFloat = ScreenActionBarLayout.horizontalPadding
    static let verticalPadding: CGFloat = 6
}
