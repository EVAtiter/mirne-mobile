import Foundation

/// 録画のチャプター（`X_PvrControl` の `X_GetTitleInfo` の Result）を読んで確かめる。
///
/// Result は item で包まない xsrs の文書で、根に `chapterNum`・`chapterTime`（`_` で区切った整数の列。単位は 1/45000 秒・録画の頭から）・
/// `startPTS` がある。nasne の無音のところで切った点で、等間隔ではない。壊れたデータを返す録画がある（startPTS が 33 ビットを超える・
/// 録画の長さを超える点・64 ビットに収まらない桁数の点。Buffalo 製では 650 件中 14 件）ので、torne mobile HB 1.5.0 と同じ規則で確かめ、
/// 通らなければ「チャプターなし」にする
public enum TitleChapters {
    /// 点の時刻の単位（1/45000 秒）
    static let unitsPerSecond = 45000
    /// startPTS の上限（33 ビット。これ以上は壊れた録画の印）
    static let ptsLimit = 1 << 33
    /// 最後の点が録画の長さを超えてよい割合
    static let overrunAllowance = 1.02
    /// これより近い点は間引く（秒）
    static let thinningSeconds = 1.0
    /// これより点が少なければチャプターなし
    static let minimumPoints = 2

    /// Result の根の子の名前
    static let countElement = "chapterNum"
    static let timeElement = "chapterTime"
    static let ptsElement = "startPTS"

    /// 確かめで外れた理由（計測コマンドが数える）
    public enum Failure: Error, Equatable {
        case noDuration
        case ptsOutOfRange
        case noCount
        case countMismatch
        /// 数として読めない点（64 ビットに収まらない桁数など）
        case notNumber
        case decreasing
        case overrun
        case unreadable
    }

    /// Result の文書から、確かめて間引いた点（録画の頭からの秒）。外れたら理由
    public static func points(result: String, durationSeconds: Int) -> Result<[Double], Failure> {
        guard let root = try? XMLTree.parse(Data(result.utf8), source: "soap:X_GetTitleInfo") else { return .failure(.unreadable) }
        func text(_ name: String) -> String? { root.firstDescendant(named: name)?.text.trimmingCharacters(in: .whitespaces) }
        return points(count: text(countElement), time: text(timeElement), pts: text(ptsElement), durationSeconds: durationSeconds)
    }

    /// 3 つの値から、確かめて間引いた点（録画の頭からの秒）。外れたら理由
    public static func points(count: String?, time: String?, pts: String?, durationSeconds: Int) -> Result<[Double], Failure> {
        guard durationSeconds > 0 else { return .failure(.noDuration) }
        guard let pts, let ptsValue = Int(pts), ptsValue >= 0, ptsValue < ptsLimit else { return .failure(.ptsOutOfRange) }
        guard let count, let expected = Int(count) else { return .failure(.noCount) }
        let tokens = (time ?? "").split(separator: "_")
        guard tokens.count == expected else { return .failure(.countMismatch) }
        var values: [Int] = []
        for token in tokens {
            guard let value = Int(token), value >= 0 else { return .failure(.notNumber) }
            if let last = values.last, value < last { return .failure(.decreasing) }
            values.append(value)
        }
        if let last = values.last, Double(last) > Double(durationSeconds * unitsPerSecond) * overrunAllowance {
            return .failure(.overrun)
        }
        var kept: [Double] = []
        for value in values {
            let seconds = Double(value) / Double(unitsPerSecond)
            if let previous = kept.last, seconds - previous < thinningSeconds { continue }
            kept.append(seconds)
        }
        return .success(kept)
    }

    /// 画面で使う点（確かめを通って `minimumPoints` 以上あるときだけ。そうでなければ空）
    public static func usablePoints(result: String, durationSeconds: Int) -> [Double] {
        guard case .success(let points) = points(result: result, durationSeconds: durationSeconds),
              points.count >= minimumPoints else { return [] }
        return points
    }
}
