import AppKit
import Observation
import os

/// 視聴ウィンドウの窓を受け持つ（標準の大きさに戻す：常に最前面：位置と大きさの保存と復元）。
///
/// `AppEnvironment` が持ち、視聴ウィンドウが開いたときに NSWindow を受け取る。メニューからも届くように、
/// 画面（ViewerView）ではなくここに置く。いまは ⌘0 のキー（ViewerView）だけが呼ぶ。
/// mirne の `ViewerWindowController.resetSize` に倣う。mirne は映像の横にサイドバーとツールバーがあるので、
/// 映像の幅から窓の大きさを出すが、こちらは映像のほかの部分が無い（タイトルバーも映像に重ねている）ので、内容の大きさを当てるだけ
@MainActor
@Observable
final class ViewerWindowController {
    /// 常に最前面（選んだ状態は保存して、次に開いたとき・起動し直したときも引き継ぐ。2026-11-20 に決めた）。
    /// 全画面の間は効かせない（mirne の `isAlwaysOnTop` と同じ）
    var isAlwaysOnTop = UserDefaults.standard.bool(forKey: ViewerSettingsKey.alwaysOnTop) {
        didSet {
            UserDefaults.standard.set(isAlwaysOnTop, forKey: ViewerSettingsKey.alwaysOnTop)
            applyLevel()
            logger.info("常に最前面: \(self.isAlwaysOnTop, privacy: .public)")
        }
    }
    /// 全画面か（全画面に入り始めたときから、出終わるまで。mirne と同じ区切り）
    private(set) var isFullScreen = false

    /// 視聴ウィンドウ（閉じたら SwiftUI が手放すので弱く持つ）
    @ObservationIgnored private weak var window: NSWindow?
    /// 全画面の出入りの知らせ（窓を受け取り直したら付け替える）
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let logger = Logger(subsystem: AppLog.subsystem, category: "window")
    /// 位置と大きさの保存と復元（16:9 を保って戻す）
    @ObservationIgnored private let placement = WindowPlacementController(
        key: WindowPlacementKey.viewer, name: "視聴ウインドウ",
        minimumSize: ViewerLayout.minimumSize, aspectRatio: ViewerLayout.aspectRatio, remembersSizeAsUser: true)

    /// 視聴ウィンドウを受け取る（開くたびに呼ばれる）
    func attach(_ window: NSWindow) {
        if self.window !== window || observers.isEmpty {
            self.window = window
            observe(window)
        }
        isFullScreen = window.styleMask.contains(.fullScreen)
        applyLevel()
        placement.attach(window)
    }

    /// 窓が画面に出る前に透明にする（位置と大きさを戻すまで見せない）
    func conceal(_ window: NSWindow) {
        placement.conceal(window)
    }

    /// 常に最前面を切り替える（T キー。全画面の間は切り替えない。mirne はメニューの項目を無効にしている）
    func toggleAlwaysOnTop() {
        guard !isFullScreen else { return }
        isAlwaysOnTop.toggle()
    }

    /// 標準の大きさに戻せるか（窓が開いていて、全画面でない）
    var canResetSize: Bool {
        guard let window else { return false }
        return !window.styleMask.contains(.fullScreen)
    }

    /// 窓の層を当てる（常に最前面で、全画面でなければ floating。mirne の `applyLevel` と同じ）
    private func applyLevel() {
        window?.level = ViewerWindowLevel.floats(alwaysOnTop: isAlwaysOnTop, fullScreen: isFullScreen) ? .floating : .normal
    }

    /// 全画面の出入りを見る。入るときは入り始めに層を戻し、出るときは出終わってから最前面に戻す（mirne と同じ）
    private func observe(_ window: NSWindow) {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers = [
            center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setFullScreen(true) }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setFullScreen(false) }
            },
            // SwiftUI は窓を「補助の窓」にして、表示のメニューの「フルスクリーンにする」を無効にする。
            // 前に出たたびに主の窓へ書き換え、メニューから全画面に入れるようにする
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let window = self?.window { ViewerView.allowFullScreen(window) }
                }
            },
        ]
    }

    private func setFullScreen(_ value: Bool) {
        isFullScreen = value
        applyLevel()
    }

    /// 標準の大きさに戻す：映像を `ViewerLayout.defaultSize` にし、窓の左上は動かさない（はみ出すなら引き戻す。2026-11-20 に中心から改めた）。
    /// 動きは付けない。全画面の間は何もしない
    func resetSize() {
        guard let window, canResetSize else { return }
        let size = window.frameRect(forContentRect: CGRect(origin: .zero, size: ViewerLayout.defaultSize)).size
        let topLeft = CGPoint(x: window.frame.minX, y: window.frame.maxY)
        let origin = ViewerWindowPositioning.origin(keepingTopLeft: topLeft, size: size)
        let anchor = (window.screen ?? NSScreen.primary())?.visibleFrame
        let resolved = ViewerWindowPositioning.resolvedOrigin(origin, windowSize: size,
                                                              visibleFrames: NSScreen.screens.map(\.visibleFrame),
                                                              anchor: anchor) ?? origin
        // AppKit に利用者が決めた大きさとして覚えさせる（setFrame だと、ほかの画面へ移したときに前に手で決めた大きさへ戻る）
        window.setFrameAsUserSize(CGRect(origin: resolved, size: size))
        logger.info("標準の大きさに戻した: \(size.width, privacy: .public)×\(size.height, privacy: .public)")
        // 人の操作で大きさを変えたので保存する（自分で動かした移動は、知らせが来ても保存しないことがあるため明示する）
        placement.saveNow()
    }
}
