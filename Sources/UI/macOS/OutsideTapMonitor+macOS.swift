import AppKit
import SwiftUI

/// 窓のどこかを押したことを知らせる（macOS 版）。その窓のマウスの押し下げをローカルモニターで見て、
/// 事象はそのまま流す（ほかの操作を妨げない）。位置は窓の中身の左上を原点にした座標（SwiftUI の `.global` と同じ）
struct OutsideTapMonitor: NSViewRepresentable {
    let onTap: (CGPoint) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onTap = onTap
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onTap = onTap
    }

    final class MonitorView: NSView {
        var onTap: ((CGPoint) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      let content = window.contentView else { return event }
                let point = content.convert(event.locationInWindow, from: nil)
                // 中身の座標が下を原点にしているときは、上を原点に直す
                let y = content.isFlipped ? point.y : content.bounds.height - point.y
                self.onTap?(CGPoint(x: point.x, y: y))
                return event
            }
        }

        // 窓から外れたとき（window が nil）に、viewDidMoveToWindow でモニターを外す
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
