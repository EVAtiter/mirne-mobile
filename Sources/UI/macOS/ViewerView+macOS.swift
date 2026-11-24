import AppKit
import os
import SwiftUI

/// 視聴ウィンドウ（macOS 版）：映像だけを出し、マウスを動かすと操作部を重ねて出す。16:9 を保ってリサイズし、全画面にできる。
/// キー操作は `ViewerBehavior.handle` のほか、F で全画面、T で常に最前面、⌘0 で標準の大きさ。
/// キーはこの窓が前面のときだけ受ける（主ウィンドウの検索欄で打った文字で効かないように）。
/// 全画面にできるのは、場面に `.windowFullScreenBehavior(.enabled)` を付けているから（MirneMobileApp。2026-11-19）
struct ViewerView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var overlay = ViewerOverlayState()
    @State private var window: NSWindow?
    /// 左上の窓のボタン（閉じる）の真ん中の、窓の上端からの高さ（右上の全画面のボタンをこの高さに揃える）
    @State private var windowButtonCenterY: CGFloat?
    @FocusState private var focused: Bool
    private let logger = Logger(subsystem: AppLog.subsystem, category: "ui")

    var body: some View {
        let playback = environment.playback
        let media = environment.mediaPlayback
        ViewerContent(overlay: overlay)
            // 全画面のボタンは右上の角（左上の窓のボタンと同じく、操作部と一緒に出し入れする。2026-11-23）。
            // メディアは窓のボタンと同じくいつも出す（OS の標準の再生画面は、SwiftUI の窓を全画面に入れない窓と見て、
            // 全画面のボタンを出さなかった。2026-11-24）
            .overlay(alignment: .topTrailing) {
                if media != nil || overlay.controlsShown(playback.state) {
                    fullScreenButton.transition(.opacity)
                }
            }
            .background(WindowAccessor(beforeShown: { environment.viewerWindow.conceal($0) }) { configure($0) })
            .onChange(of: windowButtonsVisible) { _, shown in setWindowButtons(visible: shown) }
            // 操作部を隠したら、全画面では、マウスを動かすまでカーソルも隠す
            .onChange(of: overlay.isVisible) { _, visible in
                if !visible, window?.styleMask.contains(.fullScreen) == true { NSCursor.setHiddenUntilMouseMoves(true) }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active: overlay.show()
                case .ended: overlay.hide(after: .zero)
                }
            }
            .onTapGesture(count: 2) { if media == nil { toggleFullScreen() } }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            // 文字だけのキーのメニューの項目は、視聴ウインドウが前にあるときだけ有効
            .focusedSceneValue(\.viewerIsKey, true)
            // Esc で全画面を抜ける（全画面でないときは何もしない。2026-11-23）
            .onKeyPress(.escape) {
                guard window?.styleMask.contains(.fullScreen) == true else { return .ignored }
                toggleFullScreen()
                return .handled
            }
            .onKeyPress(keys: ViewerKeys.all) { press in
                // メディアのキーは OS の標準の再生画面に任せる。全画面（F）だけはこちらで受ける（2026-11-24）
                if media != nil {
                    guard press.characters == ViewerKeys.fullScreen, press.modifiers.isEmpty else { return .ignored }
                    toggleFullScreen()
                    return .handled
                }
                let result = ViewerBehavior.handle(press, environment: environment, window: windowActions)
                if result == .handled { overlay.show() }
                return result
            }
            .onAppear {
                focused = true
                overlay.show()
            }
            .onDisappear {
                overlay.cancel()
                environment.displaySleep.update(ViewerWindowID.main, blocking: false)
                environment.endViewing()
            }
            .task { await ViewerBehavior.watchDisplaySleep(environment) { window?.isMiniaturized == true } }
    }

    /// 窓の左上のボタン（閉じるなど）を出すか：録画・ライブは操作部と一緒に出し入れし、メディアはいつも出す
    private var windowButtonsVisible: Bool {
        environment.mediaPlayback != nil || overlay.controlsShown(environment.playback.state)
    }

    /// 窓の操作（キー操作から）
    private var windowActions: ViewerBehavior.WindowActions {
        ViewerBehavior.WindowActions(toggleFullScreen: toggleFullScreen,
                                     toggleAlwaysOnTop: { environment.viewerWindow.toggleAlwaysOnTop() },
                                     resetSize: { environment.viewerWindow.resetSize() })
    }

    /// 右上の角の全画面のボタン
    private var fullScreenButton: some View {
        Button(action: toggleFullScreen) {
            Image(systemName: window?.styleMask.contains(.fullScreen) == true
                  ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: ViewerFullScreenButtonLayout.size, height: ViewerFullScreenButtonLayout.size)
                .background(.black.opacity(ViewerFullScreenButtonLayout.backgroundOpacity), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("フルスクリーン")
        .help("フルスクリーン（F）")
        .padding(.top, max(0, (windowButtonCenterY ?? ViewerFullScreenButtonLayout.fallbackCenterY) - ViewerFullScreenButtonLayout.size / 2))
        .padding(.trailing, ViewerFullScreenButtonLayout.trailingPadding)
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
        setWindowButtons(visible: windowButtonsVisible)
        windowButtonCenterY = Self.windowButtonCenterY(window)
    }

    /// 左上の閉じるボタンの真ん中の、中身の上端からの高さ（測れなければ nil）
    static func windowButtonCenterY(_ window: NSWindow) -> CGFloat? {
        guard let button = window.standardWindowButton(.closeButton), let content = window.contentView else { return nil }
        let frame = button.convert(button.bounds, to: content)
        return content.isFlipped ? frame.midY : content.bounds.height - frame.midY
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
}

/// 右上の角の全画面のボタンの寸法（体感の値。画面で見て決める）。
/// 高さは左上の窓のボタンの真ん中に揃える（測った値。6pt の決め打ちでは下がって見えた。2026-11-23）
enum ViewerFullScreenButtonLayout {
    static let size: CGFloat = 28
    /// 窓のボタンの位置を測れないときの、真ん中の高さ
    static let fallbackCenterY: CGFloat = 16
    static let trailingPadding: CGFloat = 10
    static let backgroundOpacity: Double = 0.5
}

/// 操作部の並び（macOS 版）
enum ViewerControlsLayout {
    /// アプリの中の音量のつまみを出すか
    static let showsVolumeSlider = true
}

/// 操作部の一覧（macOS 版：ふつうのメニュー。枠の無いボタンで、押すと AppKit のメニューが開く）
struct ViewerChoiceMenu<Label: View>: View {
    let choices: [ViewerChoice]
    /// 見出しを 1 行で切るか（切らなければ見出しの幅いっぱいに出す）
    var truncatesLabel = false
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            ForEach(choices) { choice in
                Button(action: choice.action) {
                    if choice.isSelected { SwiftUI.Label(choice.title, systemImage: "checkmark") } else { Text(choice.title) }
                }
                .disabled(choice.isDisabled)
            }
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        // Menu は AppKit が描くので foregroundStyle(.white) が効かず、明るい外観では黒い文字になって
        // 暗い操作部の上で見えなかった（2026-11-20）。暗い外観で描く
        .environment(\.colorScheme, .dark)
        .lineLimit(1)
        .fixedSize(horizontal: !truncatesLabel, vertical: true)
    }
}

/// VideoRenderer のビューを SwiftUI に置く（macOS 版）
struct VideoSurface: NSViewRepresentable {
    let renderer: VideoRenderer

    func makeNSView(context: Context) -> VideoLayerView { renderer.view }
    func updateNSView(_ nsView: VideoLayerView, context: Context) {}
}

/// SwiftUI の画面から、それを載せている NSWindow を受け取る（mirne の WindowAccessor と同じ）。
/// `beforeShown` は窓に載ったその場で呼ぶ（窓が画面に出る前。SwiftUI の状態は書き換えないこと。窓を透明にするのに使う）
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

/// チャプターの印を合わせる、位置のつまみの溝の両端の内側の幅（macOS 版：小さいつまみの半分。体感の値）
enum ChapterMarkPlatform {
    static let trackInset: CGFloat = 7
}
