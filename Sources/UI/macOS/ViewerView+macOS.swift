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
    @FocusState private var focused: Bool
    private let logger = Logger(subsystem: AppLog.subsystem, category: "ui")

    var body: some View {
        let playback = environment.playback
        ViewerStage(overlay: overlay) { fullScreenButton }
            .background(WindowAccessor(beforeShown: { environment.viewerWindow.conceal($0) }) { configure($0) })
            .onChange(of: overlay.controlsShown(playback.state)) { _, shown in setWindowButtons(visible: shown) }
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
            .onTapGesture(count: 2) { toggleFullScreen() }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            // 文字だけのキーのメニューの項目は、視聴ウインドウが前にあるときだけ有効
            .focusedSceneValue(\.viewerIsKey, true)
            .onKeyPress(keys: ViewerKeys.all) { press in
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

    /// 窓の操作（キー操作から）
    private var windowActions: ViewerBehavior.WindowActions {
        ViewerBehavior.WindowActions(toggleFullScreen: toggleFullScreen,
                                     toggleAlwaysOnTop: { environment.viewerWindow.toggleAlwaysOnTop() },
                                     resetSize: { environment.viewerWindow.resetSize() })
    }

    /// 操作部の右端の全画面のボタン
    private var fullScreenButton: some View {
        Button(action: toggleFullScreen) {
            Image(systemName: window?.styleMask.contains(.fullScreen) == true
                  ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        .help("フルスクリーン（F）")
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
        setWindowButtons(visible: overlay.controlsShown(environment.playback.state))
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

/// 操作部の並び（macOS 版）
enum ViewerControlsLayout {
    /// アプリの中の音量のつまみを出すか
    static let showsVolumeSlider = true
}

extension View {
    /// 操作部のメニューの形（macOS 版：枠の無いボタン）
    func viewerMenuStyle() -> some View {
        menuStyle(.borderlessButton)
    }
}

/// VideoRenderer のビューを SwiftUI に置く（macOS 版）
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

/// チャプターの印を合わせる、位置のつまみの溝の両端の内側の幅（macOS 版：小さいつまみの半分。体感の値）
enum ChapterMarkPlatform {
    static let trackInset: CGFloat = 7
}
