import Foundation
import Synchronization

// TS を PlayerEngine（録画の再生）に流し、画面に出さずに数える。
//
// - `play --file <TS>`：手元の TS（合成の検証用の素材など。nasne の録画を復号したものはディスクに無いので使えない）
// - `stream --play`：nasne の録画を復号しながら流す（資格情報が要る。復号した TS はメモリの中だけ）
//
// 描画の代わりに約 60 Hz で FrameQueue から表示すべきフレームを取り出し、表示したフレーム・遅れて捨てたフレーム・
// 音声の進みを数える。音は消す。

/// 復号のスレッドから数える数
final class SharedCounter: Sendable {
    private let count = Mutex(0)
    func add() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

/// 再生を見張って数える（描画の代わり）
@MainActor
final class PlaybackMonitor {
    /// 描画の代わりに取り出す間隔（60 Hz）
    static let displayInterval: Duration = .microseconds(16_667)

    let engine: PlayerEngine
    private let decoded = SharedCounter()
    private var shown = 0
    private var lastShownPTS: Int64?
    private var firstShownPTS: Int64?
    private(set) var firstFrame: DecodedFrame?
    private var maxAhead: Int64 = 0
    private var audioAheadSamples: [Double] = []
    private var task: Task<Void, Never>?
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant
    private(set) var startedAt: Duration?

    init(engine: PlayerEngine) {
        self.engine = engine
        origin = clock.now
        engine.isMuted = true
        engine.onVideoDecoded = { [decoded] _ in decoded.add() }
    }

    func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.displayInterval)
            }
        }
    }

    func stop() { task?.cancel() }

    /// 時計の今の時刻（秒）。再生前は nil
    var mediaSeconds: Double? { engine.presentationTime().map { Double($0) / 90_000 } }

    private func tick() {
        guard let now = engine.presentationTime() else { return }
        if startedAt == nil { startedAt = clock.now - origin }
        if let frame = engine.frames.frame(at: now), frame.pts != lastShownPTS {
            shown += 1
            lastShownPTS = frame.pts
            if firstShownPTS == nil { firstShownPTS = frame.pts }
            if firstFrame == nil { firstFrame = frame }
        }
        if let ahead = engine.bufferedAhead { maxAhead = max(maxAhead, ahead) }
        if let audioAhead = engine.statistics.audioAhead { audioAheadSamples.append(audioAhead) }
    }

    func report(feeder: RecordingFeeder) {
        let stats = engine.statistics
        let decoder = engine.decoder
        say("再生の開始: \(startedAt.map { "\($0.wholeMilliseconds) ms（最初のデータから）" } ?? "始まらなかった")"
            + "・始めた回数 \(stats.starts)・時計の張り直し \(stats.discontinuities)")
        if let frame = firstFrame {
            let sequence = frame.sequence
            say("映像: \(sequence.width)×\(sequence.height)・表示のアスペクト比 \(String(format: "%.3f", sequence.displayAspectRatio))"
                + "・frame_rate_code \(sequence.frameRateCode)・プログレッシブ \(sequence.progressiveSequence ? "はい" : "いいえ")"
                + "・上のフィールドが先 \(frame.picture.topFieldFirst ? "はい" : "いいえ")")
        }
        let span = (lastShownPTS.flatMap { last in firstShownPTS.map { Double(last - $0) / 90_000 } }) ?? 0
        say("フレーム: 復号 \(decoded.value)・表示 \(shown)（\(String(format: "%.1f", span)) 秒ぶん）"
            + "・遅れて捨てた \(engine.frames.lateDrops)・溢れて捨てた \(engine.frames.overflowDrops)"
            + "・映像の PES \(stats.videoPES)・捨てた（最初のランダムアクセスより前）\(decoder.skippedBeforeIntra)"
            + "・欠けたまま \(decoder.damagedPictures)・復号の失敗 \(decoder.decodeErrors)")
        let sorted = audioAheadSamples.sorted()
        let median = sorted.isEmpty ? nil : sorted[sorted.count / 2]
        say("音声: フレーム \(stats.audioFrames)・失敗 \(stats.audioFailures)・時計より先（中央値）\(median.map { String(format: "%.0f ms", $0) } ?? "-")"
            + "・最小 \(sorted.first.map { String(format: "%.0f ms", $0) } ?? "-")")
        // 字幕：PES の数・読めなかった数・本文の数と、いま持っている字幕の並びの数（本文の文字は出さない）
        say("字幕: PES \(stats.captionGroups)・読めない \(stats.captionUnreadable)・本文 \(stats.captionStatements)"
            + "・持っている字幕の並び \(engine.captions.count)・二重音声 \(stats.isDualMono ? "はい" : "いいえ")")
        say("先読み: 最大 \(String(format: "%.2f", Double(maxAhead) / 90_000)) 秒・待った \(feeder.waits) 回"
            + "（\(feeder.waited.wholeMilliseconds) ms）・TS \(feeder.framer.framing.map { "\($0.rawValue) バイト" } ?? "?")")
    }
}

