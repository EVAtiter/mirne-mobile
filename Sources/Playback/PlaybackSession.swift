import Foundation
import Synchronization

// 1 回の受信（2026-11-21 に PlaybackController.swift から分けた）

/// 同じ録画の張り直しで使い回す認証（HEAD の結果と交換鍵）。
///
/// 交換鍵は AKE の接続を閉じても `AKEClient` の中に残るので、同じ録画の中で飛ぶときは HEAD と AKE を省いて
/// 時間指定の GET から始められる（SIE 製の nasne は AKE に 0.5〜0.7 秒かかり、飛ぶたびの待ちの大半だった。2026-11-25 の実測）。
/// 受け取ったデータのラベルが手元に無ければ、`DTCPKeySource` が新しい接続で認証し直す。鍵はメモリの中だけに置く
struct PlaybackAuthentication: Sendable {
    /// 認証した録画の URL（張り直しの URL がこれと同じときだけ使い回す）
    let url: URL
    let endpoint: DTCPContentEndpoint
    let keySource: DTCPKeySource

    /// 張り直しでこの認証を使ってよいか（録画で、URL が同じとき。ライブは使い回さない）
    static func reusable(_ cached: PlaybackAuthentication?, for url: URL, kind: PlaybackKind) -> PlaybackAuthentication? {
        guard let cached, PlaybackAuthenticationPolicy.canReuse(cachedURL: cached.url, url: url, kind: kind) else { return nil }
        return cached
    }
}

/// 認証を使い回すかの決まり
enum PlaybackAuthenticationPolicy {
    static func canReuse(cachedURL: URL?, url: URL, kind: PlaybackKind) -> Bool {
        kind == .recording && cachedURL == url
    }
}

/// 1 回の受信（HEAD から最後まで）。中断すると鍵と接続を捨てる
final class PlaybackSession: @unchecked Sendable {
    enum Event: Sendable {
        case stage(PlaybackStage)
        /// HEAD と AKE を済ませた（次の張り直しで使い回せる）
        case authenticated(PlaybackAuthentication)
        case seekStart(Double)
        case finished
        case failed(any Error, PlaybackStage)
    }

    private let url: URL
    private let startSeconds: Double
    /// 使い回す認証（無ければ HEAD と AKE から始める）
    private let reusing: PlaybackAuthentication?
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

    init(url: URL, startSeconds: Double, reusing: PlaybackAuthentication? = nil, credentialStore: any DTCPCredentialStore,
         client: any HTTPExchanging, engine: PlayerEngine, diagnostics: DTCPDiagnostics,
         report: @escaping @Sendable (Event) async -> Void) {
        self.url = url
        self.startSeconds = startSeconds
        self.reusing = reusing
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
            var authentication: PlaybackAuthentication
            let reused = reusing != nil
            if let reusing {
                authentication = reusing
                diagnostics(.playback, "同じ録画なので、HEAD と認証を使い回す")
            } else {
                authentication = try await authenticate { stage = $0 }
            }
            state.withLock { $0.keySource = authentication.keySource }
            try Task.checkCancellation()

            stage = .request
            await report(.stage(.request))
            let body: HTTPChunkStream
            let response: HTTPURLResponse
            do {
                (body, response) = try await openStream()
            } catch let error where reused && !(error is CancellationError) && !Task.isCancelled {
                // 使い回した認証では受信を始められなかった。1 回だけ HEAD と AKE からやり直す
                diagnostics(.playback, "使い回した認証で受信を始められなかった（\(NasneDiagnostics.summary(error))）。認証し直す")
                authentication = try await authenticate { stage = $0 }
                state.withLock { $0.keySource = authentication.keySource }
                try Task.checkCancellation()
                stage = .request
                await report(.stage(.request))
                (body, response) = try await openStream()
            }
            if startSeconds > 0, let seek = response.value(forHTTPHeaderField: Self.timeSeekHeader),
               let start = Self.nptStart(seek) {
                await report(.seekStart(start))
            }
            let keySource = authentication.keySource

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

    /// 資格情報を読み、HEAD と AKE を済ませて、最初の交換鍵まで受け取る。済んだら制御へ知らせる（次の張り直しで使い回す）
    private func authenticate(onStage: (PlaybackStage) -> Void) async throws -> PlaybackAuthentication {
        onStage(.credentials)
        await report(.stage(.credentials))
        guard let credentials = try credentialStore.load() else {
            throw NasneError(category: .validation, source: "playback:credentials", messageKey: "error.noCredentials")
        }
        onStage(.head)
        await report(.stage(.head))
        let diagnostics = diagnostics
        let url = url
        let client = client
        let endpoint = try await InUseRetryPolicy.run(
            onRetry: { retry in diagnostics(.playback, "HEAD: HTTP \(LivePlaybackErrors.inUseStatus) のため頼み直す（\(retry) 回目）") },
            attempt: { try await DTCPContentHTTP.endpoint(of: url, client: client) })
        try Task.checkCancellation()

        onStage(.authentication)
        await report(.stage(.authentication))
        let srm = DTCPMemorySRMStore()
        let session = try await AKEClient(credentials: credentials, srmStore: srm, diagnostics: diagnostics)
            .connect(host: endpoint.akeHost, port: endpoint.akePort)
        _ = try await session.waitFirstExchangeKey()
        // 認証し直すときは HEAD から取り直す（使い回す間に飛んだ先で AKE のポートが変わっていてもよいように）
        let keySource = DTCPKeySource(session: session, diagnostics: diagnostics) {
            let fresh = try await DTCPContentHTTP.endpoint(of: url, client: client)
            return try await AKEClient(credentials: credentials, srmStore: srm, diagnostics: diagnostics)
                .connect(host: fresh.akeHost, port: fresh.akePort)
        }
        let authentication = PlaybackAuthentication(url: url, endpoint: endpoint, keySource: keySource)
        await report(.authenticated(authentication))
        return authentication
    }

    /// 時間指定の GET を送り、200 の応答を受け取る（busy なら頼み直す）
    private func openStream() async throws -> (HTTPChunkStream, HTTPURLResponse) {
        var request = DTCPContentHTTP.request(url, method: "GET")
        if startSeconds > 0 {
            request.setValue("npt=\(String(format: "%.3f", startSeconds))-", forHTTPHeaderField: Self.timeSeekHeader)
        }
        let diagnostics = diagnostics
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
        guard response.statusCode == 200 else {
            body.cancel()
            throw NasneError.http(response.statusCode, "playback:get")
        }
        return (body, response)
    }

    /// 時間指定の見出し
    static let timeSeekHeader = "TimeSeekRange.dlna.org"

    /// `npt=60.057-294.792/294.794` の始めの秒
    static func nptStart(_ value: String) -> Double? {
        guard let range = value.range(of: "npt=") else { return nil }
        return Double(value[range.upperBound...].prefix { $0 != "-" })
    }
}
