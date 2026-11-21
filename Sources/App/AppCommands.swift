import SwiftUI

// メニュー（構成は 2026-11-20 に決めた）。
//
// SwiftUI の `.commands` で、mirne mobile・ファイル・編集・コントロール・表示・ウインドウ・ヘルプの 7 つを作る。
// 主ウインドウの操作（設定・新規予約・削除・検索・更新・番組表の「現在」）は `MainCommandCenter` に頼みを置き、
// 画面がそれを受け取って行う（画面を開いていなければ、切り替えてから受け取る）。
// 文字だけのキー（スペース・Q・S・A・C・M・T）の項目は、視聴ウインドウが前にあるときだけ有効にする
// （主ウインドウの検索欄に打った文字をメニューが横取りしないため。視聴ウインドウは `FocusedValues.viewerIsKey` を置く）

/// 主ウインドウへの頼み（メニューが置き、画面が受け取る）
enum MainRequest: Equatable {
    case settings
    case newSchedule
    case deleteRecording
    case deleteSchedule
    case searchRecordings
    case guideNow
    case refresh
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

/// アプリのメニュー
struct AppCommands: Commands {
    let environment: AppEnvironment

    var body: some Commands {
        // mirne mobile：設定…（⌘,。ツールバーの「設定」と同じく主ウインドウのシート）
        CommandGroup(replacing: .appSettings) {
            MainCommandButton(environment: environment, title: "設定…", request: .settings, section: nil)
                .keyboardShortcut(",", modifiers: .command)
        }
        // ファイル
        CommandGroup(replacing: .newItem) {
            FileMenuItems(environment: environment)
        }
        // 編集：検索（⌘F。録画の検索欄へ移る）
        CommandGroup(after: .textEditing) {
            MainCommandButton(environment: environment, title: "検索", request: .searchRecordings, section: .recordings)
                .keyboardShortcut("f", modifiers: .command)
        }
        // コントロール（視聴の操作。mirne の「チャンネル」と「音声」を 1 つにまとめた）
        CommandMenu("コントロール") {
            ControlMenuItems(environment: environment)
        }
        // 表示：画面の切り替え・更新・番組表の「現在」・録画一覧の並べ方・文字の大きさ
        CommandGroup(before: .toolbar) {
            ViewMenuItems(environment: environment)
        }
        // ウインドウ：標準の大きさに戻す・常に最前面（視聴ウインドウ）。窓の一覧は macOS が足す
        CommandGroup(after: .windowSize) {
            WindowMenuItems(environment: environment)
        }
        // ヘルプ：ヘルプの本は無いので項目を外す（macOS の検索の欄は残る）
        CommandGroup(replacing: .help) {}
    }
}

/// 主ウインドウへ頼む項目（主ウインドウを前に出し、要るなら画面を切り替えてから頼む）
private struct MainCommandButton: View {
    let environment: AppEnvironment
    let title: String
    let request: MainRequest
    /// 切り替える画面（nil なら切り替えない）
    let section: MainSection?
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MainWindowSettingsKey.section) private var selection: MainSection = .info

    var body: some View {
        Button(title) {
            openWindow(id: MainWindowID.main)
            if let section { selection = section }
            environment.mainCommands.request(request)
        }
        .disabled(environment.services == nil)
    }
}

// MARK: - ファイル

