import SwiftUI

/// 各画面の上の帯の OS ごとの決まり（iOS 版）
enum ScreenActionBarPlatform {
    /// 帯の段の高さを、いちばん高い部品の見本で揃えるか（iOS 版：揃える。iPad の 4 つの画面で「更新」の位置がずれた。2026-11-23）
    static let alignsRowHeight = true
}

extension View {
    /// 帯の状態の文字の大きさ（iOS 版）：本文より一段小さい文字（主画面の倍率を掛ける）。
    /// 前は本文のまま（ボタンと同じ大きさ）だったが、帯のボタンをガラスの板にしたら大きく見えた（2026-11-23）
    func barStatusFont(_ controlSize: ControlSize) -> some View {
        scaledFont(.subheadline)
    }

    /// 窓を操作するボタン（iPadOS の窓の左上の閉じる・縮める）の場所を避ける（iOS 版）。
    /// 上の帯を出さないと、各画面の帯が窓の左上の角に来て、そこに置いた「‹ ›」が押せなかった（OS が窓の操作に使う。2026-11-23）。
    /// UIKit の角を避けた安全領域（`safeArea(cornerAdaptation: .horizontal)`。iOS 26 から）の左端を測り、その分だけ左を空ける
    func avoidsWindowControls() -> some View {
        modifier(WindowControlsAvoidance())
    }
}

private struct WindowControlsAvoidance: ViewModifier {
    /// 窓を操作するボタンの場所の幅（無ければ 0）
    @State private var leading: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.leading, leading)
            .background(WindowControlsProbe { leading = $0 })
    }
}

/// 角を避けた安全領域の左端を測って知らせる（見えない UIKit の view。押す操作は下へ通す）
private struct WindowControlsProbe: UIViewRepresentable {
    let report: (CGFloat) -> Void

    func makeUIView(context: Context) -> WindowControlsProbeView {
        let view = WindowControlsProbeView()
        view.report = report
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: WindowControlsProbeView, context: Context) {
        view.report = report
    }
}

private final class WindowControlsProbeView: UIView {
    var report: ((CGFloat) -> Void)?
    private var reported: CGFloat = -1

    override func layoutSubviews() {
        super.layoutSubviews()
        measure()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        measure()
    }

    private func measure() {
        guard #available(iOS 26.0, *) else { return }
        let guide = layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))
        // ふつうの安全領域（横向きの丸い角など）は帯の余白で足りているので、それを超える分だけ
        let inset = max(0, guide.layoutFrame.minX - safeAreaInsets.left)
        guard inset != reported else { return }
        reported = inset
        // 画面の更新の途中で SwiftUI の状態を書き換えないよう、次の回に知らせる
        DispatchQueue.main.async { [weak self] in self?.report?(inset) }
    }
}
