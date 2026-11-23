import AppKit
import SwiftUI

// 番組表の OS ごとの部分（macOS 版）：スクロールバーの右の余白・マウスを置いたときの吹き出し・局のロゴの絵

extension View {
    /// 番組表の右端の余白（スクロールバーの幅。`GuideLayout` の説明を参照）
    func guideTrailingScrollerInset() -> some View {
        modifier(GuideTrailingScrollerInset())
    }

    /// マウスを置いたときの吹き出しのための見張り（macOS 版：マウスの位置を渡す）
    func guidePointerHover(_ action: @escaping (HoverPhase) -> Void) -> some View {
        onContinuousHover(perform: action)
    }

    /// 斜めのスワイプでも自由に動かす（macOS 版）。スクロールの中身に置く
    func guideFreeScrolling() -> some View {
        background(FreeAxisScrolling())
    }

    /// 吹き出しの窓がスクロールの操作を受けたら知らせる
    func popoverScrollWatcher(_ onScroll: @escaping () -> Void) -> some View {
        background(PopoverScrollWatcher(onScroll: onScroll))
    }
}

/// 番組表の右端の余白：重ねて出すスクロールバー（`.overlay`）のときだけ、スクロールバーの幅を余らせる
private struct GuideTrailingScrollerInset: ViewModifier {
    /// スクロールバーの出し方（システム設定の「スクロールバーを表示」。右端の余白を決める）
    @State private var scrollerStyle = NSScroller.preferredScrollerStyle

    func body(content: Content) -> some View {
        content
            .padding(.trailing, Self.inset(scrollerStyle: scrollerStyle))
            .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
                scrollerStyle = NSScroller.preferredScrollerStyle
            }
    }

    /// `NSScroller` は main actor の上でしか読めないので、これも main actor に置く（画面の中からしか読まない）
    @MainActor static func inset(scrollerStyle: NSScroller.Style) -> CGFloat {
        scrollerStyle == .overlay ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }
}

/// 包んでいる `NSScrollView` の、1 回のスワイプを縦か横の強いほうに絞る働き（`usesPredominantAxisScrolling`。既定で入）を切る。
/// 切らないと、斜めに払っても縦か横の一方にしか動かない（iPad・iPhone の OS のスクロールは元から絞らない。2026-11-23）。
/// トラックパッドの 2 本指と Magic Mouse の 1 本指のスワイプは、どちらもスクロールの事象で届くので、これ 1 つで両方に効く。
/// SwiftUI の ScrollView からは設定できないので、中身に置いた見えない view から包んでいるスクロールの部品を探す
private struct FreeAxisScrolling: NSViewRepresentable {
    func makeNSView(context: Context) -> FreeAxisScrollingView { FreeAxisScrollingView() }
    func updateNSView(_ view: FreeAxisScrollingView, context: Context) {}
}

private final class FreeAxisScrollingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // 窓に載った直後は、まだスクロールの部品の中に組み込まれていないことがあるので、次の回にも見る
        apply()
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    private func apply() {
        enclosingScrollView?.usesPredominantAxisScrolling = false
    }

    /// 押す・置く操作は下の番組の欄へ通す
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 番組表の帯の前後の日のボタン（macOS 版：ひと続きの部品 `ControlGroup`）
struct GuideDaySteppers: View {
    let canGoBack: Bool
    let canGoForward: Bool
    let move: (Int) -> Void

    var body: some View {
        ControlGroup {
            Button("前の日", systemImage: "chevron.left") { move(-1) }
                .disabled(!canGoBack)
            Button("次の日", systemImage: "chevron.right") { move(1) }
                .disabled(!canGoForward)
        }
        .labelStyle(.iconOnly)
        .fixedSize()
    }
}

/// 局のロゴの絵（macOS 版）
enum GuideLogo {
    static func image(from data: Data) -> Image? {
        NSImage(data: data).map { Image(nsImage: $0) }
    }
}

/// 吹き出しの窓がスクロールの操作を受けたら知らせる。
///
/// 吹き出しは番組表とは別の小さな窓なので、マウスが吹き出しの上にあるとスクロールの操作は吹き出しに届き、番組表は動かない
/// （番組表が送られたら閉じるだけでは、吹き出しの上で始めたスワイプで閉じなかった。2026-11-21）。
/// 受けたら吹き出しを閉じ、続きの操作が下の番組表に届くようにする。受けた 1 回は吹き出しで捨てる
private struct PopoverScrollWatcher: NSViewRepresentable {
    let onScroll: () -> Void

    func makeNSView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.onScroll = onScroll
    }

    static func dismantleNSView(_ view: WatcherView, coordinator: ()) {
        view.stopWatching()
    }

    final class WatcherView: NSView {
        var onScroll: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                self.onScroll?()
                return nil
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
