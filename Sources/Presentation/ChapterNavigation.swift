import Foundation

/// チャプターの前後への飛び方と、位置のつまみの印の置き場（純粋な関数。試験する。torne mobile HB 1.5.0 と同じ決まり）
public enum ChapterNavigation {
    /// 点を過ぎてからこの秒までは、「前のチャプター」でその前の点へ飛ぶ（過ぎてすぐ押し直さなくて済むように。それより後ならその点へ戻る）
    public static let previousWindow: Double = 2

    /// 次のチャプター：今の位置より後の最初の点（無ければ nil）
    public static func next(_ points: [Double], from position: Double) -> Double? {
        points.first { $0 > position }
    }

    /// 前のチャプター：今の位置から `previousWindow` より前の最後の点（無ければ nil）
    public static func previous(_ points: [Double], from position: Double) -> Double? {
        points.last { $0 < position - previousWindow }
    }

    /// 位置のつまみの印の置き場（長さに対する割合 0〜1。長さが分からなければ空。長さを超える点は端に寄せる）
    public static func fractions(_ points: [Double], duration: Double?) -> [Double] {
        guard let duration, duration > 0 else { return [] }
        return points.map { min(max($0 / duration, 0), 1) }
    }
}
