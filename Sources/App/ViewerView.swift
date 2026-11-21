import AppKit
import os
import SwiftUI

/// 視聴ウィンドウの ID
enum ViewerWindowID {
    static let main = "viewer"
}

/// 視聴ウィンドウの決まり
enum ViewerLayout {
    /// 映像の縦横比（16:9）。窓はこの比を保ってリサイズする
    static let aspectRatio = CGSize(width: 16, height: 9)
    /// 初めて開くときの大きさ
    static let defaultSize = CGSize(width: 960, height: 540)
    /// これより小さくできない大きさ
    static let minimumSize = CGSize(width: 480, height: 270)
    /// 映像の縦横比を 1 つの数にしたもの（字幕を重ねる矩形の既定。映像の大きさが分かるまで使う）
    static var videoAspectRatio: Double { Double(aspectRatio.width / aspectRatio.height) }
}

/// 視聴の設定の鍵（UserDefaults）
enum ViewerSettingsKey {
    /// 起動したときに字幕を出すか（未設定なら出さない。mirne と同じ）
    static let captionsByDefault = "captionsByDefault"
    /// 視聴ウィンドウを常に最前面にするか（未設定なら通常。mirne と同じ鍵の名前）
    static let alwaysOnTop = "alwaysOnTop"
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
    /// マウスが止まってから操作部を隠すまで
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

/// 音量のキー操作の 1 回の変化
enum ViewerVolumeStep {
    static let increment: Float = 0.1
}

/// 視聴ウィンドウ：映像だけを出し、マウスを動かすと操作部を重ねて出す。16:9 を保ってリサイズし、全画面にできる。
/// キー操作：スペースで一時停止、←→ で 10 秒戻る・進む、M でミュート、A で音声の切り替え、C で字幕、F で全画面、⌘↑↓ で音量、Q で画質、T で常に最前面、⌘0 で標準の大きさ。
/// キーはこの窓が前面のときだけ受ける（主ウィンドウの検索欄で打った文字で効かないように）。
/// 全画面にできるのは、場面に `.windowFullScreenBehavior(.enabled)` を付けているから（MirneMobileApp。2026-11-19）
/// 字幕は mirne の重ね出しを写した。
/// ライブ：位置のつまみ・←→ を隠し、操作部の左に局のメニューを出す。スペースで止めると受信を切り、再開すると今の放送から見直す。↑↓ で前後の局、数字キーでリモコンキーの局
struct ViewerView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var overlayVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var window: NSWindow?
    @FocusState private var focused: Bool
    private let logger = Logger(subsystem: AppLog.subsystem, category: "ui")

