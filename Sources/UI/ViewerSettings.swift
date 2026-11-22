import CoreGraphics

// 視聴の画面の大きさと設定の鍵（macOS の視聴ウインドウと iPad の視聴の画面で共通）

/// 視聴ウィンドウの決まり
enum ViewerLayout {
    /// 映像の縦横比（16:9）。窓はこの比を保ってリサイズする
    static let aspectRatio = CGSize(width: 16, height: 9)
    /// 初めて開くときの大きさ
    static let defaultSize = CGSize(width: 960, height: 540)
    /// これより小さくできない大きさ
    static let minimumSize = CGSize(width: 480, height: 270)
    /// 映像の縦横比を 1 つの数にしたもの（字幕を重ねる矩形の既定。映像の大きさが分かるまで使う）
    static var videoAspectRatio: Double { Double(aspectRatio.width / aspectRatio.height) }
}

/// 視聴の設定の鍵（UserDefaults）
enum ViewerSettingsKey {
    /// 起動したときに字幕を出すか（未設定なら出さない。mirne と同じ）
    static let captionsByDefault = "captionsByDefault"
    /// 視聴ウィンドウを常に最前面にするか（未設定なら通常。mirne と同じ鍵の名前）
    static let alwaysOnTop = "alwaysOnTop"
}
