import CoreMedia
import Foundation
import Synchronization

// 計測：資格情報ペアの取り込み（Keychain）と、HEAD → AKE → GET → PCP の復号 → TS の中身の数え上げ。
//
// 守ること（§4）:
// - ペアの値・鍵・nonce・PIN を出さない。資格情報から出してよいのは機器 ID と証明書の指紋だけ
// - 復号した TS はメモリの中だけで数え、ディスクに書かない
// - 番組名・局名・アドレス・ポートを出さない。出すのは件数・長さ・時間・形だけ
// - nasne には読み取り（HEAD・GET）しか送らない

// MARK: - 資格情報

@MainActor
enum CredentialsCommand {
    /// 証明書・秘密鍵の長さ
    static let certificateLength = DTCPCertificate.length
    static let privateKeyLength = DTCPCredentials.privateKeyLength

    static func run(_ action: String?) throws {
        let store = DTCPKeychainCredentialStore()
        switch action {
        case "import":
            let certificate: [UInt8]
            let privateKey: [UInt8]
            if let envPath = option("--env") {
                // pydtcpip の credentials.env（PYDTCPIP_CERTIFICATE・PYDTCPIP_PRIVATE_KEY）から 2 つを読む
                (certificate, privateKey) = try DTCPCredentialInput.decodeDotEnv(
                    try read(envPath), certificateLength: certificateLength, privateKeyLength: privateKeyLength)
            } else if let certificatePath = option("--cert"), let keyPath = option("--key") {
                certificate = try DTCPCredentialInput.decode(try read(certificatePath), expectedLength: certificateLength,
                                                             name: "certificate")
                privateKey = try DTCPCredentialInput.decode(try read(keyPath), expectedLength: privateKeyLength,
                                                            name: "private key")
            } else {
                fail("credentials import --cert <証明書のファイル> --key <秘密鍵のファイル>\n"
                     + "   または credentials import --env <pydtcpip の credentials.env>")
            }
            try store.save(certificate: certificate, privateKey: privateKey)
            say("取り込んだ（Keychain・従来のログインキーチェーン）")
            try show(store)
            say("（元のファイルは、このコマンドは消さない。置き場所は利用者が管理する）")
        case "show":
            try show(store)
        case "delete":
            try store.delete()
            say("消した")
        default:
            fail("credentials <import|show|delete>")
        }
    }

    private static func read(_ path: String) throws -> Data {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            // パスは利用者のものなので、誤りの文言に出さない
            throw DTCPError.validation("dtcp:input", "could not read the file")
        }
    }

    private static func show(_ store: DTCPKeychainCredentialStore) throws {
        guard let credentials = try store.load() else {
            say("資格情報: なし")
            return
        }
        let summary = credentials.summary
        say("資格情報: あり・機器 ID \(summary.deviceIDHex)・証明書の SHA-1 \(summary.certificateSHA1Hex)")
    }
}

// MARK: - 録画の選び方（stream・head で共通）

@MainActor
enum RecordingPicker {
    /// `--pick`（shortest・longest・短い順の番号）で録画を 1 つ選ぶ。録画中・res の無い・長さの無いものは除く。
    /// `--quality` があれば、その画質の res のある録画だけから選ぶ（3倍で録った録画には dr が無い）
    static func pick() async throws -> (title: RecordedTitle, all: [RecordedTitle]) {
        let (device, _) = try await connect(requiredHost())
        let titles = try await RecordingCatalogService(soap: SOAPTransport(client: client), device: device).titles()
        let wanted = option("--quality")
        let candidates = titles.filter { !$0.isRecording && !$0.resources.isEmpty && ($0.durationSeconds ?? 0) > 0 }
            .filter { title in wanted.map { quality in title.playableResources.contains { $0.quality == quality } } ?? true }
            .sorted { ($0.durationSeconds ?? 0) < ($1.durationSeconds ?? 0) }
        guard !candidates.isEmpty else { fail("再生できる録画がない\(wanted.map { "（画質 \($0) の res のある録画が無い）" } ?? "")") }
        // --at "yyyy-MM-dd HH:mm"（日本時間）：その分に始まった録画を選ぶ（利用者が日時で教えてくれた録画を測るため）
        if let at = option("--at") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ja_JP")
            formatter.timeZone = NasneDateTime.timeZone
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            let matched = candidates.filter { $0.start.map(formatter.string) == at }
            guard matched.count == 1, let title = matched.first else { fail("--at \(at) に始まった録画が \(matched.count) 件") }
            return (title, titles)
        }
        switch option("--pick") ?? "shortest" {
        case "shortest": return (candidates[0], titles)
        case "longest": return (candidates[candidates.count - 1], titles)
        case let text:
            guard let index = Int(text), candidates.indices.contains(index) else {
                fail("--pick は shortest・longest か、短い順の番号（0〜\(candidates.count - 1)）")
            }
            return (candidates[index], titles)
        }
    }
}

