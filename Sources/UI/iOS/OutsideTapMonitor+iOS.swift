import SwiftUI
import UIKit

/// 窓のどこかを押したことを知らせる（iPad 版）。窓に、ほかの操作を妨げないタップの認識を 1 つ足す
/// （`cancelsTouchesInView` を切り、ほかの認識と同時に動かす）。一覧の上に SwiftUI のタップを重ねると、
/// 一覧の行を選べなくなったので、窓の側で受ける。位置は窓の座標（SwiftUI の `.global` と同じ）
struct OutsideTapMonitor: UIViewRepresentable {
    let onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.isUserInteractionEnabled = false
        view.onTap = onTap
        return view
    }

    func updateUIView(_ view: MonitorView, context: Context) {
        view.onTap = onTap
    }

    final class MonitorView: UIView, UIGestureRecognizerDelegate {
        var onTap: ((CGPoint) -> Void)?
        private var recognizer: UITapGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            guard let window else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            recognizer = tap
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let window else { return }
            onTap?(recognizer.location(in: window))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