    var body: some View {
        let playback = environment.playback
        ZStack {
            Color.black
            if let renderer = environment.renderer {
                VideoSurface(renderer: renderer)
            } else {
                Text("映像を表示できません（この Mac では Metal が使えません）").foregroundStyle(.white)
            }
            CaptionOverlayView(model: environment.captions)
            stateOverlay(playback.state)
            liveOverlay
            if overlayVisible || keepsOverlay(playback.state) {
                VStack {
                    Spacer()
                    ViewerControls(playback: playback, captions: environment.captions, window: window)
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .background(WindowAccessor(beforeShown: { environment.viewerWindow.conceal($0) }) { configure($0) })
        .animation(.easeOut(duration: ViewerOverlayTiming.fadeDuration), value: overlayVisible)
        .onChange(of: controlsShown(playback.state)) { _, shown in setWindowButtons(visible: shown) }
        .onContinuousHover { phase in
            switch phase {
            case .active: showOverlay()
            case .ended: hideOverlay(after: .zero)
            }
        }
        .onTapGesture(count: 2) { toggleFullScreen() }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // 文字だけのキーのメニューの項目は、視聴ウインドウが前にあるときだけ有効
        .focusedSceneValue(\.viewerIsKey, true)
        .onKeyPress(keys: ViewerKeys.all) { press in
            handle(press, playback: playback)
        }
        .onAppear {
            focused = true
            showOverlay()
        }
        .onDisappear {
            hideTask?.cancel()
            environment.displaySleep.update(ViewerWindowID.main, blocking: false)
            environment.endViewing()
        }
        .task { await watchDisplaySleep(playback) }
    }

    /// 窓を整える：タイトルバーを映像に重ね、16:9 を保つ
    private func configure(_ window: NSWindow) {
        self.window = window
        environment.viewerWindow.attach(window)
        window.contentAspectRatio = ViewerLayout.aspectRatio
        window.contentMinSize = ViewerLayout.minimumSize
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = .black
        setWindowButtons(visible: controlsShown(environment.playback.state))
    }

    /// 操作部を出しているか（マウスが動いた後の数秒と、始めている・止めている・失敗・最後まで、のとき）
    private func controlsShown(_ state: PlaybackState) -> Bool {
        overlayVisible || keepsOverlay(state)
    }

    /// 窓の左上のボタン（閉じる・しまう・拡大）を、操作部と一緒に出し入れする。
    /// ボタンを載せているタイトルバーの面ごと透かす（隠している間にマウスを窓へ入れれば、操作部と一緒に出る）
    private func setWindowButtons(visible: Bool) {
        guard let titlebar = window?.standardWindowButton(.closeButton)?.superview else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ViewerOverlayTiming.fadeDuration
            titlebar.animator().alphaValue = visible ? 1 : 0
        }
    }

    /// 全画面の切り替え（受け取った窓、無ければ前面の窓）
    private func toggleFullScreen() {
        guard let target = window ?? NSApp.keyWindow else { return }
        Self.allowFullScreen(target)
        logger.info("全画面を頼んだ: collectionBehavior \(target.collectionBehavior.rawValue, privacy: .public)")
        target.toggleFullScreen(nil)
    }

    /// SwiftUI の Window の場面は、窓を「補助の窓」（collectionBehavior に auxiliary と fullScreenAuxiliary）にして
    /// 全画面に入れない。`.windowFullScreenBehavior(.enabled)` を付けても、窓を受け取ったときに足しても、
    /// SwiftUI が上書きして補助のままだった（2026-11-19）。切り替える直前に、主の窓へ書き換える
    static func allowFullScreen(_ window: NSWindow) {
        window.collectionBehavior.remove([.auxiliary, .fullScreenAuxiliary, .fullScreenNone])
        window.collectionBehavior.insert([.primary, .fullScreenPrimary])
    }

    /// 再生している間（一時停止中・窓をしまっているときを除く）、ディスプレイを眠らせない。
    /// 一時停止・最小化への追従は `DisplaySleepTiming.checkInterval` まで遅れてよい（mirne と同じ見直し方）
    private func watchDisplaySleep(_ playback: PlaybackController) async {
        while !Task.isCancelled {
            let playing = playback.state == .playing || playback.state == .waiting
            environment.displaySleep.update(ViewerWindowID.main, blocking: playing && window?.isMiniaturized != true)
            try? await Task.sleep(for: DisplaySleepTiming.checkInterval)
        }
        environment.displaySleep.update(ViewerWindowID.main, blocking: false)
    }

    /// 始めている・止めている・失敗・最後まで、のときは操作部を出し続ける
    private func keepsOverlay(_ state: PlaybackState) -> Bool {
        switch state {
        case .playing, .waiting: false
        default: true
        }
    }

    private func showOverlay() {
        overlayVisible = true
        hideOverlay(after: ViewerOverlayTiming.hideDelay)
    }

    private func hideOverlay(after delay: Duration) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            overlayVisible = false
            // 全画面では、マウスを動かすまでカーソルも隠す
            if window?.styleMask.contains(.fullScreen) == true { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }

    private func handle(_ press: KeyPress, playback: PlaybackController) -> KeyPress.Result {
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
            toggleFullScreen()
        case "t" where !command:
            // 常に最前面の切り替え（mirne と同じ T。全画面の間は切り替えない。メニューへの置き場は）
            environment.viewerWindow.toggleAlwaysOnTop()
        case "0" where command:
            // 標準の大きさに戻す（全画面の間は何もしない。メニューへの置き場は）
            environment.viewerWindow.resetSize()
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
        showOverlay()
        return .handled
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
            VStack(alignment: .leading, spacing: 4) {
                ErrorBanner(error: error)
                Text("（\(stage.label)の途中で止まりました）").font(.caption).foregroundStyle(.secondary)
            }
            .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding()
        case .ended:
            Label("最後まで再生しました", systemImage: "checkmark.circle").viewerBadge()
        case .idle, .playing, .paused:
            EmptyView()
        }
    }
}

/// 映像の下に重ねる操作部
struct ViewerControls: View {
    let playback: PlaybackController
    let captions: CaptionOverlayModel
    let window: NSWindow?
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
                        .menuStyle(.borderlessButton)
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
                    Slider(value: Binding(get: { Double(playback.volume) }, set: { playback.volume = Float($0) }), in: 0...1)
                        .frame(width: 90)
                        .help("音量（⌘↑・⌘↓）")
                    Button {
                        guard let target = window ?? NSApp.keyWindow else { return }
                        ViewerView.allowFullScreen(target)
                        target.toggleFullScreen(nil)
                    } label: {
                        Image(systemName: window?.styleMask.contains(.fullScreen) == true
                              ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .help("フルスクリーン（F）")
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
        // 記号は 10 秒の形（SeekPolicy.skipSeconds を変えたら記号も合わせる。SF Symbols は 5・10・15・30 秒など）
        Button { playback.skip(by: -SeekPolicy.skipSeconds) } label: { Image(systemName: "gobackward.10") }
            .disabled(!playback.canSeek)
            .help("\(Int(SeekPolicy.skipSeconds)) 秒戻る（←）")
        Button { playback.skip(by: SeekPolicy.skipSeconds) } label: { Image(systemName: "goforward.10") }
            .disabled(!playback.canSeek)
            .help("\(Int(SeekPolicy.skipSeconds)) 秒進む（→）")
        Text(Self.time(scrubbing ?? playback.displaySeconds) + " / " + Self.time(playback.durationSeconds))
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

    /// 秒を「1:02:03」「12:34」に
    static func time(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "--:--" }
        let total = Int(seconds)
        let hours = total / 3600, minutes = total % 3600 / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

private extension View {
    /// 映像の上の小さな案内
    func viewerBadge() -> some View {
        padding(8).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(.white)
    }
}

/// VideoRenderer のビューを SwiftUI に置く
struct VideoSurface: NSViewRepresentable {
    let renderer: VideoRenderer

    func makeNSView(context: Context) -> VideoLayerView { renderer.view }
    func updateNSView(_ nsView: VideoLayerView, context: Context) {}
}

/// SwiftUI の画面から、それを載せている NSWindow を受け取る（mirne の WindowAccessor と同じ）。
/// `beforeShown` は窓に載ったその場で呼ぶ（窓が画面に出る前。SwiftUI の状態は書き換えないこと。 で窓を透明にするのに使う）
struct WindowAccessor: NSViewRepresentable {
    var beforeShown: ((NSWindow) -> Void)? = nil
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.beforeShown = beforeShown
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WindowReportingView, context: Context) {}
}

final class WindowReportingView: NSView {
    var beforeShown: ((NSWindow) -> Void)?
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // 窓の見え方だけを変える処理は、その場で行う（次の回では、SwiftUI が最小の大きさで出した窓が一瞬見えた）
        beforeShown?(window)
        // 画面の更新の途中で SwiftUI の状態を書き換えないよう、次の回に知らせる
        DispatchQueue.main.async { [weak self] in self?.onWindow?(window) }
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
        .menuStyle(.borderlessButton)
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
        .menuStyle(.borderlessButton)
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
        .menuStyle(.borderlessButton)
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