// MARK: - 計測

@MainActor
enum StreamCommand {
    /// 受信を続ける既定の秒数
    static let defaultSeconds = 20.0
    /// 音声の PES の PTS の飛びと見なす差（90 kHz。200 ms）
    nonisolated static let audioGapThreshold: Int64 = 18_000
    /// 音声の PTS の飛びを並べる上限
    nonisolated static let audioGapListLimit = 10
    /// 受信の上限の既定（MiB）
    static let defaultMaxMiB = 256
    /// AKE の接続が閉じたかを見に行く間隔
    static let akeWatchInterval: Duration = .milliseconds(20)
    /// 字幕の component_tag の範囲（ARIB TR-B14。0x30〜0x37 が字幕、0x38〜0x3F が文字スーパー）
    nonisolated static let captionTags: ClosedRange<UInt8> = 0x30...0x37
    nonisolated static let superimposeTags: ClosedRange<UInt8> = 0x38...0x3F
    /// 一時停止を測るときに、こちらの打ち切りを止める時間より長くするぶん（秒）
    nonisolated static let pauseTimeoutMargin: TimeInterval = 120
    /// PTS の刻み（90 kHz）
    nonisolated static let ptsClock = 90_000.0

    static func run() async throws {
        let receiveLimit = option("--seconds").flatMap(Double.init) ?? defaultSeconds
        let maxBytes = (option("--max-mib").flatMap(Int.init) ?? defaultMaxMiB) * 1024 * 1024
        let wantedQuality = option("--quality")   // dr・x3・mobile。無ければ元画質
        let clock = ContinuousClock()
        let origin = clock.now
        @Sendable func at() -> String { String(format: "%7.0f ms", seconds(clock.now - origin) * 1000) }
        let verbose = flag("--verbose")
        let diagnostics = DTCPDiagnostics { category, message in
            if verbose { print("  [\(at())] \(category.rawValue): \(message)") }
        }

        // 資格情報（先に確かめる。無ければ nasne に何も送らない）
        guard let credentials = try DTCPKeychainCredentialStore().load() else {
            fail("資格情報がない。先に credentials import で取り込む")
        }
        say("[\(at())] 資格情報: 読めた（機器 ID \(credentials.summary.deviceIDHex)）")

        // 録画を選ぶ（番組名は出さない）
        let picked = try await RecordingPicker.pick().title
        let resource: TitleResource?
        if let wantedQuality {
            resource = picked.playableResources.first { $0.quality == wantedQuality }
        } else {
            resource = picked.originalResource
        }
        guard let resource, let url = URL(string: resource.url) else {
            fail("その画質の res がない（ある画質: \(picked.resources.compactMap(\.quality).joined(separator: "・"))）")
        }
        say("[\(at())] 録画: 長さ \(picked.durationSeconds ?? 0) 秒・録り始めから番組の開始まで \(picked.programStartOffsetSeconds.map { String(format: "%.0f 秒", $0) } ?? "-")・画質 \(resource.quality ?? "なし")"
            + "・cleartextSize \(resource.cleartextSize.map { "\($0 / 1_048_576) MiB" } ?? "なし")")

        // HEAD
        let headStart = clock.now
        let endpoint = try await DTCPContentHTTP.endpoint(of: url, client: client)
        say("[\(at())] HEAD: \((clock.now - headStart).wholeMilliseconds) ms・AKE の相手あり（ポートは毎回変わる）")
        say("  contentFeatures: \(endpoint.contentFeatures.map { ContentFeaturesReport.line(DLNAContentFeatures($0)) } ?? "なし")")

        // AKE
        let srm = DTCPMemorySRMStore()
        let akeStart = clock.now
        let akeClient = AKEClient(credentials: credentials, srmStore: srm, diagnostics: diagnostics)
        let session = try await akeClient.connect(host: endpoint.akeHost, port: endpoint.akePort)
        say("[\(at())] AKE: 認証 \((clock.now - akeStart).wholeMilliseconds) ms")
        let firstLabel = try await session.waitFirstExchangeKey()
        say("[\(at())] AKE: 交換鍵を受け取った（ラベル \(firstLabel)）")
        let akeClosed = Mutex<String?>(nil)
        let watcher = Task {
            while !Task.isCancelled {
                if await akeClient.loopEnded {
                    akeClosed.withLock { $0 = at() }
                    return
                }
                try? await Task.sleep(for: akeWatchInterval)
            }
        }
        let reauthentications = Mutex(0)
        let keySource = DTCPKeySource(session: session, diagnostics: diagnostics) {
            reauthentications.withLock { $0 += 1 }
            let fresh = AKEClient(credentials: credentials, srmStore: srm, diagnostics: diagnostics)
            return try await fresh.connect(host: endpoint.akeHost, port: endpoint.akePort)
        }

        // GET → PCP → TS
        let headers = Mutex<[(at: String, summary: PCPHeaderSummary)]>([])
        let decryptor = PCPDecryptor(keyForLabel: { try await keySource.key(for: $0) },
                                     onHeader: { summary in headers.withLock { $0.append((at(), summary)) } })
        let inspector = StreamInspector()
        // --play：復号した TS を録画の再生の系にも流す（メモリの中だけ。先読みが溜まると受信も待つ）
        var playback: (feeder: RecordingFeeder, monitor: PlaybackMonitor)?
        if flag("--play") {
            let engine = PlayerEngine()
            let monitor = PlaybackMonitor(engine: engine)
            monitor.start()
            playback = (RecordingFeeder(engine: engine), monitor)
        }
        let getStart = clock.now
        // 本文は届いた塊のまま受け取る（1 バイトずつの AsyncBytes では 0.17 MB/s しか出なかった）
        // --seek <秒>：時間指定（TimeSeekRange.dlna.org）、--range <バイト>：平文のバイトの位置（Range.dtcp.com）
        var getRequest = DTCPContentHTTP.request(url, method: "GET")
        if let seek = option("--seek") { getRequest.setValue("npt=\(seek)-", forHTTPHeaderField: HeadCommand.timeSeekHeader) }
        if let offset = option("--range") { getRequest.setValue("bytes=\(offset)-", forHTTPHeaderField: HeadCommand.dtcpRangeHeader) }
        // 一時停止を測るときは、こちらの打ち切り（データが届かない時間）を止める時間より長くする（nasne の振る舞いを見るため）
        let idleTimeout = option("--pause-for").flatMap(Double.init).map { $0 + StreamCommand.pauseTimeoutMargin }
            ?? HTTPChunkStream.defaultIdleTimeout
        let body = HTTPChunkStream(request: getRequest, idleTimeout: idleTimeout)
        let http = try await body.start()
        guard http.statusCode == 200 else { fail("GET: HTTP \(http.statusCode)") }
        say("[\(at())] GET: 見出しまで \((clock.now - getStart).wholeMilliseconds) ms・Content-Length \(http.expectedContentLength)")
        for name in [HeadCommand.timeSeekHeader, "Content-Range.dtcp.com", "Content-Range"] {
            if let value = http.value(forHTTPHeaderField: name) { say("  \(name): \(value)") }
        }
        var received = 0
        var firstCipher: String?
        var firstPlain: String?
        // --play で --pause-at <秒>（最初に表示したフレームからの時計の秒）・--pause-for <秒>：一時停止して、
        // nasne が止めた受信をどれだけ待つかを見る。止めている間は受信のループも止まる
        let pauseAt = option("--pause-at").flatMap(Double.init)
        let pauseFor = option("--pause-for").flatMap(Double.init) ?? 0
        var pauseTask: Task<Void, Never>?
        let receiveStart = clock.now
        let deadline = receiveStart + .milliseconds(Int((receiveLimit + (pauseAt == nil ? 0 : pauseFor)) * 1000))
        var stoppedByUs = false
        var endReason = "最後まで受け取った"
        do {
            for try await chunk in body.chunks {
                body.consumed(chunk.count)
                if firstCipher == nil { firstCipher = at() }
                received += chunk.count
                for plain in try await decryptor.add(chunk) {
                    if firstPlain == nil { firstPlain = at() }
                    inspector.feed(plain)
                    try await playback?.feeder.feed(plain)
                }
                if let playback, let pauseAt, pauseTask == nil, let now = playback.monitor.mediaSeconds,
                   let first = playback.monitor.firstFrame, now - Double(first.pts) / 90_000 >= pauseAt {
                    say("[\(at())] 一時停止（\(pauseFor) 秒）")
                    pauseTask = Task { await PlayCommand.pauseCheck(engine: playback.feeder.engine, monitor: playback.monitor, seconds: pauseFor) }
                }
                if clock.now >= deadline || received >= maxBytes { stoppedByUs = true; break }
            }
        } catch {
            endReason = "受信が誤りで終わった（\(error)）"
        }
        if !stoppedByUs { say("[\(at())] 受信が計測の途中で終わった: \(endReason)") }
        await pauseTask?.value
        body.cancel()
        let receiveSeconds = seconds(clock.now - receiveStart)
        watcher.cancel()
        await keySource.currentSession.close()

        // 結果
        say("")
        say("受信: \(received / 1024) KiB・\(String(format: "%.1f", receiveSeconds)) 秒・"
            + String(format: "%.2f MB/s", Double(received) / receiveSeconds / 1_000_000)
            + "・最初の暗号文 \(firstCipher ?? "なし")・最初の平文 \(firstPlain ?? "なし")・受信を止めた \(body.suspensions) 回")
        say("AKE の接続が閉じた: \(akeClosed.withLock { $0 } ?? "計測の間は閉じなかった")・認証し直し \(reauthentications.withLock { $0 }) 回")
        let summaries = headers.withLock { $0 }
        let lengths = Dictionary(grouping: summaries.map(\.summary.contentLength), by: { $0 }).mapValues(\.count)
        say("PCP: \(summaries.count) 個・E-EMI \(Set(summaries.map(\.summary.encryptionMode)).sorted().map { String(format: "0x%X", $0) }.joined(separator: "・"))"
            + "・長さ \(lengths.sorted { $0.key > $1.key }.prefix(4).map { "\($0.key) バイト×\($0.value)" }.joined(separator: "・"))")
        var lastLabel: UInt8?
        for (time, summary) in summaries where summary.exchangeKeyLabel != lastLabel {
            say("  ラベル \(summary.exchangeKeyLabel)（\(time) から）")
            lastLabel = summary.exchangeKeyLabel
        }
        inspector.report()
        if let playback {
            say("")
            say("再生（--play。受信は先読みに合わせて待つので、上の受信速度は回線の速さではない）:")
            playback.monitor.stop()
            playback.monitor.report(feeder: playback.feeder)
            playback.feeder.engine.stop()
        }
    }

