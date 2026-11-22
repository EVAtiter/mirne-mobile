import os
import SwiftUI

// 視聴の画面のうち macOS と iPad で共有するもの：映像・字幕・状態の表示・操作部・キー操作。
// 画面の器（macOS は視聴ウィンドウ、iPad は主画面に全画面で重ねる画面）は OS ごとのファイルの `ViewerView`

/// 視聴ウィンドウの ID
enum ViewerWindowID {
    static let main = "viewer"
}

/// 二重音声の選択肢の名前（mirne の DualMonoLabel と同じ）
enum DualMonoLabel {
    static func text(_ channel: DualMonoChannel) -> String {
        switch channel {
        case .main: "主音声"
        case .sub: "副音声"
        case .both: "主＋副"
        }
    }
}

/// 操作部の重ね出しの時間
enum ViewerOverlayTiming {
    /// マウスが止まってから（iPad はタップしてから）操作部を隠すまで
    static let hideDelay: Duration = .seconds(3)
    /// 位置・音声の表示を書き直す間隔
    static let refreshInterval: TimeInterval = 0.5
    /// 出し入れのアニメーション（窓の左上のボタンも同じ時間で出し入れする）
    static let fadeDuration: TimeInterval = 0.2
}

/// 視聴ウィンドウで受けるキー（文字だけのキー。主ウィンドウの検索欄で打った文字では効かない）
enum ViewerKeys {
    /// 録画とライブで共通のキーと、ライブの数字キー（リモコンキー）
    /// "0" は ⌘0（標準の大きさに戻す）と、ライブのリモコンキー 10 の両方
    static let all: Set<KeyEquivalent> = Set([.space, "m", "a", "c", "f", "q", "s", "t", "0", .leftArrow, .rightArrow, .upArrow, .downArrow]
                                             + LiveRemoteKeys.keys.map { KeyEquivalent($0.character) })
}

/// ディスプレイのスリープの抑止の決まり
enum DisplaySleepTiming {
    /// 抑えるかを見直す間隔。再生の始まり・終わり・一時停止・最小化への追従はこの間隔まで遅れてよい
    /// （ディスプレイが眠るまでの時間は分の単位なので、数秒の遅れは見えない。mirne と同じ）
    static let checkInterval: Duration = .seconds(2)
}

/// 音量のキー操作の 1 回の変化
enum ViewerVolumeStep {
    static let increment: Float = 0.1
}

/// 操作部の出し入れ。出したら、しばらくして隠す
@MainActor
@Observable
final class ViewerOverlayState {
    /// 操作部を出しているか
    var isVisible = true
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    /// 出して、`ViewerOverlayTiming.hideDelay` の後に隠す
    func show() {
        isVisible = true
        hide(after: ViewerOverlayTiming.hideDelay)
    }

    func hide(after delay: Duration) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            isVisible = false
        }
    }

    func cancel() {
        hideTask?.cancel()
    }

    /// 始めている・止めている・失敗・最後まで、のときは操作部を出し続ける
    static func keepsVisible(_ state: PlaybackState) -> Bool {
        switch state {
        case .playing, .waiting: false
        default: true
        }
    }

    /// 操作部を出しているか（出してからの数秒と、始めている・止めている・失敗・最後まで、のとき）
    func controlsShown(_ state: PlaybackState) -> Bool {
        isVisible || Self.keepsVisible(state)
    }
}

/// 映像・字幕・状態の表示と、操作部の重ね出し（視聴の画面の中身）。
/// 字幕は mirne の重ね出しを写した。
/// ライブ：位置のつまみ・←→ を隠し、操作部の左に局のメニューを出す
struct ViewerStage<ControlsTrailing: View>: View {
    @Environment(AppEnvironment.self) private var environment
    let overlay: ViewerOverlayState
    /// 操作部の右端に足すもの（macOS は全画面のボタン）。操作部を書き直すたびに作り直す
    @ViewBuilder let controlsTrailing: () -> ControlsTrailing

