// 映像を出すビューの iOS / iPadOS 版（UIView）。macOS 版は Sources/Player/macOS にある。
// 描画の本体（VideoRenderer・VideoRenderCore）は OS によらず共通で、このビューは CAMetalLayer を自分の層にし、
// 描き込む先の大きさを画面に合わせるだけ

import Metal
import QuartzCore
import UIKit

/// 映像を出すビュー。CAMetalLayer を自分の層に持ち、描き込む先の大きさを画面の画素に合わせるだけで、自分では描かない
/// （描くのは `VideoRenderCore` が描画のスレッドで）
public final class VideoLayerView: UIView {
    override public class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    /// 窓に置いた・画面の倍率が変わったとき（理由の文言を渡す）
    var onDisplayChange: ((String) -> Void)?
    /// 描き込む先の大きさが変わったとき
    var onDrawableSizeChange: (() -> Void)?

    init(device: MTLDevice) {
        super.init(frame: .zero)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        isOpaque = true
        // 画面の倍率が変わったら（別の画面へ移したときなど）、描き込む先の大きさと表示のタイミングを合わせ直す
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: VideoLayerView, _: UITraitCollection) in
            view.updateDrawableSize()
            view.onDisplayChange?("画面の倍率が変わった")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    override public func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableSize()
        if window != nil { onDisplayChange?("窓に置いた") }
    }

    private func updateDrawableSize() {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 1
        if metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size.width > 0, size.height > 0, metalLayer.drawableSize != size else { return }
        metalLayer.drawableSize = size
        onDrawableSizeChange?()
    }
}
