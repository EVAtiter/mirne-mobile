import SwiftUI

// 主ウインドウへの頼みの仲立ち（macOS ではメニューが頼みを置き、画面が受け取る。iPad の画面でも同じ仕組みを使う）

/// 主ウインドウへの頼み（メニューが置き、画面が受け取る）
enum MainRequest: Equatable {
    case settings
    case newSchedule
    case deleteRecording
    case deleteSchedule
    case searchRecordings
    case guideNow
    case refresh
    /// ライブで見る（前に見た局。iPad のメニューから。macOS のメニューは視聴ウィンドウを直に開く）
    case watchLive
}

/// メニューと主ウインドウの仲立ち（`AppEnvironment` が持つ）。主ウインドウが開いたときに録画と予約のモデルを渡し、
/// メニューはそれを読んで項目の有効・無効を決める
@MainActor
@Observable
final class MainCommandCenter {
    /// 受け取られるのを待っている頼み（1 つだけ。受け取ったら消す）
    private(set) var pending: MainRequest?
    /// 主ウインドウの録画と予約のモデル（主ウインドウが開いている間）
    var recordings: RecordingsModel?
    var schedules: SchedulesModel?
    /// 録画の検索欄に打っている途中か（その間は ⌘⌫ を検索欄の「行の頭まで消す」に譲り、録画を削除…を効かなくする）
    var isSearchFieldFocused = false

    func request(_ request: MainRequest) {
        pending = request
    }

    /// `request` を待っていれば受け取って true（画面が `.onChange(of: pending, initial: true)` で呼ぶ）
    func consume(_ request: MainRequest) -> Bool {
        guard pending == request else { return false }
        pending = nil
        return true
    }
}

extension FocusedValues {
    /// 視聴ウインドウが前にあるか（視聴ウインドウが置く。前に無ければ nil）
    @Entry var viewerIsKey: Bool?
}
