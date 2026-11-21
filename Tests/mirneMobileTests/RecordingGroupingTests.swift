import Foundation
import Testing

/// 同じ番組名でまとめるときの名前の除き方。番組名はすべて架空
@Suite("番組名のまとめ")
struct RecordingGroupingTests {
    @Test("番組マーク・話数・副題を除く", arguments: [
        ("架空ドラマ #5「嵐の前」[字]", "架空ドラマ"),
        ("[新]架空ドラマ #1「始まり」[字][デ]", "架空ドラマ"),
        ("架空ドラマ　第１０話　別れの朝", "架空ドラマ"),
        ("架空ドラマ 第三回", "架空ドラマ"),
        ("架空ドラマ 最終回「さようなら」[字]", "架空ドラマ"),
        ("架空アニメ（３）", "架空アニメ"),
        ("架空アニメ ＃１２", "架空アニメ"),
        ("架空紀行▽港町を歩く", "架空紀行"),
        ("架空紀行 ▼山あいの宿", "架空紀行"),
        ("架空劇場～夏の夜～", "架空劇場"),
        ("架空劇場〜冬の朝〜", "架空劇場"),
        ("架空ドラマ【最終章】", "架空ドラマ"),
        ("架空ショー - 特別編", "架空ショー"),
        ("Fictional Show Ep.5", "Fictional Show"),
        ("架空ニュース[字]", "架空ニュース"),
        ("架空ニュース", "架空ニュース"),
    ])
    func strips(_ title: String, _ expected: String) {
        #expect(RecordingNameGrouping.groupName(title) == expected)
    }

    @Test("番組名の頭の印や数字は除かない", arguments: [
        // 頭の【】は見出しの一部（副題の始まりと見なさない）
        ("【架空特集】未来の町", "【架空特集】未来の町"),
        // 頭の # は話数と見なさない
        ("#架空ラジオ", "#架空ラジオ"),
        // 番組名の続きの数字（シーズンなど）は話数と見なさない
        ("架空ドラマ2 #3", "架空ドラマ2"),
        // 除くと空になるなら元の番組名
        ("[字]", "[字]"),
    ])
    func keeps(_ title: String, _ expected: String) {
        #expect(RecordingNameGrouping.groupName(title) == expected)
    }

    @Test("全角と半角・空白の違いは同じまとめにする")
    func foldsWidth() {
        #expect(RecordingNameGrouping.groupName("架空 ドラマ #1") == RecordingNameGrouping.groupName("架空　ドラマ　＃２"))
        #expect(RecordingNameGrouping.groupName("ＡＢＣ劇場 #1") == "ABC劇場")
    }
}
