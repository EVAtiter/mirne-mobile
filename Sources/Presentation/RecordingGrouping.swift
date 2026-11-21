import Foundation

/// 同じ番組名の録画をまとめる決まり。
///
/// 番組名から番組マーク・話数・副題を除いた名前（まとめの名前）が同じ録画を 1 つにまとめる。
/// 除き方は架空の番組名の試験（`RecordingGroupingTests`）で決めた。誤ってまとめても分かるよう、
/// まとめの中では元の番組名を出す
public enum RecordingNameGrouping {
    /// 番組マーク。BroadcastText が角括弧の表記にそろえたもの（[字]・[再]・[デ]・[5.1] など）。中身は 4 文字まで
    static let markPattern = #"\[[^\[\]]{1,4}\]"#
    /// 話数の印（全角は先に半角へそろえてから当てる）：#5・第10話・第三回・(3)・Ep.5・最終回 など
    static let episodePatterns = [
        #"#\s*\d"#,
        #"第\s*[0-9一二三四五六七八九十百千]+\s*[話回夜部章]"#,
        #"\(\s*\d+\s*\)"#,
        #"(?i)\bep(isode)?\.?\s*\d"#,
        #"最終[回話]"#,
    ]
    /// 副題の始まりの印。番組名の頭にあるものは印と見なさない（「【特集】…」の【 など）
    static let subtitleMarkers: [Character] = ["「", "『", "▽", "▼", "◇", "◆", "~", "〜", "【", "<"]
    /// 名前の終わりに残っても意味の無い区切り
    static let trailingSeparators = CharacterSet(charactersIn: " ・:-/|").union(.whitespaces)

    /// まとめの名前。除いた結果が空なら、元の番組名（の空白をそろえたもの）
    public static func groupName(_ title: String) -> String {
        // 全角の英数・記号・空白を半角へ（＃５ → #5、（３） → (3)、～ → ~）
        let folded = title.precomposedStringWithCompatibilityMapping
        let withoutMarks = folded.replacingOccurrences(of: markPattern, with: " ", options: .regularExpression)
        let compact = collapseSpaces(withoutMarks)
        var cut = compact.endIndex
        for pattern in episodePatterns {
            if let range = compact.range(of: pattern, options: .regularExpression), range.lowerBound > compact.startIndex {
                cut = min(cut, range.lowerBound)
            }
        }
        for marker in subtitleMarkers {
            if let index = compact.firstIndex(of: marker), index > compact.startIndex {
                cut = min(cut, index)
            }
        }
        if let range = compact.range(of: " - "), range.lowerBound > compact.startIndex { cut = min(cut, range.lowerBound) }
        let name = String(compact[..<cut]).trimmingCharacters(in: trailingSeparators)
        return name.isEmpty ? collapseSpaces(folded) : name
    }

    /// 録画ごとのまとめの名前（録画の ID → 名前）。
    ///
    /// 1 段目は `groupName`。2 段目に、ほかとまとまらず 1 件だけになった録画どうしで、名前の最初の空白の前（頭）が
    /// 同じものが 2 件以上あれば、その頭でまとめる（「番組名　副題」のように、副題が印なしで空白の後に続く形。
    /// 実機の 648 件で 22 件が 4 つにまとまった。2026-11-20）。頭が既にあるまとめの名前なら、そこへ入れる。
    /// 絞り込みでまとめ方が変わらないよう、絞り込む前の全部の録画で決める
    public static func groupNames(_ titles: [RecordedTitle]) -> [RecordedTitle.ID: String] {
        var names: [RecordedTitle.ID: String] = [:]
        for title in titles { names[title.id] = groupName(title.title) }
        var counts: [String: Int] = [:]
        for name in names.values { counts[name, default: 0] += 1 }
        var byHead: [String: [RecordedTitle.ID]] = [:]
        for title in titles {
            guard let name = names[title.id], counts[name] == 1, name.contains(" ") else { continue }
            byHead[head(name), default: []].append(title.id)
        }
        for (head, members) in byHead where members.count >= 2 && !head.isEmpty {
            for id in members { names[id] = head }
        }
        return names
    }

    /// 名前の最初の空白の前
    static func head(_ name: String) -> String {
        String(name.split(separator: " ", maxSplits: 1).first ?? "")
    }

    private static func collapseSpaces(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// 同じ番組名の録画のまとめ 1 つ
public struct RecordingGroup: Sendable, Equatable, Identifiable {
    /// まとめの名前（`RecordingNameGrouping.groupName`）
    public let name: String
    /// 中の録画（並べ替えの順）
    public let titles: [RecordedTitle]
    /// 未再生の件数（視聴の状態で数える）
    public let unwatchedCount: Int

    public init(name: String, titles: [RecordedTitle], unwatchedCount: Int) {
        self.name = name
        self.titles = titles
        self.unwatchedCount = unwatchedCount
    }

    public var id: String { name }
    /// いちばん新しい録画の日時
    public var latestStart: Date? { titles.compactMap(\.displayStart).max() }
}
