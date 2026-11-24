import SwiftUI

// iPad のメニュー（iPadOS 26 からのメニューバーと、⌘ を押し続けると出るキーボードのショートカットの一覧）。
// 主画面の操作だけを置く：設定（⌘,）・ライブで見る（⌘L）・マニュアル予約（⌘N）・検索（⌘F）・画面の切り替え（⌘1〜5）。
// 再生の画面の文字だけのキー（スペース・←→ など）は、再生の画面が自分で受ける（メニューには置かない）。
// 頼みは macOS と同じく `MainCommandCenter` に置き、主画面が受け取って行う

/// iPad のメニュー
struct IPadCommands: Commands {
    let environment: AppEnvironment

    var body: some Commands {
        // 設定…（主画面のシート）
        CommandGroup(replacing: .appSettings) {
            IPadCommandButton(environment: environment, title: "設定…", request: .settings, section: nil)
                .keyboardShortcut(",", modifiers: .command)
        }
        // ファイル：ライブで見る・マニュアル予約
        CommandGroup(replacing: .newItem) {
            IPadCommandButton(environment: environment, title: "ライブで見る", request: .watchLive, section: nil)
                .keyboardShortcut("l", modifiers: .command)
                .disabled(environment.live == nil)
            if ManualScheduleLabel.isOffered {
                IPadCommandButton(environment: environment, title: ManualScheduleLabel.title + "…", request: .newSchedule, section: .schedules)
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        // 編集：検索（録画の検索欄へ移る）
        CommandGroup(after: .textEditing) {
            IPadCommandButton(environment: environment, title: "検索", request: .searchRecordings, section: .recordings)
                .keyboardShortcut("f", modifiers: .command)
        }
        // 表示：画面の切り替え
        CommandGroup(before: .toolbar) {
            IPadSectionItems(environment: environment)
        }
    }
}

/// 主画面へ頼む項目（要るなら画面を切り替えてから頼む）
private struct IPadCommandButton: View {
    let environment: AppEnvironment
    let title: String
    let request: MainRequest
    /// 切り替える画面（nil なら切り替えない）
    let section: MainSection?
    @AppStorage(MainWindowSettingsKey.section) private var selection: MainSection = .info

    var body: some View {
        Button(title) {
            if let section { selection = section }
            environment.mainCommands.request(request)
        }
        .disabled(environment.services == nil)
    }
}

/// 画面の切り替え（中央の切り替えと同じ。⌘1〜4）
private struct IPadSectionItems: View {
    let environment: AppEnvironment
    @AppStorage(MainWindowSettingsKey.section) private var selection: MainSection = .info

    var body: some View {
        ForEach(Array(MainSection.allCases.enumerated()), id: \.element) { index, section in
            Button(section.title) { selection = section }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .disabled(environment.services == nil)
        }
        Divider()
    }
}
