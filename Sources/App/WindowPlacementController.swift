import AppKit
import os

/// 窓の位置と大きさを動かす時刻の決まり（mirne の `ViewerWindowTiming` と同じ値）
enum WindowPlacementTiming {
    /// 画面の構成が変わった・スリープから戻ったとき、最後の通知からこの時間たってから 1 回だけ置き直す。
    /// 通知の間隔は最大 1.1 秒ほど空く（mirne の参照実装の実測）ので、0.5 秒では通知が続いている途中で動かしてしまう
    static let repositionDebounce: Duration = .milliseconds(1500)
    /// 開いたとき、窓が画面に出るのを待つ間隔と回数（合わせて 2 秒まで）
    static let restoreWaitInterval: Duration = .milliseconds(50)
    static let restoreWaitAttempts = 40
    /// 復元するまで窓を透明にしておくが、復元できなかったときはこの時間で見せる（復元を待つ 2 秒より長く）
    static let revealFallback: Duration = .seconds(3)
}

/// 窓の位置と大きさの保存の鍵（設定に JSON で書く）
enum WindowPlacementKey {
    /// 主ウインドウ
    static let main = "mainWindowPlacement"
    /// 視聴ウインドウ（mirne と同じ鍵の名前。中身の形は違う）
    static let viewer = "viewerWindowPlacement"
}

extension NSScreen {
    /// 画面の永続的な UUID（`CGDirectDisplayID` は接続の順などで変わるので保存には使わない。mirne と同じ）
    var displayUUID: String? {
        guard let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, uuid.takeRetainedValue()) as String?
    }

    static func screen(forUUID uuid: String) -> NSScreen? {
        screens.first { $0.displayUUID == uuid }
    }

    /// プライマリの画面（原点が (0,0) の画面）。`NSScreen.main` はキーウィンドウのある画面なので使わない（mirne と同じ）
    static func primary() -> NSScreen? {
        screens.first { $0.frame.origin == .zero } ?? screens.first
    }
}

/// 窓の位置と大きさの保存と復元。主ウインドウと視聴ウインドウが 1 つずつ持つ。
///
/// mirne の `GuideWindowController`（Sources/mirne/GuideWindow.swift）を写した。決まりは mirne の視聴ウィンドウ・番組表のウィンドウと同じ:
/// - 保存するのは人が窓を動かした・大きさを変えたときだけ（画面の構成が変わっている間・自分で動かしたとき・全画面の間は保存しない）
/// - 画面の構成の変化・スリープからの復帰では、最後の通知から 1.5 秒たってから 1 回だけ置き直す
/// - 画面外の救済は「十分見えているか」で判定する（`ViewerWindowPositioning.resolvedOrigin`）
///
/// SwiftUI の自動保存（"NSWindow Frame main" など）は、mirne で開き直した窓に当たらないこと・外部画面の記録を別の画面の幅で当てることがあったので止める。
/// 保存が無いとき（初めて・前の版から）は、自動保存の記録があれば自分で当てて引き継ぐ。窓は復元するまで透明にしておく
@MainActor
final class WindowPlacementController {
    private let key: String
    /// ログに出す窓の名前（主ウインドウ・視聴ウインドウ）
    private let name: String
    /// これより小さい大きさは戻さない（保存が壊れていても、使える大きさで開く）
    private let minimumSize: CGSize
    /// 戻すときに保つ縦横比（視聴ウインドウの 16:9。主ウインドウは nil）
    private let aspectRatio: CGSize?
    private let logger: Logger

    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var restored = false
    private var restoreTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private var repositionTask: Task<Void, Never>?
    /// 窓を閉じたか（開き直したら復元し直す）
    private var closed = false
    /// 自分で窓を動かしている間（そのときの移動は保存しない）
    private var applyingFrame = false
    /// 画面の構成が変わっている間・スリープの前後
    private var reconfiguring = false
    private var isFullScreen = false
    /// 保存した位置と大きさの写し（窓を動かしている間、移動の知らせのたびに設定から JSON を読み直さない）
    private var placementCache: WindowPlacement??

    init(key: String, name: String, minimumSize: CGSize, aspectRatio: CGSize? = nil) {
        self.key = key
        self.name = name
        self.minimumSize = minimumSize
        self.aspectRatio = aspectRatio
        logger = Logger(subsystem: AppLog.subsystem, category: "window")
    }

