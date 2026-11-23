import AVFoundation
import SwiftUI

/// メディアの動画・音楽の再生（OS の標準の再生画面。AVKit）。開いたら始め、閉じたら止める。
/// 録画の再生（DTCP-IP を外して自前で復号する）とは別の部品で、資格情報は要らない。再生の窓（画面）は録画・ライブと共有し、
/// `ViewerContent` が中身を替える（窓が 1 つなので、メディアと録画・ライブは同時に鳴らない）。
/// 画面は OS ごとの AVKit の部品（Mac は `AVPlayerView`、iOS は `AVPlayerViewController`）を `MediaPlayerSurface` で包む。
/// SwiftUI の `VideoPlayer` は使わない：macOS 27.2.1 で、型を初めて読み込むところ（`_AVKit_SwiftUI` の
/// `getSuperclassMetadata`）でアプリが強制終了した（2026-11-23。動画・音楽とも）
struct MediaPlayerView: View {
    let playback: MediaPlayback
    @State private var player: AVPlayer?

    var body: some View {
        MediaPlayerSurface(player: player)
            .background(.black)
            .navigationTitle(playback.title)
            .onAppear {
                let player = AVPlayer(url: playback.url)
                self.player = player
                player.play()
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
    }
}