@MainActor
enum PlayCommand {
    /// 1 回に読む量（受信の 1 回と同じくらい）
    static let readChunk = 64 * 1024
    /// 既定の再生の秒数（時計で）
    static let defaultSeconds = 15.0
    /// 読み終えた後、時計が映像の終わりに着くのを待つ上限
    static let drainLimit: Duration = .seconds(10)

    static func run() async throws {
        guard let path = option("--file") else { fail("play --file <TS のファイル> [--seconds 15] [--pause-at <秒> --pause-for <秒>]") }
        let playSeconds = option("--seconds").flatMap(Double.init) ?? defaultSeconds
        let pauseAt = option("--pause-at").flatMap(Double.init)
        let pauseFor = option("--pause-for").flatMap(Double.init) ?? 2
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }

        let engine = PlayerEngine()
        let monitor = PlaybackMonitor(engine: engine)
        let feeder = RecordingFeeder(engine: engine)
        monitor.start()
        var pauseTask: Task<Void, Never>?
        var bytes = 0
        let clock = ContinuousClock()
        let started = clock.now
        while let chunk = try handle.read(upToCount: readChunk), !chunk.isEmpty {
            bytes += chunk.count
            try await feeder.feed(chunk)
            if let pauseAt, pauseTask == nil, let now = monitor.mediaSeconds, let first = monitor.firstFrame,
               now - Double(first.pts) / 90_000 >= pauseAt {
                pauseTask = Task { await pauseCheck(engine: engine, monitor: monitor, seconds: pauseFor) }
            }
            if seconds(clock.now - started) >= playSeconds { break }
        }
        await pauseTask?.value
        // 読み終えたら、先読みしたぶんを再生し切るまで待つ（上限つき）
        try await feeder.finish(limit: drainLimit)
        monitor.stop()
        say("読んだ: \(bytes / 1024) KiB・\(String(format: "%.1f", seconds(clock.now - started))) 秒")
        monitor.report(feeder: feeder)
        engine.stop()
    }

    /// 一時停止して、止めている間に時計が進まないこと・戻ったら進むことを確かめる
    static func pauseCheck(engine: PlayerEngine, monitor: PlaybackMonitor, seconds: Double) async {
        let before = monitor.mediaSeconds ?? 0
        let overflowBefore = engine.frames.overflowDrops
        engine.pause()
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        let during = monitor.mediaSeconds ?? 0
        // 止めている間に、描画が出せるフレーム（時計の時刻までのもの）が残っているか
        let clockNow = engine.presentationTime() ?? 0
        let earliest = engine.frames.earliestPTS
        say("一時停止中のフレーム: \(engine.frames.count) 枚・一番早いものは時計より "
            + "\(earliest.map { String(format: "%+.0f ms", Double($0 - clockNow) / 90) } ?? "-")"
            + "・止めている間に溢れて捨てた \(engine.frames.overflowDrops - overflowBefore)")
        engine.resume()
        try? await Task.sleep(for: .seconds(1))
        let after = monitor.mediaSeconds ?? 0
        say(String(format: "一時停止: %.1f 秒止めた・止めている間の時計の進み %.3f 秒・戻して 1 秒後の進み %.3f 秒",
                   seconds, during - before, after - during))
    }

    static func seconds(_ duration: Duration) -> Double { StreamCommand.seconds(duration) }
}
