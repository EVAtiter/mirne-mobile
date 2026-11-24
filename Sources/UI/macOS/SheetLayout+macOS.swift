import AppKit
import SwiftUI

extension View {
    /// シートの中身の幅（macOS 版：渡した幅に決める）
    func sheetContentWidth(_ width: CGFloat) -> some View {
        frame(width: width)
    }

    /// 大きさを変えられるシートの最小と最初の大きさ（macOS 版：シートの窓の大きさにする）
    func sheetResizableSize(minimum: CGSize, ideal: CGSize) -> some View {
        frame(minWidth: minimum.width, idealWidth: ideal.width, minHeight: minimum.height, idealHeight: ideal.height)
    }

    /// シートの高さを中身に合わせる（macOS 版：シートは元から中身の高さなので何もしない）
    func sheetFitsContentHeight() -> some View {
        self
    }

    /// Form の高さを中身の高さにする（macOS 版：何もしない）
    func formFitsContentHeight() -> some View {
        self
    }
}

/// シートの「閉じる」の置き場
enum SheetCloseLayout {
    /// 「閉じる」を左上の × にするか（macOS 版：下の帯の「閉じる」）。「キャンセル」と「予約する」のように対になるシートは、どちらの OS も下の帯のまま
    static let closesAtTop = false
    /// × の大きさ・余白（体感の値。画面で見て決める）
    static let buttonSize: CGFloat = 28
    static let horizontalPadding: CGFloat = 16
    static let topPadding: CGFloat = 16
}

/// 何かを作る・変えるシート（予約のシート）のボタンの置き場
enum SheetActionLayout {
    /// 上のナビゲーションの帯に置くか（macOS 版：下の帯。右に「キャンセル」「確定」、左に削除〔作法どおり〕）
    static let usesNavigationBar = false
}

extension View {
    /// ナビゲーションの帯の題を小さく出す（macOS 版：何もしない）
    func inlineNavigationTitle() -> some View {
        self
    }

    /// 予約のシートのフォームの高さ（macOS 版：中身の高さ。`formFitsContentHeight` は何もしない）
    func scheduleSheetFormHeight() -> some View {
        formFitsContentHeight()
    }

    /// 予約のシートの大きさ（macOS 版：シートは中身の高さ。`sheetFitsContentHeight` と同じく何もしない）
    func scheduleSheetSizing() -> some View {
        sheetFitsContentHeight()
    }
}

extension View {
    /// シートの外（シートを出している窓）をクリックしたら閉じる（macOS 版。2026-11-24）。
    /// Mac のシートは親の窓のクリックを受けない（押しても音が鳴るだけ）ので、シートの中身に置いた見えない view が
    /// 親の窓のマウスの押し下げを見て閉じる。押した事象は親の窓へ通さない（下の番組などを押したことにしない）。
    /// 入力を持つシート（予約の作成など）には付けない（打ちかけの内容が消えるため）
    func closesOnOutsideClick(_ close: @escaping () -> Void) -> some View {
        background(SheetOutsideClickCloser(close: close))
    }
}

/// 親の窓のクリックを見る見えない view（`closesOnOutsideClick`）。
/// `OutsideTapMonitor` は自分の窓のクリックを知らせて事象を通すもので、こちらは親の窓のクリックを止めるので別に置いた
private struct SheetOutsideClickCloser: NSViewRepresentable {
    let close: () -> Void

    func makeNSView(context: Context) -> CloserView {
        let view = CloserView()
        view.close = close
        return view
    }

    func updateNSView(_ view: CloserView, context: Context) {
        view.close = close
    }

    static func dismantleNSView(_ view: CloserView, coordinator: ()) {
        view.stopWatching()
    }

    final class CloserView: NSView {
        var close: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let parent = self.window?.sheetParent, event.window === parent else { return event }
                self.close?()
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
