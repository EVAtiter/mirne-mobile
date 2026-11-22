import SwiftUI
import UIKit

/// 中央の切り替え（iPad 版）。項目は文字だけ（絵は出さない。幅が狭いときも文字のまま）。
/// 作りは segmented の Picker のまま、見た目（文字の大きさ・濃さ・選んだ項目の印）を iPadOS のタブバーに寄せる
/// （前は文字が小さく薄くて見にくかった。2026-11-22）。`showsTitles` は macOS 版と同じ呼び方のために受けるだけ
struct MainSectionPicker: View {
    @Binding var selection: MainSection
    let showsTitles: Bool

    init(selection: Binding<MainSection>, showsTitles: Bool) {
        _selection = selection
        self.showsTitles = showsTitles
        MainSectionPickerAppearance.applyOnce()
    }

    var body: some View {
        Picker("画面", selection: $selection) {
            ForEach(MainSection.allCases) { section in
                Text(section.title).tag(section)
            }
        }
        .pickerStyle(.segmented)
    }
}

/// 中央の切り替えの見た目（タブバーの手本：本文に近い大きさ・選んでいない項目も濃い文字・選んだ項目は淡い灰色の地に色付きの文字）。
/// UISegmentedControl の見た目の設定はアプリ全体に効くので、ナビゲーションの帯の中のものだけに絞る
/// （予約のシートの segmented には効かせない）
@MainActor
enum MainSectionPickerAppearance {
    /// 文字の大きさ（体感の値。タブバーの文字に合わせて画面で見て決める）
    static let fontSize: CGFloat = 17
    /// 文字の太さ（選んでいない項目・選んだ項目。細いと見にくかったので一段太くした。2026-11-22）
    static let normalWeight: UIFont.Weight = .medium
    static let selectedWeight: UIFont.Weight = .bold
    private static var applied = false

    static func applyOnce() {
        guard !applied else { return }
        applied = true
        let control = UISegmentedControl.appearance(whenContainedInInstancesOf: [UINavigationBar.self])
        control.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: fontSize, weight: normalWeight),
                                        .foregroundColor: UIColor.label], for: .normal)
        control.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: fontSize, weight: selectedWeight),
                                        .foregroundColor: UIColor.tintColor], for: .selected)
        control.selectedSegmentTintColor = .tertiarySystemFill
    }
}
