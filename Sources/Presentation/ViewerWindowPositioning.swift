import CoreGraphics

// 視聴ウィンドウを標準の大きさに戻すときの置き場。
// 画面外の引き戻しは mirne の `ViewerWindowPositioning.resolvedOrigin`（Sources/mirne/ViewerWindow.swift）を写した。
// mirne は NSScreen を受け取るが、ここは試験できるように画面の `visibleFrame` の矩形を受け取る（AppKit に依存させない）

/// 視聴ウィンドウの層の決まり（mirne の `applyLevel` と同じ）
public enum ViewerWindowLevel {
    /// 最前面（floating）にするか：常に最前面を選んでいて、全画面でないとき
    public static func floats(alwaysOnTop: Bool, fullScreen: Bool) -> Bool {
        alwaysOnTop && !fullScreen
    }
}

/// 画面外の救済の決まり（mirne と同じ値。参照実装：EVA Clock Nixie の WindowPositioning）
public enum ViewerWindowPositioning {
    /// どれかの画面に最低限見えていてほしい量（掴んで戻せる大きさ。体感の値）
    public static let minVisibleOnRestore = CGSize(width: 160, height: 120)
    /// 窓が小さいとき、要求量を窓の大きさのこの割合で頭打ちにする（要求量が窓より大きいと、判定が常に偽になり内側へ押し続ける）
    public static let keepVisibleRatio: CGFloat = 0.75

    public static func minVisible(for size: CGSize) -> CGSize {
        CGSize(width: min(minVisibleOnRestore.width, size.width * keepVisibleRatio),
               height: min(minVisibleOnRestore.height, size.height * keepVisibleRatio))
    }

    /// 位置 `origin` の窓が、どれかの画面の `visibleFrame`（`visibleFrames`）に十分見えていればそのまま、足りなければ
    /// `anchor`（窓のある画面。無ければプライマリ）の `visibleFrame` へ、要求量だけ見えるように引き戻した位置。
    /// 判定も救済も `visibleFrame` で数える（メニューバーと Dock に覆われた帯は掴めない）。
    /// `intersects()` の真偽や、`visibleFrame` への無条件のクランプにはしない（どちらも、画面の端に少し掛かっただけの窓を見落とすか、動かす必要の無い窓まで動かす）。
    /// 画面が 1 つも無ければ nil
    public static func resolvedOrigin(_ origin: CGPoint, windowSize: CGSize, visibleFrames: [CGRect], anchor: CGRect?) -> CGPoint? {
        let rect = CGRect(origin: origin, size: windowSize)
        let minVisible = minVisible(for: windowSize)
        let visible = visibleFrames
            .map { $0.intersection(rect) }
            .filter { !$0.isNull }
            .max { $0.width * $0.height < $1.width * $1.height }
        if let visible, visible.width >= minVisible.width, visible.height >= minVisible.height {
            return origin
        }
        guard let frame = anchor else { return nil }
        return CGPoint(
            x: min(max(origin.x, frame.minX - (windowSize.width - minVisible.width)), frame.maxX - minVisible.width),
            y: min(max(origin.y, frame.minY - (windowSize.height - minVisible.height)), frame.maxY - minVisible.height))
    }

    /// 左上 `topLeft` を保って大きさ `size` にしたときの窓の左下（画面の座標は y が上へ増える）。
    /// mirne の `resetSize` は中心を保つが、こちらは左上を保つ（2026-11-20 に決めた）
    public static func origin(keepingTopLeft topLeft: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: topLeft.x, y: topLeft.y - size.height)
    }
}
