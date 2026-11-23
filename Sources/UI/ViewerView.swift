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
    /// 出したまま止めている数（`hold` と `release`）
    @ObservationIgnored private var holds = 0

    /// 出して、`ViewerOverlayTiming.hideDelay` の後に隠す
    func show() {
        isVisible = true
        hide(after: ViewerOverlayTiming.hideDelay)
    }

    /// 出したまま止める（一覧の吹き出しを出している間。`release` で戻す）
    func hold() {
        holds += 1
        hideTask?.cancel()
        isVisible = true
    }

    /// `hold` を戻す。止めているものが無くなったら、出し直して `hideDelay` の後に隠す
    func release() {
        holds = max(0, holds - 1)
        if holds == 0 { show() }
    }

    func hide(after delay: Duration) {
        guard holds == 0 else { return }
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
struct ViewerStage: View {
    @Environment(AppEnvironment.self) private var environment
    let overlay: ViewerOverlayState

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
                    ViewerControls(playback: playback, captions: environment.captions)
                        .environment(\.viewerOverlay, overlay)
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
    /// ライブ：スペースで止めると受信を切り、再開すると今の放送から見直す。↑ で次の局・↓ で前の局、数字キーでリモコンキーの局
    static func handle(_ press: KeyPress, environment: AppEnvironment, window: WindowActions?) -> KeyPress.Result {
        let playback = environment.playback
        let command = press.modifiers.contains(.command)
        let live = playback.kind == .live
        switch press.key {
        case .space where !command:
            playback.state == .paused ? playback.resume() : playback.pause()
        case .upArrow where !command && live:
            // ↑ で次の局、↓ で前の局（テレビのリモコンのチャンネルの ▲ ▼ と同じ向き）
            environment.stepLive(1)
        case .downArrow where !command && live:
            environment.stepLive(-1)
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

extension EnvironmentValues {
    /// 操作部の並べ方（iOS 版の再生の画面が画面の縦横の比で決める。macOS の視聴ウィンドウはいつも 16:9 なので既定の中央に置く 1 段）
    @Entry var viewerControlsStyle = ViewerControlsStyle.centeredRow
    /// 操作部の出し入れ（一覧の吹き出しを出している間は隠さないように、操作部の中から止める）
    @Entry var viewerOverlay: ViewerOverlayState? = nil
    /// 画面の幅が狭いか（iPhone の縦向きなど。局の一覧を局名だけにする。iOS 版の再生の画面が配る）
    @Entry var viewerIsNarrow = false
    /// 操作部のボタンの並びを避ける、画面の端の安全領域（iOS 版の再生の画面が配る。映像と暗い帯は端まで広げたまま）
    @Entry var viewerControlsSafeArea = EdgeInsets()
}

/// 操作部の寸法（体感の値。画面で見て決める）
enum ViewerControlsMetrics {
    /// 操作部の左右・上下の余白（安全領域がこれより広ければ安全領域に合わせる）
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 10
    /// ライブの 2 段の形の左右の余白（1 段目・2 段目とも画面の幅いっぱいに並ぶので、録画より広く取る）
    static let liveTwoRowsHorizontalPadding: CGFloat = 32
    /// 1 段の形のボタンの間・左右の組と真ん中の物の間
    static let rowSpacing: CGFloat = 14
    /// 2 段の形の 1 段目（再生の操作）のボタンの間
    static let transportSpacing: CGFloat = 30
    /// 2 段の形の 2 段目のボタンの間の最小（1 段目より 2 段目が広いときは、この間で並べて 1 段目より広げる）
    static let secondRowMinimumSpacing: CGFloat = 16
    /// 横向きの位置のつまみとボタンの段の間（チャプターの印がボタンに近すぎた。2026-11-23）
    static let centeredRowGap: CGFloat = 16
    /// 横向きの中央の再生の操作のボタンの間
    static let centeredTransportSpacing: CGFloat = 22
    /// 音量のつまみの幅（macOS）
    static let volumeSliderWidth: CGFloat = 90
    /// 2 段の形の段の間
    static let rowGap: CGFloat = 12
}

/// 操作部の並べ方
enum ViewerControlsStyle {
    /// 1 段で、真ん中の物を中央に置く（iPhone・iPad の横向き・macOS）。
    /// 録画：左に速さ〜ミュート（macOS は音量のつまみも）、中央に再生の操作、右端に時刻。
    /// ライブ：左端に「ライブ」の印と画質〜ミュート、中央に局のメニュー、右端に一時停止。
    /// 1 段に入らない幅（macOS の小さい窓など）では 2 段にする
    case centeredRow
    /// 2 段（iPhone・iPad の縦向き）
    case twoRows
}

/// 操作部の絵（文字の代わり。読み上げの名前は文字のまま）
enum ViewerControlsSymbol {
    /// 等速のときの速さのメニュー（ほかの速さのときは「1.5倍」の文字）
    static let rate = "gauge.with.dots.needle.67percent"
    /// 音声の切り替え（絵の横に「1/2」）
    static let audio = "waveform"
}

/// 映像の下に重ねる操作部（iPhone・iPad・macOS で同じ形。2026-11-23）。
/// 中央に置く 1 段の形（横長の画面）：左に速さ〜ミュート、中央に再生の操作（ライブは局のメニュー）、右端に時刻（ライブは一時停止）。
/// 2 段の形（縦長の画面と、1 段に入らない幅）：時刻を位置のつまみの両端に、1 段目に再生の操作を中央に大きく、2 段目に残りを等間隔に並べる（ボタンは減らさない）
struct ViewerControls: View {
    let playback: PlaybackController
    let captions: CaptionOverlayModel
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.viewerControlsStyle) private var style
    @Environment(\.viewerControlsSafeArea) private var safeArea
    /// 位置のつまみを動かしている間の位置（離したら、そこへ飛ぶ）
    @State private var scrubbing: Double?
    /// 2 段の形の 1 段目の幅（2 段目をこの幅に並べる）
    @State private var firstRowWidth: CGFloat = 0
    /// 番組表にサブチャンネルも並べるか（ライブの局のメニューも従う）
    @AppStorage(GuideSettingsKey.showsSubchannels) private var showsSubchannels = false

    private var isLive: Bool { playback.kind == .live }
    private var twoRows: Bool { style == .twoRows }
    /// 操作部の左右の余白（ライブの 2 段の形は、両端の「ライブ」と一時停止が画面の端に寄りすぎたので広げる。2026-11-23）
    private var horizontalPadding: CGFloat {
        twoRows && isLive ? ViewerControlsMetrics.liveTwoRowsHorizontalPadding : ViewerControlsMetrics.horizontalPadding
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: ViewerOverlayTiming.refreshInterval)) { _ in
            Group {
                switch style {
                case .twoRows: twoRowBody
                // 1 段に入らない幅（真ん中の物と左右の組が重なる）では 2 段にする
                case .centeredRow: ViewThatFits(in: .horizontal) { centeredRowBody; twoRowBody }
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.white)
            .padding(.leading, max(horizontalPadding, safeArea.leading))
            .padding(.trailing, max(horizontalPadding, safeArea.trailing))
            .padding(.top, ViewerControlsMetrics.verticalPadding)
            // ホームインジケーターの上に置く（横向きで中央のボタンに線が重なった。2026-11-23）
            .padding(.bottom, max(ViewerControlsMetrics.verticalPadding, safeArea.bottom))
            .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
        }
    }

    /// 1 段で真ん中の物を中央に置く形（録画は再生の操作、ライブは局のメニュー）。左右の組を同じ幅にして、真ん中の物を画面の中央に置く
    private var centeredRowBody: some View {
        VStack(spacing: ViewerControlsMetrics.centeredRowGap) {
            if !isLive, let duration = recordingDuration {
                positionSlider(duration: duration)
            }
            CenteredRow(spacing: ViewerControlsMetrics.rowSpacing) {
                HStack(spacing: ViewerControlsMetrics.rowSpacing) {
                    if isLive {
                        liveBadge
                    } else {
                        rateMenu
                    }
                    qualityMenu
                    audioButton
                    dualMonoMenu
                    captionsButton
                    muteButton
                    volumeSlider
                }
                if isLive {
                    if let live = environment.live {
                        LiveStationMenu(live: live, current: currentStation, showsSubchannels: showsSubchannels) { environment.playLive($0) }
                    } else {
                        Color.clear.frame(width: 0, height: 0)
                    }
                    playPauseButton
                } else {
                    transportControls
                    timeText
                }
            }
        }
    }

    /// 2 段の形
    private var twoRowBody: some View {
        VStack(spacing: ViewerControlsMetrics.rowGap) {
            if !isLive {
                if let duration = recordingDuration {
                    HStack(spacing: 8) {
                        Text(PlaybackTimeFormat.text(scrubbing ?? playback.displaySeconds))
                        positionSlider(duration: duration)
                        Text(PlaybackTimeFormat.text(playback.durationSeconds))
                    }
                    .font(.footnote)
                    .monospacedDigit()
                } else {
                    // 長さの分からない録画は、つまみを出さず時刻だけ
                    timeText.font(.footnote)
                }
            }
            Group {
                if isLive {
                    // 左端に「ライブ」の印、中央に局のメニュー（長い局名は 1 行で切る）、右端に一時停止
                    HStack(spacing: ViewerControlsMetrics.rowSpacing) {
                        liveBadge
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let live = environment.live {
                            LiveStationMenu(live: live, current: currentStation, showsSubchannels: showsSubchannels,
                                            truncatesTitle: true) { environment.playLive($0) }
                        }
                        playPauseButton
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    transportControls
                        .font(.title2)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { firstRowWidth = $0 }
            // 2 段目は 1 段目と同じ幅に、両端を揃えて等間隔に並べる（画面の幅いっぱいでは間延びした。2026-11-23）
            SpreadRow(width: firstRowWidth, minimumSpacing: ViewerControlsMetrics.secondRowMinimumSpacing) {
                if !isLive {
                    rateMenu
                }
                qualityMenu
                audioButton
                dualMonoMenu
                captionsButton
                muteButton
                volumeSlider
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 位置のつまみを出す録画の長さ（長さの分からない録画は nil）
    private var recordingDuration: Double? {
        guard let duration = playback.durationSeconds, duration > 0 else { return nil }
        return duration
    }

    /// 位置のつまみ。動かしている間は位置だけ変え、離したところで張り直す
    private func positionSlider(duration: Double) -> some View {
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

    /// 速さのメニュー（録画だけ）
    private var rateMenu: some View {
        RateMenu(rate: playback.playbackRate, canChange: playback.canChangeRate) { playback.setRate($0) }
    }

    /// 画質のメニュー（選べる画質が 2 つ以上のときだけ）
    @ViewBuilder private var qualityMenu: some View {
        let qualities = environment.qualityChoices
        if qualities.count > 1 {
            QualityMenu(choices: qualities, current: playback.currentResource) { environment.switchQuality(to: $0) }
                .disabled(playback.state.isStarting)
        }
    }

    /// 音声の切り替え（音声が 2 本以上のときだけ）。2 段の形は絵と「1/2」
    @ViewBuilder private var audioButton: some View {
        let audio = playback.engine.audioStatus
        if audio.tracks.count > 1 {
            let position = (audio.selectedIndex ?? 0) + 1
            Button {
                playback.cycleAudio()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: ViewerControlsSymbol.audio)
                    Text("\(position)/\(audio.tracks.count)").monospacedDigit()
                }
            }
            .disabled(playback.state.isStarting)
            .help("音声を切り替える（A）")
            .accessibilityLabel("音声 \(position) / \(audio.tracks.count)")
        }
    }

    /// 二重音声の主・副（二重音声のときだけ。2 段の形でも文字のまま）
    @ViewBuilder private var dualMonoMenu: some View {
        if playback.engine.audioStatus.layout == .dualMono {
            ViewerChoiceMenu(choices: DualMonoChannel.allCases.map { channel in
                ViewerChoice(id: DualMonoLabel.text(channel), title: DualMonoLabel.text(channel),
                             isSelected: channel == playback.dualMonoChannel) { playback.selectDualMono(channel) }
            }) {
                Text(DualMonoLabel.text(playback.dualMonoChannel))
            }
            .disabled(playback.state.isStarting)
            .help("二重音声の主・副を選ぶ")
        }
    }

    /// 字幕（字幕のある番組だけ）
    @ViewBuilder private var captionsButton: some View {
        if captions.isAvailable {
            Button { captions.isEnabled.toggle() } label: {
                Image(systemName: captions.isEnabled ? "captions.bubble.fill" : "captions.bubble")
            }
            .help(captions.isEnabled ? "字幕を消す（C）" : "字幕を出す（C）")
        }
    }

    /// アプリの中の音量のつまみ（macOS だけ。iPhone・iPad は端末の音量ボタンで変える）
    @ViewBuilder private var volumeSlider: some View {
        if ViewerControlsLayout.showsVolumeSlider {
            Slider(value: Binding(get: { Double(playback.volume) }, set: { playback.volume = Float($0) }), in: 0...1)
                .frame(width: ViewerControlsMetrics.volumeSliderWidth)
                .help("音量（⌘↑・⌘↓）")
        }
    }

    private var muteButton: some View {
        Button { playback.isMuted.toggle() } label: {
            Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .help("ミュート（M）")
    }

    /// 一時停止・再開（ライブは止める・今の放送から見直す）
    private var playPauseButton: some View {
        Button {
            playback.state == .paused ? playback.resume() : playback.pause()
        } label: {
            Image(systemName: playback.state == .paused ? "play.fill" : "pause.fill").frame(minWidth: 18)
        }
        .disabled(!(playback.state == .playing || playback.state == .paused || playback.state == .waiting))
        .help(isLive ? (playback.state == .paused ? "今の放送から見直す（スペース）" : "止める（スペース）") : "一時停止・再開（スペース）")
    }

    /// 再生の操作を中央に並べる形（2 段の 1 段目・横向き）：前のチャプター・10 秒戻る・一時停止・10 秒進む・次のチャプター
    private var transportControls: some View {
        HStack(spacing: twoRows ? ViewerControlsMetrics.transportSpacing : ViewerControlsMetrics.centeredTransportSpacing) {
            if hasChapters { previousChapterButton }
            backButton
            playPauseButton.font(twoRows ? .largeTitle : .title2)
            forwardButton
            if hasChapters { nextChapterButton }
        }
    }

    /// チャプターのある録画か（前後のチャプターのボタンを出す）
    private var hasChapters: Bool { !environment.chapters.isEmpty }

    private var previousChapterButton: some View {
        Button { environment.seekChapter(forward: false) } label: { Image(systemName: "backward.end.fill") }
            .disabled(!playback.canSeek)
            .help("前のチャプター（Shift + ←）")
    }

    private var nextChapterButton: some View {
        Button { environment.seekChapter(forward: true) } label: { Image(systemName: "forward.end.fill") }
            .disabled(!playback.canSeek)
            .help("次のチャプター（Shift + →）")
    }

    // 記号は 10 秒の形（SeekPolicy.skipSeconds を変えたら記号も合わせる。SF Symbols は 5・10・15・30 秒など）
    private var backButton: some View {
        Button { playback.skip(by: -SeekPolicy.skipSeconds) } label: { Image(systemName: "gobackward.10") }
            .disabled(!playback.canSeek)
            .help("\(Int(SeekPolicy.skipSeconds)) 秒戻る（←）")
    }

    private var forwardButton: some View {
        Button { playback.skip(by: SeekPolicy.skipSeconds) } label: { Image(systemName: "goforward.10") }
            .disabled(!playback.canSeek)
            .help("\(Int(SeekPolicy.skipSeconds)) 秒進む（→）")
    }

    /// 「0:00:00 / 0:00:00」
    private var timeText: some View {
        Text(PlaybackTimeFormat.text(scrubbing ?? playback.displaySeconds) + " / " + PlaybackTimeFormat.text(playback.durationSeconds))
            .monospacedDigit()
    }

    private var liveBadge: some View {
        Text("ライブ")
            .font(.caption.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }

    /// いま見ている局
    private var currentStation: LiveStationKey? {
        if case .live(let key) = environment.nowPlaying { return key }
        return nil
    }
}

/// 3 つを、真ん中の物が中央に来るように並べる（左の物は左端、右の物は右端）。
/// 要る幅は「左右の広いほう × 2 + 真ん中 + 間 × 2」（`ViewThatFits` はこの幅で入るかを見る）
struct CenteredRow: Layout {
    let spacing: CGFloat

    private func neededWidth(_ sizes: [CGSize]) -> CGFloat {
        guard sizes.count == 3 else { return sizes.reduce(0) { $0 + $1.width } }
        return max(sizes[0].width, sizes[2].width) * 2 + sizes[1].width + spacing * 2
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let needed = neededWidth(sizes)
        return CGSize(width: max(needed, proposal.width ?? needed), height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
    }
}

/// 決めた幅に、両端を揃えて等間隔に並べる（2 段の形の 2 段目）。
/// 中身が入りきらないときは、`minimumSpacing` の間で並べて幅を広げる（ボタンを減らさない）
struct SpreadRow: Layout {
    /// 並べる幅（0 なら中身と最小の間で決まる幅）
    let width: CGFloat
    let minimumSpacing: CGFloat

    private func naturalWidth(_ sizes: [CGSize]) -> CGFloat {
        sizes.reduce(0) { $0 + $1.width } + minimumSpacing * CGFloat(max(0, sizes.count - 1))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let height = sizes.map(\.height).max() ?? 0
        return CGSize(width: max(width, naturalWidth(sizes)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard !sizes.isEmpty else { return }
        let total = sizes.reduce(0) { $0 + $1.width }
        // 1 つだけなら中央に置く
        if sizes.count == 1 {
            subviews[0].place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
            return
        }
        let spacing = max(minimumSpacing, (bounds.width - total) / CGFloat(sizes.count - 1))
        var x = bounds.minX
        for (subview, size) in zip(subviews, sizes) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: .unspecified)
            x += size.width + spacing
        }
    }
}

extension View {
    /// 映像の上の小さな案内
    func viewerBadge() -> some View {
        padding(8).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(.white)
    }
}

/// 操作部の一覧の 1 項目（速さ・画質・二重音声・局）
struct ViewerChoice: Identifiable {
    let id: String
    let title: String
    let isSelected: Bool
    var isDisabled = false
    let action: () -> Void
}

/// 速さのメニュー（操作部。録画だけ。等速のときはメーターの絵、ほかの速さのときは今の速さを出す。2026-11-23）
struct RateMenu: View {
    let rate: Double
    /// 替えられるか（録画中の録画は等速だけ）
    let canChange: Bool
    let select: (Double) -> Void

    var body: some View {
        ViewerChoiceMenu(choices: PlaybackRatePolicy.rates.map { choice in
            ViewerChoice(id: PlaybackRatePolicy.label(choice), title: PlaybackRatePolicy.label(choice), isSelected: choice == rate) { select(choice) }
        }) {
            if rate == PlaybackRatePolicy.normal {
                Image(systemName: ViewerControlsSymbol.rate)
            } else {
                Text(PlaybackRatePolicy.label(rate))
            }
        }
        .accessibilityLabel(rate == PlaybackRatePolicy.normal ? "速度" : "速度 \(PlaybackRatePolicy.label(rate))")
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
        ViewerChoiceMenu(choices: choices.map { resource in
            ViewerChoice(id: resource.url, title: RecordingFormat.resourceQuality(resource.quality),
                         isSelected: resource.quality == current?.quality) { select(resource) }
        }) {
            Text(RecordingFormat.resourceQuality(current?.quality))
        }
        .help("画質を切り替える（Q）")
    }
}

/// ライブの局のメニュー（操作部の左。押すと局の一覧：リモコンキー・局名・放送中の番組名。2026-11-20 に決めた）
struct LiveStationMenu: View {
    let live: LiveModel
    let current: LiveStationKey?
    let showsSubchannels: Bool
    /// 見出しの局名を 1 行で切るか（狭い画面。切らなければ局名の幅いっぱいに出す）
    var truncatesTitle = false
    let select: (LiveStation) -> Void
    /// 画面の幅が狭いときは、一覧を局名だけにする（放送中の番組名を添えると、狭い一覧では局名まで切れた。2026-11-23）
    @Environment(\.viewerIsNarrow) private var narrow

    var body: some View {
        let currentStation = current.flatMap { live.station($0) }
        let stations = Self.items(live.stations(showsSubchannels: showsSubchannels), current: currentStation)
        ViewerChoiceMenu(choices: stations.map { station in
            ViewerChoice(id: "\(station.key)", title: Self.itemText(station, program: narrow ? nil : live.programs[station.key]),
                         isSelected: station.key == current, isDisabled: station.unavailableReason != nil) { select(station) }
        }, truncatesLabel: truncatesTitle) {
            Text(currentStation.map(Self.title) ?? "局を選ぶ")
        }
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