    nonisolated static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

}

/// 復号した TS を数える（メモリの中だけ。番組の中身は保持しない）
final class StreamInspector {
    private let framer = TSFramer()
    private let demuxer = TSDemuxer()
    private var programChanges = 0
    private var program: ProgramMap?
    private var pesCount: [UInt16: Int] = [:]
    private var pesBytes: [UInt16: Int] = [:]
    private var damaged: [UInt16: Int] = [:]
    private var videoSize: ElementaryStreamFormat.VideoSize?
    private var audioFormats: [UInt16: ElementaryStreamFormat.AACFormat] = [:]
    private var firstVideoPTS: Int64?
    private var lastVideoPTS: Int64?
    /// H.264 のピクチャの組み方（フィールド・pic_struct・GOP・open GOP の頭）
    private var h264Survey = H264StructureSurvey()
    /// PMT が変わるたびの中身（版・ES の種類の並び）
    private var programHistory: [String] = []
    /// 音声の ES ごとの頭の様子（再生の始めの音の崩れを調べる）
    private var audioHeads: [UInt16: AudioHead] = [:]
    /// `--audio-levels <秒>`：最初の音声の ES を頭からその秒数だけ復号し、フレームごとの大きさを出す（音の中身は保持しない）
    private let levelSeconds = option("--audio-levels").flatMap(Double.init)
    private let levelDecoder = AACDecoder()
    private var levelLines: [String] = []
    private var levelFirstPTS: Int64?
    /// 最初のランダムアクセスの点（MPEG-2 はシーケンスヘッダ付きの I。再生を始められる最初の映像）
    private var firstRandomAccessPTS: Int64?

