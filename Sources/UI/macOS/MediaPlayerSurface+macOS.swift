import AVKit
import SwiftUI

/// メディアの再生の画面（Mac：AVKit の `AVPlayerView`。標準の操作部・ピクチャ・イン・ピクチャ）。
/// 全画面は視聴ウィンドウの右上のボタンと F で切り替える（`AVPlayerView` は SwiftUI の窓を全画面に入れない窓と見て、
/// 全画面のボタンを出さなかった。2026-11-24。窓を切り替えた後に二つ目のボタンが出ないよう、こちらでは出さない）
struct MediaPlayerSurface: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
