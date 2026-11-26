import Foundation

/// 登録した nasne の一覧での呼び名（設定の「nasne」の節）。
///
/// このアプリで付けた呼び名、無ければ nasne の本体名（記述の friendlyName。つながったときに boxNameGet で読み直す）を出す。
/// 同じ名前の台が 2 台以上あれば、作り手（SIE・Buffalo）を添え、
/// それでも同じなら登録の順の番号も添える（2026-11-25 に決めた。既定の本体名はどの台も「nasne」なので、3 台のうち 2 台が同じ作り手のことがある）
public enum NasneDisplayName {
    /// 本体名が空のときの呼び名
    static let fallbackName = "nasne"

    /// 台の鍵 → 呼び名
    public static func names(for entries: [StoredNasne]) -> [String: String] {
        let bases = entries.map { base($0) }
        var result: [String: String] = [:]
        for (index, entry) in entries.enumerated() {
            let base = bases[index]
            let sameName = entries.indices.filter { bases[$0] == base }
            guard sameName.count > 1 else {
                result[entry.key] = base
                continue
            }
            let maker = maker(of: entry.device)
            let sameMaker = sameName.filter { Self.maker(of: entries[$0].device) == maker }
            var notes: [String] = maker.map { [$0] } ?? []
            if sameMaker.count > 1, let order = sameMaker.firstIndex(of: index) {
                notes.append(String(order + 1))
            }
            result[entry.key] = notes.isEmpty ? base : "\(base)（\(notes.joined(separator: "・"))）"
        }
        return result
    }

    /// 作り手の短い名前（型番の名前から。知らない型番は nil）
    public static func maker(of device: NasneDevice) -> String? {
        switch device.modelName {
        case NasneDevice.nasneModelName: "SIE"
        case NasneDevice.buffaloNasneModelName: "Buffalo"
        default: nil
        }
    }

    /// 呼び名の元：このアプリで付けた呼び名、無ければ本体名、それも空なら「nasne」
    private static func base(_ entry: StoredNasne) -> String {
        if let custom = entry.customName?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty { return custom }
        let name = entry.registration.friendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallbackName : name
    }

    /// 本体名（呼び名を付けた台の一覧の行に、本体名を添えるため。空なら nil）
    public static func boxName(of entry: StoredNasne) -> String? {
        let name = entry.registration.friendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
