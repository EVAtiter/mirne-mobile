import Foundation
import Testing

// 録画の読み手が、先読みが溜まって待つときに見に行く間隔（2026-11-21）。一時停止中だけ間を空ける
struct RecordingPollIntervalTests {
    @Test("再生中は 20 ms、一時停止中は 100 ms")
    func intervalFollowsPause() {
        #expect(RecordingPlayback.pollInterval(isPaused: false) == .milliseconds(20))
        #expect(RecordingPlayback.pollInterval(isPaused: true) == .milliseconds(100))
    }

    @Test("一時停止中の間隔は、最も速い再生でも復号済みの映像の半分より短い（戻した直後に絵が尽きない）")
    func pausedIntervalFitsDecodeAhead() throws {
        let fastest = try #require(PlaybackRatePolicy.rates.max())
        let interval = RecordingPlayback.pausedPollInterval
        let ticks = Double(interval.components.seconds) * 90_000 + Double(interval.components.attoseconds) / 1e18 * 90_000
        #expect(ticks * fastest <= Double(PlaybackTiming.videoDecodeAhead) / 2)
    }
}
