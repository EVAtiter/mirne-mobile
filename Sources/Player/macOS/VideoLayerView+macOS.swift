// 映像を出すビューの macOS 版（NSView）。iOS 版は Sources/Player/iOS にある。
// 描画の本体（VideoRenderer・VideoRenderCore）は OS によらず共通で、このビューは CAMetalLayer を持って
// 描き込む先の大きさを画面に合わせるだけ

import AppKit
import Metal
import QuartzCore

/// 映像を出すビュー。CAMetalLayer を持ち、描き込む先の大きさを画面の画素に合わせるだけで、自分では描かない
/// （描くのは `VideoRenderCore` が描画のスレッドで）
public final class VideoLayerView: NSView {
    let metalLayer = CAMetalLayer()
    /// 窓に置いた・別の画面へ移ったとき（理由の文言を渡す）
    var onDisplayChange: ((String) -> Void)?
    /// 描き込む先の大きさが変わったとき
    var onDrawableSizeChange: (() -> Void)?
    private var screenObserver: (any NSObjectProtocol)?

    init(device: MTLDevice) {
        super.init(frame: .zero)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    override public func makeBackingLayer() -> CALayer { metalLayer }
    override public var isOpaque: Bool { true }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        updateDrawableSize()
        guard let window else { return }
        screenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateDrawableSize()
                self?.onDisplayChange?("窓が別の画面へ移った")
            }
        }
        onDisplayChange?("窓に置いた")
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 1
        if metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size.width > 0, size.height > 0, metalLayer.drawableSize != size else { return }
        metalLayer.drawableSize = size
        onDrawableSizeChange?()
    }
}
