import Foundation

// 番組の検索。AppKit・SwiftUI に依存させない（Mac・iPhone・iPad で同じ探し方にする）

/// 手元の番組表（EPGStore から読んだ番組）の中から、語を含む番組を探す。nasne への問い合わせは増やさない。
///
/// - 探すのは番組名と短い説明（手元の番組表は詳しい説明を持っていない）。どちらかに語を含めば出す。局名は探さない
/// - 大文字と小文字・全角と半角を区別しない（放送の英数は全角で届くことが多い）
/// - 放送中とこれからの番組だけ（結果から予約・ライブで見るに使えるものだけ）。並びは放送の始まりの順（同じなら局の並び）。件数の上限は置かない
/// - ジャンルで絞れる（語を入れた後の結果を絞る。語が空なら何も出さない）
/// - 語は前後の空白を除いた全体を 1 つの語として探す
///
/// 全角・半角と大文字・小文字を区別しない比べ方を打つたびに全件へかけると重い（約 3,900 件で 1 回 75〜100 ms。2026-11-24 に測った）ので、
/// 番組表を読み直したときに一度だけ、比べやすい形（`fold`）にそろえた文字を作っておき、打つたびには素の部分一致（`.literal`）で探す
/// （約 3,900 件で、作るのに約 16 ms・探すのに約 3 ms。Swift の `contains` は文字の同値を見るぶん遅く、15〜24 ms だった）
public struct ProgramSearchIndex: Sendable {
    /// 探す元の 1 局（番組表に並べている局と、その局の番組）
    public struct Source: Sendable {
        public let channel: Channel
        public let events: [BroadcastEvent]

        public init(channel: Channel, events: [BroadcastEvent]) {
            self.channel = channel
            self.events = events
        }
    }

    /// 見つかった番組
    public struct Result: Sendable, Identifiable, Equatable {
        public let channel: Channel
        public let event: BroadcastEvent

        /// 局と番組の組（同じ番組を 2 度出さない）
        public var id: String {
            "\(channel.networkID)-\(channel.transportStreamID)-\(channel.serviceID)-\(event.eventID)"
        }
    }

    private struct Entry: Sendable {
        /// 局の並び（同じ時刻の番組を並べる順）
        let order: Int
        let result: Result
        /// 番組名と短い説明を比べやすい形にそろえたもの
        let folded: String
    }

    /// 放送の始まりの順に並べた番組（始まりの分からない番組は後ろ）
    private let entries: [Entry]

    /// 何も探せない索引（番組表を読む前）
    public static let empty = ProgramSearchIndex(sources: [])

    /// 番組表を読み直したときに作る（重いので画面の外で行う）
    public init(sources: [Source]) {
        var entries: [Entry] = []
        for (order, source) in sources.enumerated() {
            for event in source.events {
                let folded = Self.fold(event.title) + Self.fieldSeparator + Self.fold(event.text)
                entries.append(Entry(order: order, result: Result(channel: source.channel, event: event), folded: folded))
            }
        }
        self.entries = entries.sorted { lhs, rhs in
            let left = lhs.result.event.start ?? .distantFuture
            let right = rhs.result.event.start ?? .distantFuture
            return left != right ? left < right : lhs.order < rhs.order
        }
    }

    /// 探す元の番組の数（調べの記録用）
    public var count: Int { entries.count }

    /// `query` を番組名か短い説明に含む、`now` の時点で終わっていない番組。`genre` を渡すと、それが真を返す番組だけにする
    public func results(for query: String, now: Date, genre: ((ProgramGenre?) -> Bool)? = nil) -> [Result] {
        let word = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !word.isEmpty else { return [] }
        return entries.lazy
            .filter { Self.isUpcoming($0.result.event, now: now) && $0.folded.range(of: word, options: .literal) != nil && (genre?($0.result.event.genre) ?? true) }
            .map(\.result)
    }

    /// 比べやすい形（大文字と小文字・全角と半角をそろえる）
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    /// 番組名と短い説明のつなぎ（語が番組名の終わりと説明の始まりをまたいで当たらないよう、放送の文字に出ない字を挟む）
    static let fieldSeparator = "\u{0}"

    /// 放送中かこれからか（終わりの分からない番組は、始まりが今より後のときだけ）
    static func isUpcoming(_ event: BroadcastEvent, now: Date) -> Bool {
        if let end = event.end { return end > now }
        if let start = event.start { return start > now }
        return false
    }

    /// 結果の行の日時「11/25(水) 18:00〜18:30」
    public static func timeText(_ event: BroadcastEvent) -> String {
        guard let start = event.start else { return ProgramDisplay.timeRange(event) }
        return "\(ProgramGuide.dateLabel(start)) \(ProgramDisplay.timeRange(event))"
    }
}
