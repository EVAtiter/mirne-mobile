import AppKit
import SwiftUI

// 番組表の OS ごとの部分（macOS 版）：スクロールバーの右の余白・斜めのスワイプ・マウスのドラッグ・局のロゴの絵

extension View {
    /// 番組表の右端の余白（スクロールバーの幅。`GuideLayout` の説明を参照）
    func guideTrailingScrollerInset() -> some View {
        modifier(GuideTrailingScrollerInset())
    }

    /// 斜めのスワイプでも自由に動かす（macOS 版）。スクロールの中身に置く
    func guideFreeScrolling() -> some View {
        background(FreeAxisScrolling())
    }

    /// マウスの左ボタンを押したまま動かして、表を縦横どちらにも送る（macOS 版）。スクロールの中身に置く
    func guideMouseDragScrolling() -> some View {
        background(MouseDragScrolling())
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

/// マウスのドラッグで送る決まり（macOS 版）
enum GuideMouseDrag {
    /// 押してからこれだけ動くまではクリック（番組のシート・視聴のボタン）とし、超えたらドラッグにする（pt。体感の値。画面で見て決める）
    static let threshold: CGFloat = 4
    /// ドラッグにした後の離した事象を、番組のボタンに「外で離した」と見せる位置（窓の座標。窓から十分に離れた所）
    static let releaseLocationOutsideWindow = NSPoint(x: -100_000, y: -100_000)
}

/// 番組表をマウスの左ボタンを押したまま動かして送る（2026-11-24）。
///
/// 包んでいる `NSScrollView` を探す見えない view が、窓のマウスの事象を見る（ローカルモニター）。
/// - 押し下げは下へ通す（番組の欄・局の視聴のボタンはふつうに押せる）。スクロールバーの上・窓が前面でないとき（前面にするだけのクリック）は見ない
/// - 押したまま `GuideMouseDrag.threshold` を超えて動いたらドラッグにし、つかんだ所が付いてくるように見える位置を動かす（惰性は付けない）。
///   ドラッグの間はカーソルを握った手にし、動きの事象は下へ通さない
/// - ドラッグにした後の離した事象は、窓の外で離したことにして下へ通す（番組のボタンが押されず、押したままの状態も解ける）
private struct MouseDragScrolling: NSViewRepresentable {
    func makeNSView(context: Context) -> MouseDragScrollingView { MouseDragScrollingView() }
    func updateNSView(_ view: MouseDragScrollingView, context: Context) {}

    static func dismantleNSView(_ view: MouseDragScrollingView, coordinator: ()) {
        view.stopWatching()
    }
}

private final class MouseDragScrollingView: NSView {
    private var monitor: Any?
    /// 押した所（窓の座標）と、そのときの見えている位置（中身の座標）。押していない・見ない押し下げなら nil
    private var start: (location: NSPoint, origin: NSPoint)?
    private var dragging = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopWatching()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        finishDragging()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, let scrollView = enclosingScrollView else { return event }
        switch event.type {
        case .leftMouseDown:
            finishDragging()
            if window.isKeyWindow, isOnContent(event, in: scrollView) {
                start = (event.locationInWindow, scrollView.contentView.bounds.origin)
            }
            return event
        case .leftMouseDragged:
            guard let start else { return event }
            let dx = event.locationInWindow.x - start.location.x
            let dy = event.locationInWindow.y - start.location.y
            if !dragging {
                guard hypot(dx, dy) >= GuideMouseDrag.threshold else { return event }
                dragging = true
                NSCursor.closedHand.push()
            }
            let clip = scrollView.contentView
            // 窓の座標は上向きが正。中身が上から下へ並ぶ（flipped）なら縦の向きを逆にする
            let deltaY = clip.isFlipped ? -dy : dy
            let wanted = NSRect(origin: NSPoint(x: start.origin.x - dx, y: start.origin.y - deltaY), size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(wanted).origin)
            scrollView.reflectScrolledClipView(clip)
            return nil
        case .leftMouseUp:
            let wasDragging = dragging
            finishDragging()
            guard wasDragging else { return event }
            return NSEvent.mouseEvent(with: .leftMouseUp, location: GuideMouseDrag.releaseLocationOutsideWindow,
                                      modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                      windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
                                      clickCount: event.clickCount, pressure: 0) ?? event
        default:
            return event
        }
    }

    /// 表の中身の上か（スクロールバーの上は除く）
    private func isOnContent(_ event: NSEvent, in scrollView: NSScrollView) -> Bool {
        let point = scrollView.convert(event.locationInWindow, from: nil)
        guard scrollView.bounds.contains(point) else { return false }
        for scroller in [scrollView.verticalScroller, scrollView.horizontalScroller] {
            if let scroller, !scroller.isHidden, scroller.frame.contains(point) { return false }
        }
        return true
    }

    private func finishDragging() {
        if dragging { NSCursor.pop() }
        dragging = false
        start = nil
    }

    /// 押す・置く操作は下の番組の欄へ通す（事象はローカルモニターで見る）
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
