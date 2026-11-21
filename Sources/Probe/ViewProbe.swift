import AppKit
import Foundation

// 録画を画面に出して確かめる（デインターレース・A/V のずれ・描画の間に合い方）。
//
// mirne の再生の実験窓（PlaybackLab）と同じつなぎ方で、窓を 1 枚開いて VideoRenderer で描く。字幕の重ね出しは
// まだ無い（視聴ウィンドウの で）。
//
// - `view --file <TS>`：手元の TS（合成の素材）。`--snapshot <PNG のパス> --snapshot-at <秒>` で、
//   描いた絵（デインターレース後）を書き出せる（合成の素材のときだけ）
// - `view --live <番号> [--band DTTB|BS|CS] [--quality …]`：ライブの局を受信して流す（合意を取ってから 1 回だけ）
// - `view [--quality dr|x3|mobile] [--pick …] [--seek <秒>]`：nasne の録画を復号しながら流す。
//   **nasne の録画の絵は書き出さない**（復号したものをディスクに置かない）

/// PCP の鍵のラベルの移り変わり（復号の側から記録する）
final class SharedLabels: @unchecked Sendable {
    private let lock = NSLock()
    private var labels: [UInt8] = []
    func record(_ label: UInt8) { lock.withLock { if labels.last != label { labels.append(label) } } }
    var summary: String { lock.withLock { labels.isEmpty ? "なし" : "\(labels.count) 種類（変わった回数 \(labels.count - 1)）" } }
}

