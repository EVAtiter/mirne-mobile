import AVFAudio
import os
import SwiftUI
import UIKit

/// 再生の画面（iPad 版）：主画面の上に全画面で重ねる。タップで操作部を出し入れし、左上の「閉じる」で主画面へ戻る（再生を終える）。
/// 録画では、画面の左半分のダブルタップで 10 秒戻る・右半分で 10 秒進む。
/// ハードウェアキーボードのキーは macOS と同じ（全画面・常に最前面・標準の大きさは無い）
struct ViewerView: View {
    @Environment(AppEnvironment.self) private var environment
    /// 閉じる（主画面へ戻る）
    let close: () -> Void
    @State private var overlay = ViewerOverlayState()
    /// 画面の幅（ダブルタップが左右のどちらかを決める）
    @State private var width: CGFloat = 0
    @FocusState private var focused: Bool

    var body: some View {
        let playback = environment.playback
        ViewerStage(overlay: overlay) { EmptyView() }
            .overlay(alignment: .topLeading) {
                if overlay.controlsShown(playback.state) {
                    closeButton.transition(.opacity)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .contentShape(Rectangle())
            // ダブルタップ（録画だけ）：左半分で戻る・右半分で進む。1 回のタップは、ダブルタップでないと分かってから出し入れする
            .onTapGesture(count: 2, coordinateSpace: .local) { location in skip(at: location) }
            .onTapGesture {
                if overlay.isVisible { overlay.hide(after: .zero) } else { overlay.show() }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(keys: ViewerKeys.all) { press in
                let result = ViewerBehavior.handle(press, environment: environment, window: nil)
                if result == .handled { overlay.show() }
                return result
            }
            .statusBarHidden()
            .persistentSystemOverlays(overlay.controlsShown(playback.state) ? .automatic : .hidden)
            // 主画面の文字の大きさは配らない（macOS の視聴ウィンドウと同じ）
            .font(.body)
            .controlSize(.regular)
            .onAppear {
                focused = true
                overlay.show()
                PlaybackAudioSession.activate()
            }
            .onDisappear {
                overlay.cancel()
                environment.displaySleep.update(ViewerWindowID.main, blocking: false)
                environment.endViewing()
                PlaybackAudioSession.deactivate()
            }
            .task { await ViewerBehavior.watchDisplaySleep(environment) { false } }
    }

    /// 左上の「閉じる」（操作部と一緒に出し入れする）
    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: ViewerCloseButtonLayout.size, height: ViewerCloseButtonLayout.size)
                .background(.black.opacity(ViewerCloseButtonLayout.backgroundOpacity), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("閉じる")
        .padding(ViewerCloseButtonLayout.margin)
    }

    /// ダブルタップで 10 秒戻る・進む（録画で、位置を変えられるときだけ）
    private func skip(at location: CGPoint) {
        let playback = environment.playback
        guard playback.kind != .live, playback.canSeek, width > 0 else { return }
        playback.skip(by: location.x < width / 2 ? -SeekPolicy.skipSeconds : SeekPolicy.skipSeconds)
        overlay.show()
    }
}

/// 左上の「閉じる」の寸法（体感の値。画面で見て決める）
enum ViewerCloseButtonLayout {
    static let size: CGFloat = 40
    static let margin: CGFloat = 20
    static let backgroundOpacity: Double = 0.5
}

/// 操作部の並び（iPad 版）
enum ViewerControlsLayout {
    /// アプリの中の音量のつまみを出すか（iPad は端末の音量ボタンで変えるので出さない。ミュートは残す）
    static let showsVolumeSlider = false
}

extension View {
    /// 操作部のメニューの形（iPad 版：既定。操作部の `buttonStyle(.borderless)` で文字のボタンになる）
    func viewerMenuStyle() -> some View {
        self
    }
}

/// VideoRenderer のビューを SwiftUI に置く（iPad 版）。タップは SwiftUI の側で受ける
struct VideoSurface: UIViewRepresentable {
    let renderer: VideoRenderer

    func makeUIView(context: Context) -> VideoLayerView {
        let view = renderer.view
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: VideoLayerView, context: Context) {}
}

/// 再生の間の音の扱い（動画のアプリと同じ）：消音スイッチが入っていても鳴らし、ほかのアプリの音を止める。
/// 再生の画面を開いている間だけ有効にし、閉じたらほかのアプリへ音を返す
@MainActor
enum PlaybackAudioSession {
    private static let logger = Logger(subsystem: AppLog.subsystem, category: "playback")

    static func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            logger.info("音のセッションを有効にした")
        } catch let failure as NSError {
            // 誤りはコードだけ出す（音のセッションの誤りに nasne の値は入らない）
            logger.error("音のセッションを有効にできない：コード \(failure.code, privacy: .public)")
        }
    }

    static func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            logger.info("音のセッションを止めた")
        } catch let failure as NSError {
            logger.error("音のセッションを止められない：コード \(failure.code, privacy: .public)")
        }
    }
}

/// チャプターの印を合わせる、位置のつまみの溝の両端の内側の幅（iPad 版：つまみの半分。体感の値）
enum ChapterMarkPlatform {
    static let trackInset: CGFloat = 14
}
