import SwiftUI

/// 主ウインドウの知らせ（nasne を探している・各画面の読み込み中と誤り・操作の結果）。
/// 窓の幅いっぱいの帯ではなく、下の切り替え（タブバー）のすぐ上に浮かべる板で出す（2026-11-23。Mac・iPad・iPhone で同じ形）。
/// 中身の上に重ねるだけで、窓の中身の並び方は変えない。知らせを 1 行ずつ並べ、2 件以上なら行の間に線を引く。
/// 誤りとうまくいった知らせは閉じられる。置き場所は切り替えの器（`MainTabContainer`。OS ごと）が決める
struct MainNoticeBar: View {
    let notices: [MainNotice]
    let perform: (MainNoticeAction) -> Void
    let dismiss: (MainNotice) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !notices.isEmpty {
                // 中身に合わせた幅（入らなければ上限の幅で、説明の文字を省く）
                ViewThatFits(in: .horizontal) {
                    rows.fixedSize(horizontal: true, vertical: false)
                    rows
                }
                .frame(maxWidth: MainNoticeLayout.maximumWidth)
                .mainFloatingBackground(RoundedRectangle(cornerRadius: MainNoticeLayout.cornerRadius))
                .padding(.horizontal, MainNoticeLayout.outerMargin)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: MainNoticeLayout.transitionDuration), value: notices)
    }

    /// 行を縦に並べる（行は板の幅いっぱいに広げ、閉じるボタンを右端に揃える）
    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(notices.enumerated()), id: \.element.id) { index, notice in
                if index > 0 { Divider() }
                MainNoticeRow(notice: notice, perform: perform, dismiss: dismiss)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
                // ボタンの文字は折り返さない（狭い iPhone で 2 行になり、帯が太くなった。足りなければ説明の文字を省く。2026-11-23）
                Button(action.title) { perform(action) }
                    .lineLimit(1)
                    .fixedSize()
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

/// 知らせの板の寸法（体感の値。画面で見て決める）
enum MainNoticeLayout {
    static let spacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 8
    /// 板の幅の上限（Mac・iPad。iPhone は画面の幅から左右の余白を引いた幅）
    static let maximumWidth: CGFloat = 560
    /// 板と画面の左右の端の間（狭い画面で）
    static let outerMargin: CGFloat = 16
    static let cornerRadius: CGFloat = 16
    /// 板と下の切り替え（タブバー）の間（iOS 版）
    static let gapAboveTabBar: CGFloat = 8
    /// 板と横スクロールバーの間（macOS 版。板は窓の下端の横スクロールバーより上に出す）
    static let gapAboveScroller: CGFloat = 8
    /// 出し入れの動きの長さ
    static let transitionDuration: TimeInterval = 0.25
}