@MainActor
enum ViewCommand {
    /// 窓の大きさ（16:9）
    static let windowSize = NSSize(width: 1280, height: 720)
    /// 既定の再生の秒数
    static let defaultSeconds = 30.0
    /// 統計を出す間隔
    static let reportInterval: Duration = .seconds(10)

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let engine = PlayerEngine()
        engine.isMuted = flag("--mute")
        guard let renderer = VideoRenderer(frames: engine.frames) else { fail("Metal の描画を作れない") }
        renderer.clock = { engine.presentationTime() }
        renderer.mediaTimeAtHost = { engine.mediaTime(atHost: $0) }
        renderer.clockEpoch = { engine.clockEpoch }
        let modeName = option("--deinterlace") ?? "adaptive"
        guard let mode = DeinterlaceMode.allCases.first(where: { String(describing: $0) == modeName }) else {
            fail("--deinterlace は adaptive・bob・weave")
        }
        renderer.deinterlace = mode
        currentRenderer = renderer

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: windowSize),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "mirne mobile（検証・\(modeName)）"
        window.contentView = renderer.view
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate()

        Task { @MainActor in
            do {
                let started = ContinuousClock.now
                let reporter = Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: reportInterval)
                        if !Task.isCancelled { report(engine: engine, renderer: renderer, started: started, final: false) }
                    }
                }
                if let path = option("--file") {
                    try await playFile(path, engine: engine, renderer: renderer)
                } else if option("--live") != nil {
                    try await playLive(engine: engine)
                } else {
                    guard option("--snapshot") == nil else { fail("--snapshot は --file（合成の素材）のときだけ使える") }
                    try await playRecording(engine: engine)
                }
                reporter.cancel()
                report(engine: engine, renderer: renderer, started: started, final: true)
            } catch {
                say("誤り: \(error)")
            }
            engine.stop()
            exit(0)
        }
        app.run()
        exit(0)
    }

    /// 手元の TS を流す（RecordingFeeder の先読みの抑えで、再生の速さに合わせて読む）
    static func playFile(_ path: String, engine: PlayerEngine, renderer: VideoRenderer) async throws {
        let seconds = option("--seconds").flatMap(Double.init) ?? defaultSeconds
        let snapshotPath = option("--snapshot")
        let snapshotAt = option("--snapshot-at").flatMap(Double.init) ?? 3
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let feeder = RecordingFeeder(engine: engine)
        let clock = ContinuousClock()
        let started = clock.now
        var snapshotTaken = false
        while let chunk = try handle.read(upToCount: PlayCommand.readChunk), !chunk.isEmpty {
            try await feeder.feed(chunk)
            let elapsed = StreamCommand.seconds(clock.now - started)
            if let snapshotPath, !snapshotTaken, elapsed >= snapshotAt {
                renderer.requestSnapshot(to: URL(fileURLWithPath: snapshotPath))
                say("スナップショットを頼んだ（\(String(format: "%.1f", elapsed)) 秒）")
                snapshotTaken = true
            }
            if elapsed >= seconds { break }
        }
        // 先読みしたぶんを出し切る（上限つき）
        try await feeder.finish(limit: PlayCommand.drainLimit)
    }

    /// nasne の録画を HEAD → AKE → GET → PCP の復号で受け、再生の系に流す（stream と同じ手順。数え上げはしない）
    static func playRecording(engine: PlayerEngine) async throws {
        let seconds = option("--seconds").flatMap(Double.init) ?? defaultSeconds
        guard let credentials = try DTCPKeychainCredentialStore().load() else {
            fail("資格情報がない。先に credentials import で取り込む")
        }
        let picked = try await RecordingPicker.pick().title
        let wanted = option("--quality")
        guard let resource = wanted.map({ quality in picked.playableResources.first { $0.quality == quality } }) ?? picked.originalResource,
              let url = URL(string: resource.url) else { fail("その画質の res がない") }
        say("録画: 長さ \(picked.durationSeconds ?? 0) 秒・画質 \(resource.quality ?? "なし")")
        let endpoint = try await DTCPContentHTTP.endpoint(of: url, client: client)
        let diagnostics = DTCPDiagnostics { _, _ in }
        let srm = DTCPMemorySRMStore()
        let session = try await AKEClient(credentials: credentials, srmStore: srm, diagnostics: diagnostics)
            .connect(host: endpoint.akeHost, port: endpoint.akePort)
        _ = try await session.waitFirstExchangeKey()
        let keySource = DTCPKeySource(session: session, diagnostics: diagnostics) {
            try await AKEClient(credentials: credentials, srmStore: srm, diagnostics: diagnostics)
                .connect(host: endpoint.akeHost, port: endpoint.akePort)
        }
        let decryptor = PCPDecryptor(keyForLabel: { try await keySource.key(for: $0) }, onHeader: { _ in })
        var request = DTCPContentHTTP.request(url, method: "GET")
        if let seek = option("--seek") { request.setValue("npt=\(seek)-", forHTTPHeaderField: HeadCommand.timeSeekHeader) }
        let body = HTTPChunkStream(request: request)
        let response = try await body.start()
        guard response.statusCode == 200 else { fail("GET: HTTP \(response.statusCode)") }
        say("受信を始めた")
        let feeder = RecordingFeeder(engine: engine)
        let clock = ContinuousClock()
        let started = clock.now
        // --pause-at <秒>（受信を始めてから）・--pause-for <秒>：一時停止して、止めている間に描けているかを 1 秒ごとに出す
        let pauseAt = option("--pause-at").flatMap(Double.init)
        let pauseFor = option("--pause-for").flatMap(Double.init) ?? 5
        var pauseTask: Task<Void, Never>?
        for try await chunk in body.chunks {
            body.consumed(chunk.count)
            for plain in try await decryptor.add(chunk) { try await feeder.feed(plain) }
            let elapsed = StreamCommand.seconds(clock.now - started)
            if let pauseAt, pauseTask == nil, elapsed >= pauseAt, let renderer = currentRenderer {
                pauseTask = Task { @MainActor in await pauseCheck(engine: engine, renderer: renderer, seconds: pauseFor) }
            }
            if elapsed >= seconds + (pauseAt == nil ? 0 : pauseFor) { break }
        }
        await pauseTask?.value
        body.cancel()
        await keySource.currentSession.close()
    }

    /// 一時停止の確かめで使う描画（run で入れる）
    static var currentRenderer: VideoRenderer?

    /// 一時停止して、止めている間の描画の回数・描いた数・空振りを 1 秒ごとに出す
    static func pauseCheck(engine: PlayerEngine, renderer: VideoRenderer, seconds: Double) async {
        let delayBefore = renderer.presentationDelayMilliseconds
        engine.pause()
        say("一時停止（\(seconds) 秒）・見込みの遅れ \(String(format: "%.1f", delayBefore)) ms")
        var last = renderer.statistics
        for second in 1...max(1, Int(seconds)) {
            try? await Task.sleep(for: .seconds(1))
            let now = renderer.statistics
            say("  止めて \(second) 秒: 描画 \(now.calls - last.calls)・描いた \(now.drawn - last.drawn)・空振り \(now.starved - last.starved)"
                + "・見込みの遅れ \(String(format: "%.1f", renderer.presentationDelayMilliseconds)) ms"
                + "・フレーム \(engine.frames.count) 枚・一番早いものは時計より "
                + "\(engine.frames.earliestPTS.flatMap { pts in engine.presentationTime().map { String(format: "%+.0f ms", Double(pts - $0) / 90) } } ?? "-")")
            last = now
        }
        engine.resume()
        say("再開")
    }

    /// ライブの受信で、録画中・予約がないことを確かめる時間の幅（いまからこの秒数のあいだに予約が重なれば止める）
    static let liveScheduleGuard: TimeInterval = 3600
    /// ライブの受信の途中で、nasne の選局の状態を読む時機（受信を始めてからの秒数）
    static let liveStatusCheckAt = 5.0

    /// ライブの局を受信して流す（合意を取ってから 1 回だけ）。
    /// 録画中のものがあるか、この先 1 時間に予約があれば、nasne に HEAD も GET も送らずに止まる
    static func playLive(engine: PlayerEngine) async throws {
        let seconds = option("--seconds").flatMap(Double.init) ?? defaultSeconds
        let bandName = option("--band") ?? NasneProfiles.standard.dlna.liveBandSuffixes[BroadcastingType.terrestrial] ?? ""
        guard let index = option("--live").flatMap(Int.init) else { fail("--live は帯域の中の番号（0 から）") }
        guard let credentials = try DTCPKeychainCredentialStore().load() else {
            fail("資格情報がない。先に credentials import で取り込む")
        }
        let (device, registration) = try await connect(requiredHost())
        let catalog = RecordingCatalogService(soap: SOAPTransport(client: client), device: device)
        // 録画を妨げないための確かめ（読み取りだけ）
        let recording = try await catalog.titles(withMetadata: false).filter(\.isRecording).count
        let now = Date()
        let upcoming = try await catalog.schedules().filter { $0.end > now && $0.start < now.addingTimeInterval(liveScheduleGuard) }.count
        say("録画中 \(recording) 件・この先 1 時間に重なる予約 \(upcoming) 件")
        guard recording == 0, upcoming == 0 else { fail("録画中のものか、この先 1 時間に予約があるので、ライブの受信をしない") }
        let info = WebAPIDeviceInfoService(transport: WebAPITransport(host: registration.host, client: client))
        func tuning(_ label: String) async {
            let status = try? await info.liveStatus()
            say("選局の状態（\(label)）: tuningStatus \(status?.tuningStatus.map(String.init) ?? "読めない")")
        }
        await tuning("HEAD の前")

        let bands = try await DLNALiveCatalogService(catalog: catalog).bands()
        guard let band = bands.first(where: { $0.containerID.hasSuffix("/" + bandName) }) else { fail("帯域 \(bandName) がない") }
        guard band.channels.indices.contains(index) else { fail("帯域 \(bandName) の局は 0〜\(band.channels.count - 1)") }
        let channel = band.channels[index]
        let wanted = option("--quality")
        guard let resource = wanted.map({ quality in channel.resources.first { $0.quality == quality } }) ?? channel.originalResource,
              let url = URL(string: resource.url) else { fail("その画質の res がない") }
        say("局: 帯域 \(bandName) の \(index) 番（局名は出さない）・画質 \(resource.quality ?? "なし")")

        let clock = ContinuousClock()
        var stage = clock.now
        let endpoint = try await DTCPContentHTTP.endpoint(of: url, client: client)
        say("HEAD: \((clock.now - stage).wholeMilliseconds) ms・AKE の相手 nasne と\(endpoint.akeHost == registration.host ? "同じ" : "別")")
        say("  contentFeatures: \(endpoint.contentFeatures.map { ContentFeaturesReport.line(DLNAContentFeatures($0)) } ?? "なし")")
        await tuning("HEAD の後")

        let diagnostics = DTCPDiagnostics { _, _ in }
        let srm = DTCPMemorySRMStore()
        stage = clock.now
        let session = try await AKEClient(credentials: credentials, srmStore: srm, diagnostics: diagnostics)
            .connect(host: endpoint.akeHost, port: endpoint.akePort)
        _ = try await session.waitFirstExchangeKey()
        say("AKE: 交換鍵まで \((clock.now - stage).wholeMilliseconds) ms")
        let keySource = DTCPKeySource(session: session, diagnostics: diagnostics) {
            try await AKEClient(credentials: credentials, srmStore: srm, diagnostics: diagnostics)
                .connect(host: endpoint.akeHost, port: endpoint.akePort)
        }
        let labels = SharedLabels()
        let decryptor = PCPDecryptor(keyForLabel: { try await keySource.key(for: $0) },
                                     onHeader: { labels.record($0.exchangeKeyLabel) })
        stage = clock.now
        let body = HTTPChunkStream(request: DTCPContentHTTP.request(url, method: "GET"))
        let response = try await body.start()
        say("GET: HTTP \(response.statusCode)・見出しまで \((clock.now - stage).wholeMilliseconds) ms・Content-Length \(response.expectedContentLength)")
        guard response.statusCode == 200 else {
            body.cancel()
            await keySource.currentSession.close()
            return
        }
        let inspector = StreamInspector()
        let feeder = RecordingFeeder(engine: engine)
        let started = clock.now
        var received = 0
        var checked = false
        var endReason = "計測の時間に達した"
        do {
            for try await chunk in body.chunks {
                body.consumed(chunk.count)
                received += chunk.count
                for plain in try await decryptor.add(chunk) {
                    inspector.feed(plain)
                    try await feeder.feed(plain)
                }
                let elapsed = StreamCommand.seconds(clock.now - started)
                if !checked, elapsed >= liveStatusCheckAt {
                    checked = true
                    await tuning("受信の途中")
                }
                if elapsed >= seconds { break }
            }
        } catch {
            endReason = "受信が誤りで終わった（\(error)）"
        }
        let receiveSeconds = StreamCommand.seconds(clock.now - started)
        body.cancel()
        await keySource.currentSession.close()
        say("")
        say("受信: \(received / 1024) KiB・\(String(format: "%.1f", receiveSeconds)) 秒・\(String(format: "%.2f MB/s", Double(received) / receiveSeconds / 1_000_000))・\(endReason)")
        say("PCP のラベル: \(labels.summary)")
        inspector.report()
        await tuning("受信を止めた後")
    }

    /// 描画と再生の統計（mirne の PlaybackLab の summary の要るところ）
    static func report(engine: PlayerEngine, renderer: VideoRenderer, started: ContinuousClock.Instant, final: Bool) {
        let elapsed = StreamCommand.seconds(ContinuousClock.now - started)
        let render = renderer.statistics
        let playback = engine.statistics
        let decoder = engine.decoder
        say("")
        say("\(final ? "【最後】" : "【途中】")経過 \(String(format: "%.1f", elapsed)) 秒・\(render.lastSize)・デインターレース \(renderer.deinterlace)"
            + "・描画の大きさ \(Int(renderer.drawableSize.width))×\(Int(renderer.drawableSize.height))")
        say(String(format: "描画: %.1f 回/秒・描いた %d・空振り %d・選んだフィールドの遅れの最大 %.1f ms・draw の最大 %.1f ms",
                   Double(render.calls) / max(elapsed, 0.001), render.drawn, render.starved, render.maximumLateness, render.maximumDrawTime)
            + "・動き適応 \(render.adaptiveFields)・bob にした \(render.adaptiveFallbacks)")
        if let sync = renderer.avSync.summary {
            say(String(format: "A/V のずれ（画面に出た時刻 − PTS。正は映像が遅れ）: 中央 %.1f ms・5〜95%% %.1f〜%.1f ms・最小 %.1f・最大 %.1f（%d 回）・描いてから出るまで %.1f ms",
                       sync.p50, sync.p5, sync.p95, sync.minimum, sync.maximum, sync.count, renderer.presentationDelayMilliseconds))
        }
        say("再生: 開始 \(playback.firstStartDelay.map { "\($0.wholeMilliseconds) ms" } ?? "-")・時計の張り直し \(playback.discontinuities)"
            + "・遅れて捨てた \(engine.frames.lateDrops)・溢れて捨てた \(engine.frames.overflowDrops)・復号の失敗 \(decoder.decodeErrors)"
            + "・音声 \(playback.audioFrames) フレーム（失敗 \(playback.audioFailures)）\(engine.isMuted ? "・音は消している" : "")")
    }
}