private struct FileMenuItems: View {
    let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MainWindowSettingsKey.section) private var selection: MainSection = .info

    var body: some View {
        Button("ライブで見る") {
            openWindow(id: ViewerWindowID.main)
            Task { await environment.startLive() }
        }
        .keyboardShortcut("l", modifiers: .command)
        .disabled(environment.live == nil)

        // 選んだ録画の再生（名前は一覧の下の欄のボタンと同じ）
        let actions = playActions
        if actions.isEmpty {
            Button("再生") {}
                .keyboardShortcut("o", modifiers: .command)
                .disabled(true)
        } else {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                if index == 0 {
                    Button(action.label) { play(action) }.keyboardShortcut("o", modifiers: .command)
                } else {
                    Button(action.label) { play(action) }
                }
            }
        }

        Divider()
        // 局の一覧は予約の画面が開いたときに読むので、ここでは登録していれば押せる（読めなければ画面がシートを出さない）
        MainCommandButton(environment: environment, title: "新規予約…", request: .newSchedule, section: .schedules)
            .keyboardShortcut("n", modifiers: .command)

        Divider()
        // 録画を削除…・予約を削除…（⌘⌫。選んでいる画面の項目に効く）
        switch selection {
        case .recordings:
            Button("録画を削除…") { environment.mainCommands.request(.deleteRecording) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!canDeleteRecording)
        case .schedules:
            Button("予約を削除…") { environment.mainCommands.request(.deleteSchedule) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(environment.mainCommands.schedules?.selectedSchedule == nil)
        default:
            Button("削除…") {}
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(true)
        }
    }

    /// 選んだ録画の再生のボタン（一覧の下の欄と同じ。押せなければ空）
    private var playActions: [RecordingPlayAction] {
        guard let model = environment.mainCommands.recordings, let title = model.selectedTitle else { return [] }
        let panel = RecordingPlayPanel.make(title: title, state: model.viewingState(of: title), canPlay: model.canPlay,
                                            isStarting: environment.playback.state.isStarting, isRefreshing: model.isRefreshing)
        guard case .actions(let actions, let fromStart) = panel else { return [] }
        return actions + (fromStart.map { [$0] } ?? [])
    }

    private var canDeleteRecording: Bool {
        guard !environment.mainCommands.isSearchFieldFocused,
              let model = environment.mainCommands.recordings, let title = model.selectedTitle else { return false }
        return model.deletionBlocker(title) == nil
    }

    private func play(_ action: RecordingPlayAction) {
        guard let model = environment.mainCommands.recordings, let title = model.selectedTitle,
              model.canPlay, !environment.playback.state.isStarting else { return }
        environment.playFromList(title, action)
        openWindow(id: ViewerWindowID.main)
    }
}

// MARK: - コントロール

private struct ControlMenuItems: View {
    let environment: AppEnvironment
    @FocusedValue(\.viewerIsKey) private var viewerIsKey

    var body: some View {
        let playback = environment.playback
        let viewer = viewerIsKey == true
        let playing = environment.nowPlaying != nil
        let live = playback.kind == .live
        let recording = playing && !live

        Button(playback.state == .paused ? "再生" : "一時停止") {
            playback.state == .paused ? playback.resume() : playback.pause()
        }
        .keyboardShortcut(.space, modifiers: [])
        .disabled(!viewer || !playing)

        Button("10 秒戻る") { playback.skip(by: -SeekPolicy.skipSeconds) }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(!viewer || !recording || !playback.canSeek)
        Button("10 秒進む") { playback.skip(by: SeekPolicy.skipSeconds) }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(!viewer || !recording || !playback.canSeek)

        Button("画質を切り替える") { environment.cycleQuality() }
            .keyboardShortcut("q", modifiers: [])
            .disabled(!viewer || environment.qualityChoices.count < 2 || playback.state.isStarting)
        Button(recording && playback.playbackRate != PlaybackRatePolicy.normal
               ? "再生速度を切り替える（いま \(PlaybackRatePolicy.label(playback.playbackRate))）" : "再生速度を切り替える") {
            playback.cycleRate()
        }
        .keyboardShortcut("s", modifiers: [])
        .disabled(!viewer || !recording || !playback.canChangeRate)

        Divider()
        // ライブの局
        Button("前の局") { environment.stepLive(-1) }
            .keyboardShortcut(.upArrow, modifiers: [])
            .disabled(!viewer || !live)
        Button("次の局") { environment.stepLive(1) }
            .keyboardShortcut(.downArrow, modifiers: [])
            .disabled(!viewer || !live)
        Menu("局を選ぶ") {
            ForEach(LiveRemoteKeys.keys, id: \.number) { key in
                Button(stationTitle(key.number)) { environment.selectLive(remoteKey: key.number) }
                    .keyboardShortcut(KeyEquivalent(key.character), modifiers: [])
                    .disabled(!viewer || !live || !hasStation(key.number))
            }
        }
        .disabled(!viewer || !live)

        Divider()
        let audio = playback.engine.audioStatus
        Button("音声を切り替える") { playback.cycleAudio() }
            .keyboardShortcut("a", modifiers: [])
            .disabled(!viewer || audio.tracks.count < 2 || playback.state.isStarting)
        Menu("二重音声") {
            ForEach(DualMonoChannel.allCases, id: \.self) { channel in
                Toggle(DualMonoLabel.text(channel), isOn: Binding(get: { playback.dualMonoChannel == channel },
                                                                  set: { _ in playback.selectDualMono(channel) }))
            }
        }
        .disabled(!viewer || audio.layout != .dualMono)
        Toggle("字幕", isOn: Binding(get: { environment.captions.isEnabled }, set: { environment.captions.isEnabled = $0 }))
            .keyboardShortcut("c", modifiers: [])
            .disabled(!viewer)

        Divider()
        Toggle("ミュート", isOn: Binding(get: { playback.isMuted }, set: { playback.isMuted = $0 }))
            .keyboardShortcut("m", modifiers: [])
            .disabled(!viewer)
        Button("音量を上げる") { playback.volume = min(1, playback.volume + ViewerVolumeStep.increment) }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(!viewer)
        Button("音量を下げる") { playback.volume = max(0, playback.volume - ViewerVolumeStep.increment) }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(!viewer)
    }