    /// 音声の ES の頭の様子
    struct AudioHead {
        var firstPTS: Int64?
        var lastPTS: Int64?
        var pes = 0
        var frames = 0
        var damaged = 0
        /// ADTS のフレームの頭が同期語でなかった・長さが合わなかった PES
        var broken = 0
        /// 形（object・Hz・channel_configuration）が変わった時刻と新しい形
        var changes: [(pts: Int64, format: String)] = []
        /// PTS の飛び（前の PES からの差が 0 以下か 200 ms を超える）
        var gaps: [(pts: Int64, delta: Int64)] = []
        var lastFormat: String?
        /// フレームの頭の要素の並び（PCE の中身つき）ごとのフレーム数と、最初に現れた時刻
        var leading: [String: (count: Int, firstPTS: Int64)] = [:]
    }

    func feed(_ data: Data) {
        let packets = framer.feed(data)
        guard !packets.isEmpty else { return }
        for event in demuxer.feed(packets) {
            switch event {
            case .program(let map):
                programChanges += 1
                program = map
                let kinds = map.streams.map { String(format: "%02X", $0.streamType) }.joined(separator: " ")
                programHistory.append("版 \(map.version)・映像の PTS \(lastVideoPTS.map { String(format: "%.1f 秒", Double($0) / StreamCommand.ptsClock) } ?? "まだ")・stream_type \(kinds)")
            case .pes(let pes):
                pesCount[pes.pid, default: 0] += 1
                pesBytes[pes.pid, default: 0] += pes.payload.count
                if pes.damaged { damaged[pes.pid, default: 0] += 1 }
                guard let stream = program?.streams.first(where: { $0.pid == pes.pid }) else { continue }
                switch stream.streamType {
                case ElementaryStream.mpeg2Video, ElementaryStream.h264:
                    if videoSize == nil {
                        videoSize = stream.streamType == ElementaryStream.h264
                            ? ElementaryStreamFormat.h264Size(pes.payload) : ElementaryStreamFormat.mpeg2SequenceSize(pes.payload)
                    }
                    if stream.streamType == ElementaryStream.h264 { h264Survey.add(pes.payload, pts: pes.pts) }
                    if firstRandomAccessPTS == nil, let pts = pes.pts,
                       VideoCodec.isRandomAccess(pes.payload, streamType: stream.streamType) { firstRandomAccessPTS = pts }
                    if let pts = pes.pts {
                        if firstVideoPTS == nil { firstVideoPTS = pts }
                        lastVideoPTS = pts
                    }
                case ElementaryStream.aacADTS:
                    if audioFormats[pes.pid] == nil { audioFormats[pes.pid] = ElementaryStreamFormat.adts(pes.payload) }
                    surveyAudio(pes)
                    if pes.pid == program?.audio.first?.pid { measureLevels(pes) }
                default: break
                }
            default: break
            }
        }
    }

