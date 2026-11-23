import AVKit
import SwiftUI

/// メディアの再生の画面（Mac：AVKit の `AVPlayerView`。標準の操作部・全画面・ピクチャ・イン・ピクチャ）
struct MediaPlayerSurface: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