    /// リモコンキーの項目の名前（「1　局名」。局が無ければキーだけ）
    private func stationTitle(_ number: Int) -> String {
        guard let live = environment.live,
              let station = LiveLineup.station(remoteKey: number, in: live.stations(showsSubchannels: AppEnvironment.showsSubchannels))
        else { return "\(number)" }
        return "\(number)　\(station.channel.serviceName)"
    }

    private func hasStation(_ number: Int) -> Bool {
        guard let live = environment.live else { return false }
        return LiveLineup.station(remoteKey: number, in: live.stations(showsSubchannels: AppEnvironment.showsSubchannels)) != nil
    }
}

// MARK: - 表示

private struct ViewMenuItems: View {
    let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MainWindowSettingsKey.section) private var selection: MainSection = .info
    @AppStorage(MainWindowSettingsKey.textSize) private var textSize = MainTextSize.initial.rawValue

    var body: some View {
        let registered = environment.services != nil
        // 中央の切り替えと同じ
        ForEach(Array(MainSection.allCases.enumerated()), id: \.element) { index, section in
            Button(section.title) {
                openWindow(id: MainWindowID.main)
                selection = section
            }
            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            .disabled(!registered)
        }
        Divider()
        MainCommandButton(environment: environment, title: "更新", request: .refresh, section: nil)
            .keyboardShortcut("r", modifiers: .command)
        MainCommandButton(environment: environment, title: "番組表の「現在」へ", request: .guideNow, section: .guide)
        Divider()
        // 録画一覧の並べ方（ツールバーの帯の操作をキーボードからも）
        if let recordings = environment.mainCommands.recordings {
            @Bindable var model = recordings
            Picker("録画の並べ替え", selection: $model.sortOrder) {
                ForEach(RecordingsModel.SortOrder.allCases, id: \.self) { Text(RecordingSortLabel.text($0)).tag($0) }
            }
            Picker("録画の視聴の状態", selection: $model.viewingFilter) {
                ForEach(RecordingsModel.ViewingFilter.allCases, id: \.self) { Text(RecordingViewingFilterLabel.text($0)).tag($0) }
            }
            Toggle("録画を番組名でまとめる", isOn: $model.groupsByName)
        }
        Divider()
        // 文字の大きさ（標準と大きいの 2 つ）
        Button("文字を大きくする") { textSize = MainTextSize.large.rawValue }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(!registered || textSize == MainTextSize.large.rawValue)
        Button("文字を標準にする") { textSize = MainTextSize.standard.rawValue }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(!registered || textSize == MainTextSize.standard.rawValue)
        Divider()
    }
}

// MARK: - ウインドウ

private struct WindowMenuItems: View {
    let environment: AppEnvironment
    @FocusedValue(\.viewerIsKey) private var viewerIsKey

    var body: some View {
        let window = environment.viewerWindow
        Divider()
        Button("標準の大きさに戻す") { window.resetSize() }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(viewerIsKey != true || !window.canResetSize)
        Toggle("常に最前面", isOn: Binding(get: { window.isAlwaysOnTop }, set: { _ in window.toggleAlwaysOnTop() }))
            .keyboardShortcut("t", modifiers: [])
            .disabled(viewerIsKey != true || window.isFullScreen)
    }
}

/// 主ウインドウの場面の ID
enum MainWindowID {
    static let main = "main"
}
