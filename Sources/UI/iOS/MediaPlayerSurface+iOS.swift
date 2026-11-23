import AVKit
import SwiftUI

/// メディアの再生の画面（iPhone・iPad：AVKit の `AVPlayerViewController`。標準の操作部・AirPlay・ピクチャ・イン・ピクチャ）
struct MediaPlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
