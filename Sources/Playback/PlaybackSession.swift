import Foundation
import Synchronization

// 1 回の受信（2026-11-21 に PlaybackController.swift から分けた）

/// 1 回の受信（HEAD から最後まで）。中断すると鍵と接続を捨てる
final class PlaybackSession: @unchecked Sendable {
    enum Event: Sendable {
        case stage(PlaybackStage)
        case seekStart(Double)
        case finished
        case failed(any Error, PlaybackStage)
    }

    private let url: URL
    private let startSeconds: Double
    private let credentialStore: any DTCPCredentialStore
    private let client: any HTTPExchanging
    private let engine: PlayerEngine
    private let diagnostics: DTCPDiagnostics
    private let report: @Sendable (Event) async -> Void
    private let state = Mutex(SessionState())
    private var task: Task<Void, Never>?

    private struct SessionState {
        var body: HTTPChunkStream?
        var keySource: DTCPKeySource?
        /// 受信を待ち始めた時刻（受け取ったら nil。黙っている時間を数える）
        var waitingSince: ContinuousClock.Instant?
        var finished = false
    }

    init(url: URL, startSeconds: Double, credentialStore: any DTCPCredentialStore, client: any HTTPExchanging,
         engine: PlayerEngine, diagnostics: DTCPDiagnostics, report: @escaping @Sendable (Event) async -> Void) {
        self.url = url
        self.startSeconds = startSeconds
        self.credentialStore = credentialStore
        self.client = client
        self.engine = engine
        self.diagnostics = diagnostics
        self.report = report
    }

    /// 受信を待っている時間（受信していないときは 0）
    var silentFor: Duration {
        state.withLock { $0.waitingSince.map { ContinuousClock.now - $0 } } ?? .zero
    }

    var isFinished: Bool { state.withLock { $0.finished } }

    func run() {
        task = Task.detached { [self] in await self.pipeline() }
    }

    /// 止めて、受信の手順が終わるまで待つ
    func cancelAndWait() async {
        task?.cancel()
        let (body, keySource) = state.withLock { ($0.body, $0.keySource) }
        body?.cancel()
        await task?.value
        if let keySource { await keySource.currentSession.close() }
    }

    private func pipeline() async {
        var stage = PlaybackStage.credentials
        do {
            await report(.stage(.credentials))
            guard let credentials = try credentialStore.load() else {
                throw NasneError(category: .validation, source: "playback:credentials", messageKey: "error.noCredentials")
            }
            stage = .head
            await report(.stage(.head))
            let endpoint = try await InUseRetryPolicy.run(
                onRetry: { retry in diagnostics(.playback, "HEAD: HTTP \(LivePlaybackErrors.inUseStatus) のため頼み直す（\(retry) 回目）") },
                attempt: { try await DTCPContentHTTP.endpoint(of: url, client: client) })
            try Task.checkCancellation()

            stage = .authentication
            await report(.stage(.authentication))
            let srm = DTCPMemorySRMStore()
            let diagnostics = diagnostics
            let session = try await AKEClient(credentials: credentials, srmStore: srm, diagnostics: diagnostics)
                .connect(host: endpoint.akeHost, port: endpoint.akePort)
            _ = try await session.waitFirstExchangeKey()
            let keySource = DTCPKeySource(session: session, diagnostics: diagnostics) {
                try await AKEClient(credentials: credentials, srmStore: srm, diagnostics: diagnostics)
                    .connect(host: endpoint.akeHost, port: endpoint.akePort)
            }
            state.withLock { $0.keySource = keySource }
            try Task.checkCancellation()

            stage = .request
            await report(.stage(.request))
            var request = DTCPContentHTTP.request(url, method: "GET")
            if startSeconds > 0 {
                request.setValue("npt=\(String(format: "%.3f", startSeconds))-", forHTTPHeaderField: Self.timeSeekHeader)
            }
            let opened = try await BusyRetryPolicy.open(
                onRetry: { retry in diagnostics(.playback, "GET: HTTP \(BusyRetryPolicy.busyStatus) のため頼み直す（\(retry) 回目）") },
                attempt: {
                    let body = HTTPChunkStream(request: request, idleTimeout: PlaybackTimingPolicy.receiveIdleTimeout)
                    state.withLock { $0.body = body }
                    let response = try await body.start()
                    return ((body, response), response.statusCode)
                },
                discard: { $0.0.cancel() })
            let (body, response) = opened.value
            guard response.statusCode == 200 else { throw NasneError.http(response.statusCode, "playback:get") }
            if startSeconds > 0, let seek = response.value(forHTTPHeaderField: Self.timeSeekHeader),
               let start = Self.nptStart(seek) {
                await report(.seekStart(start))
            }

            stage = .receiving
            let decryptor = PCPDecryptor(keyForLabel: { try await keySource.key(for: $0) }, onHeader: { _ in })
            let feeder = RecordingFeeder(engine: engine)
            var iterator = body.chunks.makeAsyncIterator()
            while true {
                state.withLock { $0.waitingSince = .now }
                guard let chunk = try await iterator.next() else { break }
                state.withLock { $0.waitingSince = nil }
                body.consumed(chunk.count)
                for plain in try await decryptor.add(chunk) { try await feeder.feed(plain) }
                try Task.checkCancellation()
            }
            state.withLock {
                $0.waitingSince = nil
                $0.finished = true
            }
            try await feeder.finish(limit: PlaybackTimingPolicy.drainLimit)
            await keySource.currentSession.close()
            if !Task.isCancelled { await report(.finished) }
        } catch is CancellationError {
            return
        } catch {
            state.withLock { $0.waitingSince = nil }
            if Task.isCancelled { return }
            await report(.failed(error, stage))
        }
    }

    /// 時間指定の見出し
    static let timeSeekHeader = "TimeSeekRange.dlna.org"

    /// `npt=60.057-294.792/294.794` の始めの秒
    static func nptStart(_ value: String) -> Double? {
        guard let range = value.range(of: "npt=") else { return nil }
        return Double(value[range.upperBound...].prefix { $0 != "-" })
    }
}