    func report() {
        say("TS: パケット長 \(framer.framing.map { "\($0.rawValue) バイト" } ?? "決まらなかった")・パケット \(framer.packets) 個"
            + "・頭で読み飛ばし \(framer.leadingSkippedBytes) バイト・同期の探し直し \(framer.resynchronizations) 回")
        say("PAT の番組: \(demuxer.programs.count) 個・PMT の変化 \(programChanges) 回")
        for (index, entry) in programHistory.enumerated() { say("  PMT \(index + 1): \(entry)") }
        guard let program else {
            say("PMT: 読めなかった")
            return
        }
        say("PMT: ES \(program.streams.count) 本・ECM \(program.ecmPIDs.isEmpty ? "なし" : "あり")")
        for stream in program.streams {
            var kind = String(format: "stream_type 0x%02X", stream.streamType)
            switch stream.streamType {
            case ElementaryStream.mpeg2Video: kind += "（MPEG-2 映像）"
            case ElementaryStream.h264: kind += "（H.264）"
            case ElementaryStream.aacADTS: kind += "（AAC）"
            case ElementaryStream.privatePES:
                if let tag = stream.componentTag, StreamCommand.captionTags.contains(tag) { kind += "（字幕）" }
                else if let tag = stream.componentTag, StreamCommand.superimposeTags.contains(tag) { kind += "（文字スーパー）" }
                else { kind += "（私的）" }
            default: break
            }
            var line = "  \(kind)・component_tag \(stream.componentTag.map { String(format: "0x%02X", $0) } ?? "なし")"
                + "・PES \(pesCount[stream.pid] ?? 0) 個 / \((pesBytes[stream.pid] ?? 0) / 1024) KiB"
            if let lost = damaged[stream.pid] { line += "・欠け \(lost)" }
            if let format = audioFormats[stream.pid] {
                line += "・AAC object \(format.objectType)・\(format.sampleRate.map(String.init) ?? "?") Hz・channel_configuration \(format.channelConfiguration)"
            }
            say(line)
        }
        if let videoSize { say("映像の大きさ: \(videoSize.width)×\(videoSize.height)") }
        if let first = firstVideoPTS {
            say(String(format: "最初の映像の PTS: %.3f 秒（33 ビットの値 ÷ 90 kHz）", Double(first) / StreamCommand.ptsClock))
        }
        if let first = firstVideoPTS, let access = firstRandomAccessPTS {
            say(String(format: "最初のランダムアクセスの点: 映像の最初から %+.3f 秒", Double(access - first) / StreamCommand.ptsClock))
        }
        if let first = firstVideoPTS, let last = lastVideoPTS {
            let span = Double((last - first + (1 << 33)) % (1 << 33)) / StreamCommand.ptsClock
            say(String(format: "映像の PTS の幅: %.1f 秒", span))
        }
        reportH264()
        reportAudioHeads()
        if !levelLines.isEmpty {
            say("音の大きさ（最初の音声・PTS の秒・フレームごと）: 復号 \(levelDecoder.decodedFrames)・失敗 \(levelDecoder.failures)")
            for line in levelLines { say(line) }
        }
    }

