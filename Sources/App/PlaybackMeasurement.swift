import Foundation
import QuartzCore

// 計測は開発用のビルド（Debug）だけに入れる。公開版（Release）には入れない（2026-11-21）
#if DEBUG

/// 再生の非機能要件の計測。
///
/// - 再生ボタン → 映像：再生を新しく頼まれた時刻から、最初の絵が画面に出た時刻まで（どちらも CACurrentMediaTime の秒）
/// - 映像・音声のずれ：再生中は 1 分ごとに、終わったら全体を、`AVSyncRecorder` の要約で出す
///
/// 出すのは時間と数値だけ（番組名・局名・アドレス・ID は出さない）。CPU とメモリはアプリの外から数える（`scripts/measure-process.sh`）
@MainActor
final class PlaybackMeasurement {
    /// 最初の絵を待つ間の見張りの間隔
    static let firstFramePollInterval: Duration = .milliseconds(5)
    /// 最初の絵を待つ上限（これを過ぎたら諦めて、ずれの見張りだけ続ける）
    static let firstFrameTimeout: TimeInterval = 30
    /// 再生しているかを見る間隔
    static let stateCheckInterval: Duration = .seconds(1)
    /// 再生している間に、ずれと描画の数をログに出す間隔（再生している秒で数える）
    static let periodicSeconds = 60

    private let playback: PlaybackController
    private let renderer: VideoRenderer?
    private var task: Task<Void, Never>?

    init(playback: PlaybackController, renderer: VideoRenderer?) {
        self.playback = playback
        self.renderer = renderer
        playback.onRequest = { [weak self] kind, quality in self?.requested(kind: kind, quality: quality) }
    }

    private func requested(kind: PlaybackKind, quality: String?) {
        let requestedAt = CACurrentMediaTime()
        // 頼んだ時点の時計の張り直しの回数。前の受信の時計（止める前）を、新しい再生の開始と取り違えないために使う
        let epochAtRequest = playback.engine.clockEpoch
        task?.cancel()
        let label = "\(kind == .live ? "ライブ" : "録画")・画質 \(quality ?? "元")"
        task = Task { [weak self] in
            await self?.measure(label: label, requestedAt: requestedAt, epochAtRequest: epochAtRequest)
        }
    }

    private func measure(label: String, requestedAt: CFTimeInterval, epochAtRequest: Int) async {
        guard let renderer else { return }
        let engine = playback.engine
        let started = ContinuousClock.now
        // 再生系が時計を動かし始める（新しい張り直しの回数になる）のを待ち、その回数で最初に画面に出た時刻を探す
        var engineStartedAt: CFTimeInterval?
        var firstFrameAt: CFTimeInterval?
        while !Task.isCancelled, CACurrentMediaTime() - requestedAt < Self.firstFrameTimeout {
            if case .failed = playback.state { break }
            if playback.state == .idle { break }
            if engine.startPTS != nil, !engine.isPaused, engine.clockEpoch != epochAtRequest {
                if engineStartedAt == nil {
                    engineStartedAt = CACurrentMediaTime()
                    renderer.avSync.reset()
                    renderer.resetDrawStatistics()
                }
                if let host = renderer.avSync.firstPresentedHost(inEpoch: engine.clockEpoch), host >= requestedAt {
                    firstFrameAt = host
                    break
                }
            }
            try? await Task.sleep(for: Self.firstFramePollInterval)
        }
        guard !Task.isCancelled else { return }
        if let firstFrameAt {
            let engineText = engineStartedAt.map { "・再生系の開始まで \(Self.milliseconds($0 - requestedAt)) ms" } ?? ""
            PerformanceLog.logger.info("計測: 再生（\(label, privacy: .public)）を頼んでから最初の絵が出るまで \(Self.milliseconds(firstFrameAt - requestedAt), privacy: .public) ms\(engineText, privacy: .public)")
        } else {
            PerformanceLog.logger.info("計測: 再生（\(label, privacy: .public)）の最初の絵を測れなかった（\(started.elapsedMilliseconds, privacy: .public) ms 待った）")
        }
        // 再生している間は 1 分ごとに、終わったら最後に数え直してからのずれを出す。
        // 一時停止・先読みの待ちの間は時計が止まっていて、止めた絵のずれは意味が無いので、再生に戻ったら数え直す
        var playingSeconds = 0
        var needsReset = false
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.stateCheckInterval)
            guard !Task.isCancelled else { return }
            switch playback.state {
            case .idle, .ended, .failed:
                log("終わり", label: label, renderer: renderer)
                return
            case .playing:
                if needsReset {
                    needsReset = false
                    renderer.avSync.reset()
                    renderer.resetDrawStatistics()
                }
                playingSeconds += 1
                if playingSeconds.isMultiple(of: Self.periodicSeconds) {
                    log("\(playingSeconds / Self.periodicSeconds) 分", label: label, renderer: renderer)
                }
            default:
                needsReset = true
            }
        }
    }

    private func log(_ point: String, label: String, renderer: VideoRenderer) {
        let stats = renderer.statistics
        let drawing = "描いた \(stats.drawn)・空振り \(stats.starved)・遅れの最大 \(Self.oneDecimal(stats.maximumLateness)) ms"
        if let sync = renderer.avSync.summary {
            PerformanceLog.logger.info("計測: 再生（\(label, privacy: .public)）\(point, privacy: .public)：A/V のずれ 中央 \(Self.oneDecimal(sync.p50), privacy: .public) ms・5〜95% \(Self.oneDecimal(sync.p5), privacy: .public)〜\(Self.oneDecimal(sync.p95), privacy: .public) ms・最小 \(Self.oneDecimal(sync.minimum), privacy: .public)・最大 \(Self.oneDecimal(sync.maximum), privacy: .public) ms（直近 \(sync.count, privacy: .public) 枚）・\(drawing, privacy: .public)")
        } else {
            PerformanceLog.logger.info("計測: 再生（\(label, privacy: .public)）\(point, privacy: .public)：A/V のずれの記録なし・\(drawing, privacy: .public)")
        }
    }

    static func milliseconds(_ seconds: CFTimeInterval) -> Int {
        Int((seconds * 1000).rounded())
    }

    static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

#endif