    /// 保存した位置と大きさ（設定を読むのは最初の 1 回だけ。書くときは写しと設定の両方へ）
    private var storedPlacement: WindowPlacement? {
        get {
            if let placementCache { return placementCache }
            let loaded = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(WindowPlacement.self, from: $0) }
            placementCache = .some(loaded)
            return loaded
        }
        set {
            placementCache = .some(newValue)
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// 窓が決まった（開き直したときも呼ばれる）
    func attach(_ window: NSWindow) {
        guard window !== self.window || closed else { return }
        if window !== self.window {
            self.window = window
            observe(window)
        }
        closed = false
        restored = false
        restoreTask?.cancel()
        restoreTask = nil
        isFullScreen = window.styleMask.contains(.fullScreen)
        hideUntilRestored(window)
        scheduleRestore(window)
    }

    /// 窓が画面に出る前に透明にする（`WindowAccessor` が窓に載ったその場で呼ぶ）。
    /// `attach` は次の回に呼ばれるので、そこで透明にすると、SwiftUI が最小の大きさで出した窓が一瞬見えてから消えた（2026-11-21）。
    /// 復元しない窓（もう受け取って開いている窓）には触らない。見せるのは `attach` からの復元か、時間切れの見張り
    func conceal(_ window: NSWindow) {
        guard window !== self.window || closed else { return }
        // 窓に載った時点で、窓がもう画面に出ていたか（出ていれば、透明にする前に一瞬見えている）
        logger.debug("\(self.name, privacy: .public)：透明にした: 画面に出ていた \(window.isVisible, privacy: .public)")
        window.alphaValue = 0
    }

    /// 今の位置と大きさを保存する（標準の大きさに戻したときなど、人の操作で自分が窓を動かしたとき）
    func saveNow() {
        save(userInitiated: true)
    }

    // MARK: - 復元と保存

    /// 窓が画面に出て、SwiftUI が位置と大きさを当て終えてから復元する（mirne と同じ時機）
    private func scheduleRestore(_ window: NSWindow) {
        restoreTask = Task { [weak self, weak window] in
            for _ in 0..<WindowPlacementTiming.restoreWaitAttempts {
                guard let window, !window.isVisible else { break }
                try? await Task.sleep(for: WindowPlacementTiming.restoreWaitInterval)
            }
            try? await Task.sleep(for: WindowPlacementTiming.restoreWaitInterval)
            guard !Task.isCancelled, let self, let window, !self.restored else { return }
            self.restore(window)
        }
    }

    private func restore(_ window: NSWindow) {
        restored = true
        // SwiftUI の自動保存を止め、残っている記録も消す（止めても記録は残り、窓が記録の画面へ入ったときに SwiftUI がその大きさを当て直す。mirne の実測）
        let autosaveName = window.frameAutosaveName
        let autosaveKey = "NSWindow Frame \(autosaveName)"
        let autosavedFrame = autosaveName.isEmpty ? nil : UserDefaults.standard.string(forKey: autosaveKey)
        window.setFrameAutosaveName("")
        if !autosaveName.isEmpty {
            UserDefaults.standard.removeObject(forKey: autosaveKey)
        }
        if isFullScreen {
            // 全画面のまま開いた（macOS の窓の復元）：位置は触らず、全画面を出たときの位置から保存を始める
            reveal(window)
            return
        }
        guard let placement = storedPlacement else {
            // 保存が無い（初めて・前の版から）：自動保存の記録があれば自分で当てて引き継ぐ。
            // `setFrame(from:)` は記録を今の画面に合わせて置き直した（mirne で、外部画面の記録が別の画面の幅で当たった）ので、
            // 位置と大きさを取り出して自分で当てる
            guard let autosaved = autosavedFrame.flatMap(WindowPlacement.frame(fromAutosave:)) else {
                logger.info("\(self.name, privacy: .public)：保存が無いので開いた位置を引き継いだ")
                reveal(window)
                save(userInitiated: true)
                return
            }
            let anchor = NSScreen.screens.first { $0.frame.intersects(autosaved) } ?? NSScreen.primary()
            let origin = resolvedOrigin(autosaved.origin, size: autosaved.size, anchor: anchor)
            logger.info("\(self.name, privacy: .public)：前の版の自動保存の位置と大きさを引き継いだ")
            apply(CGRect(origin: origin, size: autosaved.size), to: window) { [weak self] in self?.save(userInitiated: true) }
            return
        }
        let size = placement.size(minimumSize: minimumSize, aspectRatio: aspectRatio)
        let target = placement.displayUUID.flatMap(NSScreen.screen(forUUID:))
        let base = (target ?? NSScreen.primary())?.frame ?? .zero
        let saved = placement.origin(on: base, size: size)
        let origin = resolvedOrigin(saved, size: size, anchor: target ?? NSScreen.primary())
        logger.info("\(self.name, privacy: .public)：位置を戻した: 保存先の画面 \(target == nil ? "なし（プライマリ基準）" : "あり", privacy: .public)・救済 \(origin == saved ? "なし" : "あり", privacy: .public)")
        apply(CGRect(origin: origin, size: size), to: window)
    }

    /// 位置と大きさを当て、次のランループで macOS に書き換えられていたら当て直してから見せる（SwiftUI の窓は、当てた直後に macOS が位置を書き換えることがある。mirne の実測）
    private func apply(_ frame: CGRect, to window: NSWindow, then completion: (() -> Void)? = nil) {
        setFrame(frame, on: window)
        Task { [weak self, weak window] in
            guard let self, let window else { return }
            if window.frame != frame, !self.isFullScreen {
                self.logger.info("\(self.name, privacy: .public)：復元した位置がずれたので当て直した")
                self.setFrame(frame, on: window)
            }
            self.reveal(window)
            completion?()
        }
    }

    /// 十分見えていればそのまま、足りなければ `anchor` の見える範囲へ引き戻した位置
    private func resolvedOrigin(_ origin: CGPoint, size: CGSize, anchor: NSScreen?) -> CGPoint {
        ViewerWindowPositioning.resolvedOrigin(origin, windowSize: size,
                                               visibleFrames: NSScreen.screens.map(\.visibleFrame),
                                               anchor: anchor?.visibleFrame) ?? origin
    }

    private func hideUntilRestored(_ window: NSWindow) {
        window.alphaValue = 0
        revealTask?.cancel()
        revealTask = Task { [weak self, weak window] in
            try? await Task.sleep(for: WindowPlacementTiming.revealFallback)
            guard !Task.isCancelled, let self, let window, window.alphaValue == 0 else { return }
            self.logger.info("\(self.name, privacy: .public)：復元できないまま時間がたったので窓を見せた")
            self.reveal(window)
        }
    }

    private func reveal(_ window: NSWindow) {
        revealTask?.cancel()
        revealTask = nil
        window.alphaValue = 1
    }

    /// 位置と大きさを保存する。`userInitiated` でなければ保存先の画面に触らず、保存先と違う画面にいるときは位置も捨てる
    private func save(userInitiated: Bool) {
        guard let window, restored, !closed, !isFullScreen, !reconfiguring,
              let screen = window.screen, let uuid = screen.displayUUID,
              let placement = WindowPlacement.updated(saved: storedPlacement, frame: window.frame, screenFrame: screen.frame,
                                                      displayUUID: uuid, userInitiated: userInitiated) else { return }
        storedPlacement = placement
    }

    /// 画面の構成が落ち着いたら、保存した位置へ置き直す（保存先が無ければプライマリを基準に）
    private func reposition() {
        reconfiguring = false
        guard let window, restored, !closed, !isFullScreen, let placement = storedPlacement else { return }
        let size = window.frame.size
        let target = placement.displayUUID.flatMap(NSScreen.screen(forUUID:))
        let base = (target ?? NSScreen.primary())?.frame ?? .zero
        let origin = resolvedOrigin(placement.origin(on: base, size: size), size: size, anchor: target ?? NSScreen.primary())
        guard origin != window.frame.origin else { return }
        logger.info("\(self.name, privacy: .public)：画面の構成が変わったので置き直した: 保存先の画面 \(target == nil ? "なし" : "あり", privacy: .public)")
        setFrame(CGRect(origin: origin, size: size), on: window)
    }

    private func setFrame(_ frame: CGRect, on window: NSWindow) {
        applyingFrame = true
        window.setFrame(frame, display: true, animate: false)
        applyingFrame = false
    }

    // MARK: - 通知

    private func observe(_ window: NSWindow) {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0); workspace.removeObserver($0) }
        observers = [
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowDidMove() }
            },
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.save(userInitiated: true) }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.closed = true }
            },
            // 閉じた窓を SwiftUI は壊さずに隠しておき、開き直すと同じ窓を出すことがある（そのときは中身からの知らせが来ないことがある。mirne の実測）。
            // 閉じた後に窓がまた見えるようになったことで、開き直したと見る
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowMayHaveReopened() }
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowMayHaveReopened() }
            },
            center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isFullScreen = true }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isFullScreen = false }
            },
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanging() }
            },
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanging() }
            },
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanging() }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanging() }
            },
        ]
    }

    private func windowMayHaveReopened() {
        guard closed, let window, window.isVisible else { return }
        attach(window)
    }

    private func windowDidMove() {
        guard let window, !applyingFrame, !window.inLiveResize else { return }
        // 人が動かした（画面の構成が変わっている間・全画面の間は save が捨てる）
        save(userInitiated: true)
    }

    /// 画面の構成が変わり始めた・スリープの前後。最後の通知から待って 1 回だけ置き直す
    private func screensChanging() {
        reconfiguring = true
        repositionTask?.cancel()
        repositionTask = Task { [weak self] in
            try? await Task.sleep(for: WindowPlacementTiming.repositionDebounce)
            guard !Task.isCancelled else { return }
            self?.reposition()
        }
    }
}
