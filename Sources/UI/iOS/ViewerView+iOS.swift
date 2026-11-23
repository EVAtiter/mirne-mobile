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
    /// 画面の大きさ（幅はダブルタップが左右のどちらかを決める。縦横の比で操作部の並べ方を決める）
    @State private var size: CGSize = .zero
    /// 画面の端の安全領域（再生の画面は端まで広げるので、操作部のボタンの並びだけをこの内側に置く。
    /// 左上の × は重ねる側で安全領域の内側に置かれる）
    @State private var safeArea = EdgeInsets()
    @FocusState private var focused: Bool

    /// 画面の幅が狭いか（局の一覧を局名だけにする幅）
    private var isNarrow: Bool { size.width > 0 && size.width < ViewerNarrowLayout.width }

    /// 操作部の並べ方（iPhone と iPad で同じ。2026-11-23）：縦長の画面（縦向き）は 2 段、横長の画面（横向き）は真ん中の物を中央に置く 1 段
    private var controlsStyle: ViewerControlsStyle {
        size.width < size.height ? .twoRows : .centeredRow
    }

    var body: some View {
        let playback = environment.playback
        let media = environment.mediaPlayback
        ViewerContent(overlay: overlay)
            .environment(\.viewerControlsStyle, controlsStyle)
            .environment(\.viewerIsNarrow, isNarrow)
            .environment(\.viewerControlsSafeArea, safeArea)
            // 安全領域は、端まで広げる前の器で測る（ViewerStage の中は安全領域を無視している）
            .background {
                Color.clear.onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { safeArea = $0 }
            }
            .overlay(alignment: .topLeading) {
                // メディアは OS の標準の再生画面の操作部が出し入れするので、閉じるはいつも出す
                if media != nil || overlay.controlsShown(playback.state) {
                    closeButton.transition(.opacity)
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .contentShape(Rectangle())
            // ダブルタップ（録画だけ）：左半分で戻る・右半分で進む。1 回のタップは、ダブルタップでないと分かってから出し入れする。
            // メディアのタップは OS の標準の再生画面に任せる
            .onTapGesture(count: 2, coordinateSpace: .local) { location in if media == nil { skip(at: location) } }
            .onTapGesture {
                guard media == nil else { return }
                if overlay.isVisible { overlay.hide(after: .zero) } else { overlay.show() }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(keys: ViewerKeys.all) { press in
                guard media == nil else { return .ignored }
                let result = ViewerBehavior.handle(press, environment: environment, window: nil)
                if result == .handled { overlay.show() }
                return result
            }
            .statusBarHidden()
            .persistentSystemOverlays(media != nil || overlay.controlsShown(playback.state) ? .automatic : .hidden)
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
        guard playback.kind != .live, playback.canSeek, size.width > 0 else { return }
        playback.skip(by: location.x < size.width / 2 ? -SeekPolicy.skipSeconds : SeekPolicy.skipSeconds)
        overlay.show()
    }
}

/// 左上の「閉じる」の寸法（体感の値。画面で見て決める）
enum ViewerCloseButtonLayout {
    static let size: CGFloat = 40
    static let margin: CGFloat = 20
    static let backgroundOpacity: Double = 0.5
}

/// 画面が狭いかの境目（iPhone の縦向きは狭い・横向きと iPad は広い。体感の値）
enum ViewerNarrowLayout {
    static let width: CGFloat = 600
}

/// 操作部の並び（iPad 版）
enum ViewerControlsLayout {
    /// アプリの中の音量のつまみを出すか（iPad は端末の音量ボタンで変えるので出さない。ミュートは残す）
    static let showsVolumeSlider = false
}

/// 操作部の一覧（iOS 版：自前の吹き出し）。OS のメニューは、開いている間に操作部が隠れると一緒に消えた（2026-11-23）。
/// 吹き出しなら開いているかが分かるので、開いている間は操作部を隠さない。幅も中身に合わせられる（OS のメニューは iPad でも狭かった）
struct ViewerChoiceMenu<Label: View>: View {
    let choices: [ViewerChoice]
    /// 見出しを 1 行で切るか（切らなければ見出しの幅いっぱいに出す）
    var truncatesLabel = false
    @ViewBuilder let label: () -> Label
    @Environment(\.viewerOverlay) private var overlay
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: { label() }
            .lineLimit(1)
            .fixedSize(horizontal: !truncatesLabel, vertical: true)
            .popover(isPresented: $isPresented) {
                ViewerChoiceList(choices: choices) { isPresented = false }
                    // 暗い操作部に合わせて暗い地と外観で描く（既定の地は灰色で、白い文字が読みにくかった）
                    .environment(\.colorScheme, .dark)
                    .presentationBackground(ViewerChoiceLayout.background)
                    // iPhone でもシートにせず吹き出しで出す
                    .presentationCompactAdaptation(.popover)
            }
            .onChange(of: isPresented) { _, shown in
                if shown { overlay?.hold() } else { overlay?.release() }
            }
    }
}

/// 吹き出しの中の一覧（選んでいる項目に印。押したら選んで閉じる）
private struct ViewerChoiceList: View {
    let choices: [ViewerChoice]
    let dismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                    if index > 0 { Divider() }
                    Button {
                        choice.action()
                        dismiss()
                    } label: {
                        HStack(spacing: ViewerChoiceLayout.checkmarkSpacing) {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .opacity(choice.isSelected ? 1 : 0)
                            Text(choice.title).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, ViewerChoiceLayout.horizontalPadding)
                        .padding(.vertical, ViewerChoiceLayout.verticalPadding)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(choice.isDisabled ? .secondary : .primary)
                    .disabled(choice.isDisabled)
                }
            }
        }
        .scrollFitsContentHeight(maxHeight: ViewerChoiceLayout.maxHeight)
        .modifier(CappedIdealWidth(maxWidth: ViewerChoiceLayout.maxWidth))
    }
}

/// 吹き出しの一覧の寸法（体感の値。画面で見て決める）
enum ViewerChoiceLayout {
    /// 一覧の幅の上限（局名と放送中の番組名が 1 行に入る幅。画面より広いときは OS が詰める）
    static let maxWidth: CGFloat = 440
    /// 一覧の高さの上限（越えたらスクロール）
    static let maxHeight: CGFloat = 480
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 11
    static let checkmarkSpacing: CGFloat = 10
    /// 吹き出しの地（暗い操作部に合わせる）
    static let background = Color(white: 0.16)
}

/// 幅を中身の幅（上限つき）にする（吹き出しは中身の幅で開くので、長い行で画面いっぱいに広がらないようにする）
private struct CappedIdealWidth: ViewModifier {
    let maxWidth: CGFloat
    @State private var idealWidth: CGFloat?

    func body(content: Content) -> some View {
        content
            .background {
                // 中身の本来の幅を、上限なしで測る（見えない写しで測る）
                content.fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { idealWidth = $0 }
            }
            .frame(width: idealWidth.map { min($0, maxWidth) })
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
