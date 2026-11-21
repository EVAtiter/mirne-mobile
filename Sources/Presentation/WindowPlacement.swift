import CoreGraphics
import Foundation

// 窓の位置と大きさの保存と復元。
// mirne の `GuideWindowPlacement` と `GuideWindowController` の保存・復元の計算（Sources/mirne/GuideWindow.swift）を写した。
// mirne は NSScreen と NSWindow を受け取って計算するが、ここは試験できるように矩形と画面の UUID を受け取る（AppKit に依存させない）

/// 保存する窓の位置と大きさ。
///
/// 位置は画面の UUID と、その画面の `frame` の左下からの「窓の左上」の位置（mirne の視聴ウィンドウ・番組表のウィンドウと同じ基準）。
/// 大きさは窓の幅と高さ
public struct WindowPlacement: Codable, Equatable, Sendable {
    public var displayUUID: String?
    public var left: Double
    public var top: Double
    public var width: Double
    public var height: Double

    public init(displayUUID: String?, left: Double, top: Double, width: Double, height: Double) {
        self.displayUUID = displayUUID
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }

    /// 窓 `frame` を、画面 `screenFrame`（UUID は `displayUUID`）の左下からの左上と大きさで持つ
    public init(frame: CGRect, screenFrame: CGRect, displayUUID: String?) {
        self.init(displayUUID: displayUUID,
                  left: frame.minX - screenFrame.minX, top: frame.maxY - screenFrame.minY,
                  width: frame.width, height: frame.height)
    }

    /// 戻す大きさ：`minimumSize` より小さくしない（保存が壊れていても使える大きさで開く）。
    /// `aspectRatio` があれば、幅から高さを決め直す（視聴ウィンドウの 16:9。高さが最小より小さくなるなら高さから幅を決める）
    public func size(minimumSize: CGSize, aspectRatio: CGSize? = nil) -> CGSize {
        var size = CGSize(width: max(width, minimumSize.width), height: max(height, minimumSize.height))
        if let aspectRatio, aspectRatio.width > 0, aspectRatio.height > 0 {
            let ratio = aspectRatio.height / aspectRatio.width
            size.height = size.width * ratio
            if size.height < minimumSize.height {
                size.height = minimumSize.height
                size.width = size.height / ratio
            }
        }
        return size
    }

    /// 基準の画面の `frame`（`base`）に、保存した左上で大きさ `size` の窓を置いたときの左下
    public func origin(on base: CGRect, size: CGSize) -> CGPoint {
        CGPoint(x: base.minX + left, y: base.minY + top - size.height)
    }

    /// 窓の今の位置から、保存する値を決める（保存しないなら nil）。
    ///
    /// - 人が動かした（`userInitiated`）なら、今いる画面を保存先にする
    /// - そうでなければ保存先の画面には触らず、保存先と違う画面にいるときは位置も捨てる（mirne と同じ）
    /// - 前の保存と同じなら書かない
    public static func updated(saved: WindowPlacement?, frame: CGRect, screenFrame: CGRect,
                               displayUUID: String, userInitiated: Bool) -> WindowPlacement? {
        if !userInitiated, let saved, saved.displayUUID != displayUUID { return nil }
        let target = userInitiated ? displayUUID : (saved?.displayUUID ?? displayUUID)
        let placement = WindowPlacement(frame: frame, screenFrame: screenFrame, displayUUID: target)
        return placement == saved ? nil : placement
    }

    /// AppKit の自動保存の記録（「x y 幅 高さ 画面の x y 幅 高さ」）から、窓の位置と大きさ（画面の座標）。
    /// 初めて起動したとき、SwiftUI が付けていた自動保存の記録を引き継ぐのに使う
    public static func frame(fromAutosave string: String) -> CGRect? {
        let numbers = string.split(separator: " ").compactMap { Double($0) }
        guard numbers.count >= 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }
}