    /// 音声の PES を 1 つ数える（ADTS のフレームを頭から辿る）
    private func surveyAudio(_ pes: PESPacket) {
        var head = audioHeads[pes.pid] ?? AudioHead()
        head.pes += 1
        if pes.damaged { head.damaged += 1 }
        if let pts = pes.pts {
            if head.firstPTS == nil { head.firstPTS = pts }
            if let last = head.lastPTS {
                let delta = pts - last
                if delta <= 0 || delta > StreamCommand.audioGapThreshold { head.gaps.append((pts, delta)) }
            }
            head.lastPTS = pts
        }
        let bytes = [UInt8](pes.payload)
        var offset = 0
        var broken = false
        while offset + 7 <= bytes.count {
            guard bytes[offset] == 0xFF, bytes[offset + 1] & 0xF0 == 0xF0 else { broken = true; break }
            let length = (Int(bytes[offset + 3] & 0x03) << 11) | (Int(bytes[offset + 4]) << 3) | (Int(bytes[offset + 5]) >> 5)
            guard length >= 7, offset + length <= bytes.count else { broken = true; break }
            if let format = ElementaryStreamFormat.adts(Data(bytes[offset..<(offset + length)])) {
                let key = "object \(format.objectType)・\(format.sampleRate.map(String.init) ?? "?") Hz・channel_configuration \(format.channelConfiguration)"
                if key != head.lastFormat {
                    head.changes.append((pes.pts ?? -1, key))
                    head.lastFormat = key
                }
            }
            let headerLength = bytes[offset + 1] & 1 == 1 ? 7 : 9
            let key = bytes[(offset + headerLength)..<(offset + length)].withUnsafeBytes { Self.describeLeading($0) }
            let entry = head.leading[key] ?? (0, pes.pts ?? -1)
            head.leading[key] = (entry.count + 1, entry.firstPTS)
            head.frames += 1
            offset += length
        }
        if broken || offset != bytes.count { head.broken += 1 }
        audioHeads[pes.pid] = head
    }