    var body: some View {
        let playback = environment.playback
        ZStack {
            Color.black
            if let renderer = environment.renderer {
                VideoSurface(renderer: renderer)
            } else {
                Text("映像を表示できません（\(DeviceWording.thisDevice) では Metal が使えません）").foregroundStyle(.white)
            }
            CaptionOverlayView(model: environment.captions)
            stateOverlay(playback.state)
            liveOverlay
            if overlay.controlsShown(playback.state) {
                VStack {
                    Spacer()
                    ViewerControls(playback: playback, captions: environment.captions, trailing: controlsTrailing)
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: ViewerOverlayTiming.fadeDuration), value: overlay.isVisible)
    }

    /// ライブを始める前の表示（局の一覧を読んでいる・始められなかった）
    @ViewBuilder
    private var liveOverlay: some View {
        if environment.preparingLive {
            Label("局の一覧を読み込んでいます…", systemImage: "hourglass").viewerBadge()
        } else if let error = environment.liveStartError {
            ErrorBanner(error: error)
                .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding()
        }
    }

    /// 始めている・待っている・失敗・最後まで、の表示（映像の真ん中）
    @ViewBuilder
    private func stateOverlay(_ state: PlaybackState) -> some View {
        switch state {
        case .starting(let stage):
            Label("\(stage.label)…", systemImage: "hourglass").viewerBadge()
        case .waiting:
            Label("受信を待っています…", systemImage: "hourglass").viewerBadge()
        case .failed(let error, let stage):
            let refused = isLiveRefused(error)
            VStack(alignment: .leading, spacing: 4) {
                if refused, let station = blockingRecordingStation {
                    // nasne が別の局を録画している：録画中の局しか見られないので、そこへ切り替えるボタンを出す
                    // （局をどう選んだか〔ライブのボタン・番組表・局のメニュー・キー〕によらない）
                    // ボタンは文の幅の中で横の中央に置く（板の幅は文で決まる）
                    VStack(alignment: .center, spacing: 4) {
                        ErrorBanner(error: ErrorPresentation(title: LiveRecordingConflict.title,
                                                             message: LiveRecordingConflict.message(LiveStationMenu.title(station))))
                        Button { environment.switchToRecordingStation() } label: {
                            Label(LiveRecordingConflict.switchTitle, systemImage: LiveSymbol.watch)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                    }
                } else {
                    ErrorBanner(error: error)
                    Text("（\(stage.label)の途中で止まりました）").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding()
            // ライブの配信が 511 で断られたら、nasne が録画中かを読む
            .task(id: refused) {
                if refused { await environment.refreshRecordingStation() }
            }
        case .ended:
            Label("最後まで再生しました", systemImage: "checkmark.circle").viewerBadge()
        case .idle, .playing, .paused:
            EmptyView()
        }
    }
}

extension ViewerStage {
    /// ライブの配信が 511 で断られたか（ほかの機器が配信を使っている・nasne が別の局を録画している）
    fileprivate func isLiveRefused(_ error: ErrorPresentation) -> Bool {
        environment.playback.kind == .live && error.code == String(LivePlaybackErrors.inUseStatus)
    }

    /// 断られた理由が録画のときの、録画中の局（見ようとした局と別の局を録画しているとき。そうでなければ nil）
    fileprivate var blockingRecordingStation: LiveStation? {
        guard let station = environment.recordingStation, environment.nowPlaying != .live(station.key) else { return nil }
        return station
    }
}

/// 位置のつまみの下に出すチャプターの印
private struct ChapterMarks: View {
    let fractions: [Double]

    var body: some View {
        GeometryReader { geo in
            let inset = ChapterMarkLayout.trackInset
            let width = max(0, geo.size.width - 2 * inset)
            ForEach(Array(fractions.enumerated()), id: \.offset) { _, fraction in
                Capsule()
                    .fill(.white.opacity(ChapterMarkLayout.opacity))
                    .frame(width: ChapterMarkLayout.width, height: ChapterMarkLayout.height)
                    .position(x: inset + width * fraction, y: geo.size.height - ChapterMarkLayout.height / 2)
            }
        }
        .frame(height: ChapterMarkLayout.height)
        .offset(y: ChapterMarkLayout.height + ChapterMarkLayout.gap)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// チャプターの印の寸法（体感の値。画面で見て決める）
enum ChapterMarkLayout {
    static let width: CGFloat = 2
    static let height: CGFloat = 5
    /// つまみの下端から印までの間
    static let gap: CGFloat = 1
    static let opacity: Double = 0.7
    /// 溝の両端の内側の幅（つまみの半分。OS ごと）
    static var trackInset: CGFloat { ChapterMarkPlatform.trackInset }
}

/// ライブの配信が、nasne の録画のために断られたときの文言
enum LiveRecordingConflict {
    static let title = "nasne が録画中です"
    static let switchTitle = "録画中の局に切り替える"

    static func message(_ station: String) -> String {
        "録画している間は、録画中の局（\(station)）しかライブで見られません。"
    }
}

/// 視聴の画面の、OS に依らない振る舞い（キー操作・ディスプレイのスリープ）
@MainActor
enum ViewerBehavior {
    /// 窓の操作（全画面・常に最前面・標準の大きさ）。iPad には無いので nil
    struct WindowActions {
        let toggleFullScreen: () -> Void
        let toggleAlwaysOnTop: () -> Void
        let resetSize: () -> Void
    }

    /// キー操作。スペースで一時停止、←→ で 10 秒戻る・進む、M でミュート、A で音声の切り替え、C で字幕、⌘↑↓ で音量、Q で画質、S で速さ。
    /// macOS は F で全画面、T で常に最前面、⌘0 で標準の大きさ。
    /// ライブ：スペースで止めると受信を切り、再開すると今の放送から見直す。↑↓ で前後の局、数字キーでリモコンキーの局
    static func handle(_ press: KeyPress, environment: AppEnvironment, window: WindowActions?) -> KeyPress.Result {
        let playback = environment.playback
        let command = press.modifiers.contains(.command)
        let live = playback.kind == .live
        switch press.key {
        case .space where !command:
            playback.state == .paused ? playback.resume() : playback.pause()
        case .upArrow where !command && live:
            environment.stepLive(-1)
        case .downArrow where !command && live:
            environment.stepLive(1)
        case .leftArrow where live, .rightArrow where live:
            return .ignored
        case "m" where !command:
            playback.isMuted.toggle()
        case "a" where !command:
            playback.cycleAudio()
        case "q" where !command:
            // 次の画質へ（録画は元画質とモバイル、ライブは DR・3倍・モバイルを回る）
            environment.cycleQuality()
        case "s" where !command && !live:
            // 次の速さへ（1・1.25・1.5・2 倍を回る。録画中の録画は等速だけで、何もしない）
            playback.cycleRate()
        case "c" where !command:
            environment.captions.isEnabled.toggle()
        case "f" where !command:
            guard let window else { return .ignored }
            window.toggleFullScreen()
        case "t" where !command:
            // 常に最前面の切り替え（mirne と同じ T。全画面の間は切り替えない）
            guard let window else { return .ignored }
            window.toggleAlwaysOnTop()
        case "0" where command:
            // 標準の大きさに戻す（全画面の間は何もしない）
            guard let window else { return .ignored }
            window.resetSize()
        case .leftArrow where !command && press.modifiers.contains(.shift):
            // Shift + ←→：前後のチャプターへ（チャプターの無い録画では何もしない）
            environment.seekChapter(forward: false)
        case .rightArrow where !command && press.modifiers.contains(.shift):
            environment.seekChapter(forward: true)
        case .leftArrow where !command:
            playback.skip(by: -SeekPolicy.skipSeconds)
        case .rightArrow where !command:
            playback.skip(by: SeekPolicy.skipSeconds)
        case .upArrow where command:
            playback.volume = min(1, playback.volume + ViewerVolumeStep.increment)
        case .downArrow where command:
            playback.volume = max(0, playback.volume - ViewerVolumeStep.increment)
        default:
            guard live, !command, let number = LiveRemoteKeys.number(for: press.key.character) else { return .ignored }
            environment.selectLive(remoteKey: number)
        }
        return .handled
    }

    /// 再生している間（一時停止中・窓をしまっているときを除く）、ディスプレイを眠らせない。
    /// 一時停止・最小化への追従は `DisplaySleepTiming.checkInterval` まで遅れてよい（mirne と同じ見直し方）
    static func watchDisplaySleep(_ environment: AppEnvironment, isHidden: () -> Bool) async {
        let playback = environment.playback
        while !Task.isCancelled {
            let playing = playback.state == .playing || playback.state == .waiting
            environment.displaySleep.update(ViewerWindowID.main, blocking: playing && !isHidden())
            try? await Task.sleep(for: DisplaySleepTiming.checkInterval)
        }
        environment.displaySleep.update(ViewerWindowID.main, blocking: false)
    }
}

/// 映像の下に重ねる操作部
struct ViewerControls<Trailing: View>: View {
    let playback: PlaybackController
    let captions: CaptionOverlayModel
    /// 右端に足すもの（macOS は全画面のボタン）。書き直すたびに作り直す（全画面の印を今の状態にするため）
    @ViewBuilder let trailing: () -> Trailing
    @Environment(AppEnvironment.self) private var environment
    /// 位置のつまみを動かしている間の位置（離したら、そこへ飛ぶ）
    @State private var scrubbing: Double?
    /// 番組表にサブチャンネルも並べるか（ライブの局のメニューも従う）
    @AppStorage(GuideSettingsKey.showsSubchannels) private var showsSubchannels = false

    private var isLive: Bool { playback.kind == .live }

    var body: some View {
        TimelineView(.periodic(from: .now, by: ViewerOverlayTiming.refreshInterval)) { _ in
            VStack(spacing: 6) {
                if !isLive, let duration = playback.durationSeconds, duration > 0 {
                    // 位置のつまみ。動かしている間は位置だけ変え、離したところで張り直す
                    Slider(value: Binding(get: { min(scrubbing ?? playback.displaySeconds ?? 0, duration) },
                                          set: { scrubbing = $0 }),
                           in: 0...duration) { editing in
                        guard !editing, let target = scrubbing else { return }
                        scrubbing = nil
                        playback.seek(to: target)
                    }
                    .controlSize(.small)
                    .tint(.white)
                    // AppKit が描くので、明るい外観では暗い操作部の上で見えにくい（二重音声のメニューと同じ）
                    .environment(\.colorScheme, .dark)
                    .disabled(!playback.canSeek)
                    // チャプターの位置の印（つまみの下に細い縦線。つまみは OS が描くので、溝の両端の内側の幅は体感の値で合わせる）
                    .overlay(alignment: .bottom) {
                        ChapterMarks(fractions: ChapterNavigation.fractions(environment.chapters, duration: duration))
                    }
                }
                HStack(spacing: 14) {
                    if isLive {
                        liveControls
                    } else {
                        recordingControls
                    }
                    Spacer()
                    if !isLive {
                        RateMenu(rate: playback.playbackRate, canChange: playback.canChangeRate) { playback.setRate($0) }
                    }
                    let qualities = environment.qualityChoices
                    if qualities.count > 1 {
                        QualityMenu(choices: qualities, current: playback.currentResource) { environment.switchQuality(to: $0) }
                            .disabled(playback.state.isStarting)
                    }
                    let audio = playback.engine.audioStatus
                    if audio.tracks.count > 1 {
                        Button("音声 \((audio.selectedIndex ?? 0) + 1) / \(audio.tracks.count)") {
                            playback.cycleAudio()
                        }
                        .disabled(playback.state.isStarting)
                        .help("音声を切り替える（A）")
                    }
                    if audio.layout == .dualMono {
                        Menu(DualMonoLabel.text(playback.dualMonoChannel)) {
                            ForEach(DualMonoChannel.allCases, id: \.self) { channel in
                                Button {
                                    playback.selectDualMono(channel)
                                } label: {
                                    if channel == playback.dualMonoChannel {
                                        Label(DualMonoLabel.text(channel), systemImage: "checkmark")
                                    } else {
                                        Text(DualMonoLabel.text(channel))
                                    }
                                }
                            }
                        }
                        .viewerMenuStyle()
                        // Menu は AppKit が描くので foregroundStyle(.white) が効かず、明るい外観では黒い文字になって
                        // 暗い操作部の上で見えなかった（2026-11-20）。このメニューだけ暗い外観で描く
                        .environment(\.colorScheme, .dark)
                        .fixedSize()
                        .disabled(playback.state.isStarting)
                        .help("二重音声の主・副を選ぶ")
                    }
                    if captions.isAvailable {
                        Button { captions.isEnabled.toggle() } label: {
                            Image(systemName: captions.isEnabled ? "captions.bubble.fill" : "captions.bubble")
                        }
                        .help(captions.isEnabled ? "字幕を消す（C）" : "字幕を出す（C）")
                    }
                    Button { playback.isMuted.toggle() } label: {
                        Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .help("ミュート（M）")
                    // アプリの中の音量（iPad は端末の音量ボタンで変えるので出さない）
                    if ViewerControlsLayout.showsVolumeSlider {
                        Slider(value: Binding(get: { Double(playback.volume) }, set: { playback.volume = Float($0) }), in: 0...1)
                            .frame(width: 90)
                            .help("音量（⌘↑・⌘↓）")
                    }
                    trailing()
                }
                .buttonStyle(.borderless)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
        }
    }

    /// 録画の操作：一時停止・前後へ飛ばす・位置
    @ViewBuilder private var recordingControls: some View {
        Button {
            playback.state == .paused ? playback.resume() : playback.pause()
        } label: {
            Image(systemName: playback.state == .paused ? "play.fill" : "pause.fill").frame(width: 18)
        }
        .disabled(!(playback.state == .playing || playback.state == .paused || playback.state == .waiting))
        .help("一時停止・再開（スペース）")
        // 前後のチャプター（チャプターのある録画だけ。10 秒の飛ばしの外側に置く）
        let hasChapters = !environment.chapters.isEmpty
        if hasChapters {
            Button { environment.seekChapter(forward: false) } label: { Image(systemName: "backward.end.fill") }
                .disabled(!playback.canSeek)
                .help("前のチャプター（Shift + ←）")
        }
        // 記号は 10 秒の形（SeekPolicy.skipSeconds を変えたら記号も合わせる。SF Symbols は 5・10・15・30 秒など）
        Button { playback.skip(by: -SeekPolicy.skipSeconds) } label: { Image(systemName: "gobackward.10") }
            .disabled(!playback.canSeek)
            .help("\(Int(SeekPolicy.skipSeconds)) 秒戻る（←）")
        Button { playback.skip(by: SeekPolicy.skipSeconds) } label: { Image(systemName: "goforward.10") }
            .disabled(!playback.canSeek)
            .help("\(Int(SeekPolicy.skipSeconds)) 秒進む（→）")
        if hasChapters {
            Button { environment.seekChapter(forward: true) } label: { Image(systemName: "forward.end.fill") }
                .disabled(!playback.canSeek)
                .help("次のチャプター（Shift + →）")
        }
        Text(PlaybackTimeFormat.text(scrubbing ?? playback.displaySeconds) + " / " + PlaybackTimeFormat.text(playback.durationSeconds))
            .monospacedDigit()
    }

    /// ライブの操作：止める・見直す、局のメニューと「ライブ」の印。止めると受信を切り、再開すると今の放送から見直す
    @ViewBuilder private var liveControls: some View {
        Button {
            playback.state == .paused ? playback.resume() : playback.pause()
        } label: {
            Image(systemName: playback.state == .paused ? "play.fill" : "pause.fill").frame(width: 18)
        }
        .disabled(!(playback.state == .playing || playback.state == .paused || playback.state == .waiting))
        .help(playback.state == .paused ? "今の放送から見直す（スペース）" : "止める（スペース）")
        if let live = environment.live {
            LiveStationMenu(live: live, current: currentStation, showsSubchannels: showsSubchannels) { environment.playLive($0) }
        }
        Text("ライブ")
            .font(.caption.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
    }

    /// いま見ている局
    private var currentStation: LiveStationKey? {
        if case .live(let key) = environment.nowPlaying { return key }
        return nil
    }
}

extension View {
    /// 映像の上の小さな案内
    func viewerBadge() -> some View {
        padding(8).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(.white)
    }
}

/// 速さのメニュー（操作部。録画だけ。等速のときは「速度」、ほかの速さのときは今の速さを出す。2026-11-21 に決めた）
struct RateMenu: View {
    let rate: Double
    /// 替えられるか（録画中の録画は等速だけ）
    let canChange: Bool
    let select: (Double) -> Void

    var body: some View {
        Menu(rate == PlaybackRatePolicy.normal ? "速度" : PlaybackRatePolicy.label(rate)) {
            ForEach(PlaybackRatePolicy.rates, id: \.self) { choice in
                Button { select(choice) } label: {
                    let name = PlaybackRatePolicy.label(choice)
                    if choice == rate { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        }
        .viewerMenuStyle()
        // 画質のメニューと同じく、AppKit が描くので暗い外観で描く
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .disabled(!canChange)
        .help(canChange ? "再生速度を切り替える（S）" : "録画中の録画は等速で再生します")
    }
}

/// 画質のメニュー（操作部。今の画質の名前を出し、押すと選べる画質の一覧。2026-11-20 に決めた）
struct QualityMenu: View {
    let choices: [TitleResource]
    let current: TitleResource?
    let select: (TitleResource) -> Void

    var body: some View {
        Menu(RecordingFormat.resourceQuality(current?.quality)) {
            ForEach(choices, id: \.url) { resource in
                Button { select(resource) } label: {
                    let name = RecordingFormat.resourceQuality(resource.quality)
                    if resource.quality == current?.quality { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        }
        .viewerMenuStyle()
        // 二重音声のメニューと同じく、AppKit が描くので暗い外観で描く
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .help("画質を切り替える（Q）")
    }
}

/// ライブの局のメニュー（操作部の左。押すと局の一覧：リモコンキー・局名・放送中の番組名。2026-11-20 に決めた）
struct LiveStationMenu: View {
    let live: LiveModel
    let current: LiveStationKey?
    let showsSubchannels: Bool
    let select: (LiveStation) -> Void

    var body: some View {
        let currentStation = current.flatMap { live.station($0) }
        Menu(currentStation.map(Self.title) ?? "局を選ぶ") {
            ForEach(Self.items(live.stations(showsSubchannels: showsSubchannels), current: currentStation)) { station in
                Button { select(station) } label: {
                    let text = Self.itemText(station, program: live.programs[station.key])
                    if station.key == current { Label(text, systemImage: "checkmark") } else { Text(text) }
                }
                .disabled(station.unavailableReason != nil)
            }
        }
        .viewerMenuStyle()
        // 二重音声のメニューと同じく、AppKit が描くので暗い外観で描く（明るい外観では暗い操作部の上で見えない）
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .help("局を選ぶ（↑↓・数字キー）")
        // 操作部を出すたびに放送中の番組名を引き直す（番組の境目で古くならないように）
        .task { await live.refreshPrograms() }
    }

    /// 一覧に並べる局（番組表から隠したサブチャンネルを見ているときは、それも最後に入れる）
    static func items(_ stations: [LiveStation], current: LiveStation?) -> [LiveStation] {
        guard let current, !stations.contains(where: { $0.key == current.key }) else { return stations }
        return stations + [current]
    }

    /// メニューの見出し（リモコンキーと局名）
    static func title(_ station: LiveStation) -> String {
        station.channel.remoteControlKey.map { "\($0)  \(station.channel.serviceName)" } ?? station.channel.serviceName
    }

    /// 一覧の 1 行（見られない局は理由を添える）
    static func itemText(_ station: LiveStation, program: String?) -> String {
        var text = title(station)
        if let program { text += "　\(program)" }
        if let reason = station.unavailableReason { text += "（\(reason)）" }
        return text
    }
}
