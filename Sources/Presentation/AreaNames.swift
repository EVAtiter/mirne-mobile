// torne mobile HB（MIT、© mar1mo-41414）の lib/ui/format.dart の areaLabel と地域の表を Swift へ移植したもの
// （plan.md §19。表の出所は nasne 本体の Web UI に組み込まれた 56 件の表）。

import Foundation

/// `status/areaInfoGet` の (areaIdentifierCode, pref) を、公式の地域の名前に直す。
/// 表に無い組は数のまま返す（名前を作らない）
public enum AreaNames {
    struct Key: Hashable {
        let code: Int
        let pref: Int
    }

    /// (areaIdentifierCode, pref) → 地域の名前
    static let byPair: [Key: String] = {
        let entries: [(Int, Int, String)] = [
            (13, 1, "北海道（帯広）"), (14, 1, "北海道（釧路）"), (15, 1, "北海道（北見）"), (12, 1, "北海道（旭川）"),
            (12, 2, "北海道（旭川・空知）"), (10, 2, "北海道（札幌）"), (11, 2, "北海道（函館）"), (16, 2, "北海道（室蘭）"),
            (22, 3, "青森"), (20, 4, "岩手"), (17, 5, "宮城"), (18, 6, "秋田"), (19, 7, "山形"), (21, 8, "福島"),
            (26, 9, "茨城"), (28, 10, "栃木"), (25, 11, "群馬"), (29, 12, "埼玉"), (27, 13, "千葉"), (23, 14, "東京"),
            (23, 49, "東京（島部）"), (24, 15, "神奈川"), (31, 16, "新潟"), (37, 17, "富山"), (34, 18, "石川"),
            (36, 19, "福井"), (32, 20, "山梨"), (30, 21, "長野"), (39, 22, "岐阜"), (35, 23, "静岡"), (33, 24, "愛知"),
            (38, 25, "三重"), (45, 26, "滋賀"), (41, 27, "京都"), (40, 28, "大阪"), (42, 29, "兵庫"), (44, 30, "奈良"),
            (43, 31, "和歌山"), (49, 32, "鳥取"), (48, 33, "島根"), (47, 34, "岡山"), (46, 35, "広島"), (50, 36, "山口"),
            (53, 37, "徳島"), (52, 38, "香川"), (51, 39, "愛媛"), (54, 40, "高知"), (55, 41, "福岡"), (61, 42, "佐賀"),
            (57, 43, "長崎"), (56, 44, "熊本"), (60, 45, "大分"), (59, 46, "宮崎"), (58, 47, "鹿児島"),
            (58, 50, "鹿児島（南西諸島）"), (62, 48, "沖縄"),
        ]
        return Dictionary(uniqueKeysWithValues: entries.map { (Key(code: $0.0, pref: $0.1), $0.2) })
    }()

    /// pref だけで 1 つに決まる地域（北海道の 1・2 を除く）
    static let byUniquePref: [Int: String] = {
        var names: [Int: Set<String>] = [:]
        for (key, name) in byPair { names[key.pref, default: []].insert(name) }
        return names.compactMapValues { $0.count == 1 ? $0.first : nil }
    }()

    /// 地域の名前。分からなければ数のまま（pref、無ければ areaIdentifierCode）。どちらも無ければ nil
    public static func label(areaIdentifierCode: Int?, pref: Int?) -> String? {
        if let code = areaIdentifierCode, let pref, let name = byPair[Key(code: code, pref: pref)] { return name }
        if let pref, let name = byUniquePref[pref] { return name }
        return pref.map(String.init) ?? areaIdentifierCode.map(String.init)
    }
}