    /// フレームの頭の要素の並び（最初の音の要素まで）と PCE の中身を 1 行にする
    nonisolated static func describeLeading(_ raw: UnsafeRawBufferPointer) -> String {
        guard let leading = AACLeadingElements.read(raw) else { return "読めない" }
        let names = ["SCE", "CPE", "CCE", "LFE", "DSE", "PCE", "FIL", "END"]
        var text = leading.kinds.map { names[$0.rawValue] }.joined(separator: " ")
        if let config = leading.programConfig {
            func list(_ elements: [AACLeadingElements.ProgramConfig.Element]) -> String {
                elements.isEmpty ? "-" : elements.map { "\($0.isPair ? "CPE" : "SCE")\($0.tag)" }.joined(separator: ",")
            }
            text += "（PCE: object \(config.objectType)・前 \(list(config.front))・横 \(list(config.side))・後 \(list(config.back))"
                + "・LFE \(config.lowFrequencyTags.isEmpty ? "-" : config.lowFrequencyTags.map(String.init).joined(separator: ","))）"
        }
        return text
    }

    /// 復号した音のフレームごとの大きさ（最大値と RMS を dBFS で。左右の大きいほう）
    private func measureLevels(_ pes: PESPacket) {
        guard let levelSeconds else { return }
        for sample in levelDecoder.decode(pes.payload, pts: pes.pts) {
            let pts = Int64((CMSampleBufferGetPresentationTimeStamp(sample).seconds * StreamCommand.ptsClock).rounded())
            if levelFirstPTS == nil { levelFirstPTS = pts }
            guard let first = levelFirstPTS, Double(pts - first) / StreamCommand.ptsClock <= levelSeconds,
                  let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { continue }
            let count = length / MemoryLayout<Float32>.size
            let values = UnsafeRawPointer(pointer).bindMemory(to: Float32.self, capacity: count)
            var peak: Float32 = 0
            var sum: Double = 0
            var crossings = 0
            for index in 0..<count {
                peak = max(peak, abs(values[index]))
                sum += Double(values[index]) * Double(values[index])
                // 左のチャンネル（インターリーブの偶数番）の符号の変わり目（雑音ほど多い）
                if index >= 2, index % 2 == 0, (values[index] >= 0) != (values[index - 2] >= 0) { crossings += 1 }
            }
            let rms = count > 0 ? (sum / Double(count)).squareRoot() : 0
            func decibels(_ value: Double) -> String { value > 0 ? String(format: "%6.1f", 20 * log10(value)) : "  -inf" }
            let relative = firstVideoPTS.map { String(format: "%+.3f", Double(pts - $0) / StreamCommand.ptsClock) } ?? "?"
            levelLines.append("  \(String(format: "%.3f", Double(pts) / StreamCommand.ptsClock))（映像の最初から \(relative) 秒）: 最大 \(decibels(Double(peak))) dB・RMS \(decibels(rms)) dB・ゼロ交差 \(crossings)")
        }
    }

