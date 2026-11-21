import Foundation

/// 録画の TS を PlayerEngine へ渡す（mirne mobile で足したもの）。
///
/// - 192 バイト（タイムスタンプ付き）の TS は 188 に直してから渡す（`TSFramer`）
/// - 時計より `RecordingPlayback.targetAhead` 先まで受け取ったら、渡した後に待つ。一時停止で時計が止まれば
///   先読みはそこで増えなくなるので、同じように待つ（一時停止だけを理由には待たない。データが途切れて
///   時計を止めたときに、読み込みまで止めて抜けられなくなるため。2026-11-18）。一時停止中は見に行く間隔だけを空ける
///   （`RecordingPlayback.pausedPollInterval`。2026-11-21）
///   呼び出し側（受信のループ）はこの `feed` を await するので、受信がそのぶん止まる（読む側が引いたぶんだけ読む）
public final class RecordingFeeder: @unchecked Sendable {
    public let engine: PlayerEngine
    public let framer = TSFramer()
    /// 先読みが溜まって待った回数と、その合計
    public private(set) var waits = 0
    public private(set) var waited: Duration = .zero

    public init(engine: PlayerEngine) {
        self.engine = engine
    }

    /// 受信したバイト列（切れ目はどこでもよい）を渡す。先読みが溜まっていれば、減るまで戻らない
    public func feed(_ data: Data) async throws {
        let packets = framer.feed(data)
        if !packets.isEmpty { engine.feed(packets) }
        let clock = ContinuousClock()
        let start = clock.now
        var didWait = false
        // 再生前（bufferedAhead が nil）は待たない。始めるのに要るぶんを溜めるため
        while let ahead = engine.bufferedAhead, ahead > RecordingPlayback.targetAhead {
            didWait = true
            try await Task.sleep(for: RecordingPlayback.pollInterval(isPaused: engine.isPaused))
            engine.pump()   // 待っている間も、時計に合わせて映像を復号する
        }
        if didWait {
            waits += 1
            waited += clock.now - start
        }
    }

    /// 読み終えたら呼ぶ。先読みしたぶんを再生し切るまで、映像の復号を進めながら待つ（上限 `limit`）
    public func finish(limit: Duration) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while let ahead = engine.bufferedAhead, ahead > 0, clock.now - start < limit {
            try await Task.sleep(for: RecordingPlayback.pollInterval(isPaused: engine.isPaused))
            engine.pump()
        }
    }
}
