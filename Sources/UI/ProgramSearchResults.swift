import SwiftUI

/// 番組の検索の決まり（番組表の画面の検索の欄と結果の一覧）
enum ProgramSearchLayout {
    /// 検索の欄の見本の文字（Mac の窓のタイトルの帯の欄と、iOS の帯の中の欄で同じもの）
    static let prompt = "番組名・説明"
    /// iOS の帯の中の欄の幅（窓が狭いときは最小の幅まで縮む）
    static let fieldWidth: CGFloat = 200
    static let fieldMinimumWidth: CGFloat = 100
    /// 結果の上の段（ジャンルの選び・件数）の余白
    static let headerHorizontalPadding: CGFloat = 12
    static let headerVerticalPadding: CGFloat = 6
    /// 行の中の 2 段（日時と局・番組名）の間
    static let rowSpacing: CGFloat = 2
    /// 行の中の局のロゴの高さ（番組表の局名の横のロゴと同じ。倍率は掛けない）
    static let logoHeight: CGFloat = 14
}

/// 番組の検索の語（前後の空白を除いて空なら、番組表を出す）
enum ProgramSearchQuery {
    static func isActive(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 番組の検索の結果（番組表の代わりに出す）。上にジャンルの選びと件数、下に放送の始まりの順の一覧。
/// 行を押すと、番組表で番組を押したときと同じシートを出す
struct ProgramSearchResults: View {
    let index: ProgramSearchIndex
    let query: String
    @Binding var genre: GuideGenreCategory?
    let marks: ScheduleMarks
    /// 局のロゴの絵（serviceID ごと）
    let logos: [Int: Image]
    let select: (ProgramSearchIndex.Result) -> Void

    var body: some View {
        // 終わった番組を外すので、分の境目で選び直す
        let minute = (Date().timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: minute), by: 60)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let selected = genre
        let results = index.results(for: query, now: now, genre: selected.map { category in { category.includes($0) } })
        return VStack(spacing: 0) {
            HStack(spacing: ScreenActionBarLayout.spacing) {
                Picker("ジャンル", selection: $genre) {
                    Text("すべてのジャンル").tag(GuideGenreCategory?.none)
                    Divider()
                    ForEach(GuideGenreCategory.allCases) { category in
                        Text(category.name).tag(Optional(category))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .barMenuChrome()
                Spacer(minLength: 0)
                Text("\(results.count) 件")
                    .scaledFont(.callout, monospacedDigit: true)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, ProgramSearchLayout.headerHorizontalPadding)
            .padding(.vertical, ProgramSearchLayout.headerVerticalPadding)
            Divider()
            if results.isEmpty {
                ContentUnavailableView.search(text: query.trimmingCharacters(in: .whitespacesAndNewlines))
                    // 残りの高さいっぱいに広げる（macOS では中身の高さにしかならず、上の帯ごと窓の縦の真ん中に寄る）
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { result in
                    Button { select(result) } label: {
                        ProgramSearchRow(result: result, now: now, mark: marks.mark(result.event, on: result.channel),
                                         logo: logos[result.channel.serviceID])
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                // 一覧を送り始めたらキーボードを閉じる（iPhone のキーボードには閉じるボタンが無い。Mac には効かない。2026-11-24）
                .scrollDismissesKeyboard(.immediately)
            }
        }
    }
}

/// 結果の 1 行：上の段に日時（放送中なら「放送中」）と局、下の段に番組名と予約済みの印
private struct ProgramSearchRow: View {
    let result: ProgramSearchIndex.Result
    let now: Date
    let mark: ScheduleMark?
    let logo: Image?

    private var onAir: Bool {
        (result.event.start ?? .distantFuture) <= now && now < (result.event.end ?? .distantPast)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ProgramSearchLayout.rowSpacing) {
            HStack(spacing: ScreenActionBarLayout.spacing) {
                Text(ProgramSearchIndex.timeText(result.event))
                    .scaledFont(.callout, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                if onAir {
                    Text("放送中")
                        .scaledFont(.caption, weight: .semibold)
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
                if let logo {
                    logo.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(height: ProgramSearchLayout.logoHeight)
                        .accessibilityHidden(true)
                }
                Text(result.channel.serviceName)
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: GuideScheduleMark.spacing) {
                if let mark {
                    Image(systemName: mark == .whole ? GuideScheduleMark.symbol : GuideScheduleMark.partSymbol)
                        .scaledFont(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel(mark == .whole ? "予約済み" : "一部を予約済み")
                }
                Text(result.event.title)
                    .scaledFont(.body, weight: .semibold)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