    /// 音声の ES ごとの頭の様子。時刻は最初の映像の PTS からの秒
    private func reportAudioHeads() {
        guard !audioHeads.isEmpty else { return }
        func relative(_ pts: Int64) -> String {
            guard let base = firstVideoPTS, pts >= 0 else { return "?" }
            return String(format: "%+.3f 秒", Double(pts - base) / StreamCommand.ptsClock)
        }
        for (pid, head) in audioHeads.sorted(by: { $0.key < $1.key }) {
            let order = program?.audio.firstIndex { $0.pid == pid }.map { "音声 \($0 + 1)" } ?? "PMT に無い"
            say("音声の頭（\(order)）: 最初の PTS \(head.firstPTS.map(relative) ?? "なし")（映像の最初から）・PES \(head.pes)・フレーム \(head.frames)"
                + "・欠け \(head.damaged)・ADTS が崩れた PES \(head.broken)")
            for change in head.changes { say("  形: \(relative(change.pts)) から \(change.format)") }
            for (key, entry) in head.leading.sorted(by: { $0.value.firstPTS < $1.value.firstPTS }) {
                say("  頭の要素: \(key)・\(entry.count) フレーム（\(relative(entry.firstPTS)) から）")
            }
            for gap in head.gaps.prefix(StreamCommand.audioGapListLimit) {
                say("  PTS の飛び: \(relative(gap.pts))・前から \(String(format: "%.1f", Double(gap.delta) / 90)) ms")
            }
            if head.gaps.count > StreamCommand.audioGapListLimit { say("  PTS の飛び: ほか \(head.gaps.count - StreamCommand.audioGapListLimit) 回") }
        }
    }

    /// H.264 のピクチャの組み方
    private func reportH264() {
        let survey = h264Survey
        guard survey.accessUnits > 0, let parameters = survey.parameters else { return }
        say("H.264: アクセスユニット \(survey.accessUnits) 個・frame_mbs_only \(parameters.frameMBsOnly ? 1 : 0)"
            + "・MBAFF \(parameters.mbAdaptiveFrameField ? 1 : 0)・pic_struct の申告 \(parameters.picStructPresent ? 1 : 0)"
            + "・HRD \(parameters.hrdDelayLengths.map { "あり（遅れの欄 \($0.cpbRemoval)・\($0.dpbOutput) ビット）" } ?? "なし")")
        let layouts = survey.layouts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: "・")
        say("  PES の中のピクチャ（F フレーム・T 上のフィールド・B 下のフィールド）: \(layouts)")
        let structs = survey.picStructs.sorted { $0.key < $1.key }
            .map { "\($0.key < 0 ? "なし" : String($0.key)) \($0.value)" }.joined(separator: "・")
        say("  pic_struct（0 フレーム・1 上・2 下・3 上下・4 下上・5 上下上・6 下上下・7 2 倍・8 3 倍）: \(structs)")
        say("  IDR \(survey.idr)・recovery point \(survey.recoveryPoints)・I \(survey.intra)")
        if let minimum = survey.gopLengths.min(), let maximum = survey.gopLengths.max() {
            say("  ランダムアクセスの点の間（復号の順の PES の数）: \(survey.gopLengths.count) 回・\(minimum)〜\(maximum)")
        }
        say("  点の後の、点より前に表示する B（open GOP の頭）: \(survey.leadingPictures.map(String.init).joined(separator: " "))")
    }
}
