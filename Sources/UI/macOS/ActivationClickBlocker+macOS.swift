import AppKit
import SwiftUI

/// 窓が前面でないときのクリックを、窓を前面にするだけにする（macOS 版）。
/// SwiftUI のボタンは前面でない窓の最初のクリックにも応えるので、ほかのアプリから番組表を押して戻ると、
/// 押した場所の番組のシートが出ていた（2026-11-24）。重ねた view が、窓がキーでないときのマウスの押し下げだけを受け、
/// `acceptsFirstMouse` を偽にして、AppKit に窓を前面にさせるだけにする。窓がキーのときと、押し下げ以外の事象
/// （スクロール・ホバー）は受けない（下の view に届く）
struct ActivationClickBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> BlockerView { BlockerView() }
    func updateNSView(_ view: BlockerView, context: Context) {}

    final class BlockerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let window, !window.isKeyWindow, NSApp.currentEvent?.type == .leftMouseDown else { return nil }
            return super.hitTest(point)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    }
}
