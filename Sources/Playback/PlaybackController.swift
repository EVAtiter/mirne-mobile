import Foundation
import Observation

// 録画の再生。
//
// UI は「この res を再生して」とだけ言い、中（HEAD → AKE → GET → PCP の逐次復号 → 先読みの抑え → PlayerEngine）を
// 知らない。手順は計測コマンドの `stream --play` で実機の DR・3倍・モバイルを確かめた形のまま。
// AppKit に依存させない（描画の VideoRenderer は画面の側が engine の FrameQueue につなぐ）。
//
// 状態と画面が知るサービスは PlaybackState.swift、決まりの値は PlaybackPolicy.swift、1 回の受信は PlaybackSession.swift（2026-11-21 に分けた）

/// 再生の中身（DTCP-IP と mirne の PlayerEngine）
@MainActor
@Observable
public final class PlaybackController: PlaybackService {
    public private(set) var state = PlaybackState.idle
    /// 録画の長さ（秒。分からなければ nil）。録画中の録画は時刻とともに伸びる（`RecordingGrowth`）
    public var durationSeconds: Double? {
        guard let growth else { return listedDuration }
        return growth.duration(base: listedDuration, at: now())
    }
    /// 一覧の長さ
    private var listedDuration: Double?
    /// 録画中の録画を再生しているときの、長さの伸び方（録画中でなければ nil）
    public private(set) var growth: RecordingGrowth?
    /// 今の時刻（試験で替える）
    @ObservationIgnored var now: () -> Date = Date.init
    public private(set) var kind = PlaybackKind.recording
    /// 選んでいる二重音声の主・副（張り直しても引き継ぐ。別の録画を再生すると主音声に戻す）
    public private(set) var dualMonoChannel = DualMonoChannel.initial
    /// 再生の速さ（シーク・画質や音声の切り替え・一時停止では保ち、新しい録画・ライブで 1 に戻す。保存しない）
    public private(set) var playbackRate = PlaybackRatePolicy.normal
    /// 画面の描画がつなぐ再生系（FrameQueue と時計）
    public let engine: PlayerEngine

    private let credentialStore: any DTCPCredentialStore
    private let client: any HTTPExchanging
    private let diagnostics: DTCPDiagnostics

    @ObservationIgnored private var session: PlaybackSession?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    /// 始める・止めるを順に行う（受信は画面のスレッドの外で動くので、止め終わるのを待ってから再生系を空にする）
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var resource: TitleResource?
    @ObservationIgnored private var pausedAt: ContinuousClock.Instant?
    /// 再生位置の基準（録画の頭からの秒と、そのときの PTS）。PTS は再生が始まったとき（`watch`）に再生系の時計の始まりを覚え、
    /// その後に時計を張り直しても変えない。覚えるまでは再生系の今の始まりで数える（`positionSeconds`）
    @ObservationIgnored private var baseSeconds: Double = 0
    @ObservationIgnored private var basePTS: Int64?
    /// 利用者が選んだ音声（張り直しても引き継ぐ。別の録画を再生すると忘れる）
    @ObservationIgnored private var preferredAudio: AudioTrack?
    /// いまの受信を始めた時刻（始まるまでの時間をログに出す）
    @ObservationIgnored private var startedAt: ContinuousClock.Instant?
    /// 最後に頼んだ始める位置（秒）。始める前にスリープしたら、ここを止めた位置にする
    @ObservationIgnored private var requestedSeconds: Double = 0
    /// 張り直した後、始まったら一時停止に戻す（一時停止中に音声を切り替えたとき）
    @ObservationIgnored private var pauseWhenStarted = false
    /// スリープの前に止めた位置（秒）。再開を押したら、ここから張り直す
    @ObservationIgnored private var reconnectPosition: Double?
    /// 始め直しを頼んだ回数。待っている始め直しが、その後のスリープ・停止で古くなったら始めない
    @ObservationIgnored private var generation = 0
    /// この録画の再生が一度でも始まったか（始まる前に閉じたら、視聴の位置を記録しない）
    @ObservationIgnored private var hasStarted = false
    /// 止めどころ（一時停止・停止・スリープ・最後まで・`recordCheckpoint`）を受け取る（視聴の状態の記録）
    @ObservationIgnored public var onCheckpoint: (@MainActor (PlaybackCheckpoint) -> Void)?
    /// 録画やライブの再生を新しく頼まれたことを受け取る（非機能要件の計測。シーク・切り替えの張り直しでは呼ばない）
    @ObservationIgnored public var onRequest: (@MainActor (_ kind: PlaybackKind, _ quality: String?) -> Void)?

    init(credentialStore: any DTCPCredentialStore, client: any HTTPExchanging,
         engine: PlayerEngine = PlayerEngine(), diagnostics: DTCPDiagnostics = .osLog) {
        self.credentialStore = credentialStore
        self.client = client
        self.engine = engine
        self.diagnostics = diagnostics
    }

    /// 実機に向けた組み立て
    public static func live(client: any HTTPExchanging) -> PlaybackController {
        PlaybackController(credentialStore: DTCPKeychainCredentialStore(), client: client)
    }

    public var currentResource: TitleResource? { resource }

    public var volume: Float {
        get { engine.volume }
        set { engine.volume = newValue }
    }

    public var isMuted: Bool {
        get { engine.isMuted }
        set { engine.isMuted = newValue }
    }

    /// 再生位置（録画の頭からの秒）。読むだけで、基準は変えない（2026-11-21。前は最初に読んだときに基準の PTS を覚えていた）
    public var positionSeconds: Double? {
        guard let now = engine.presentationTime(), let base = basePTS ?? engine.startPTS else { return nil }
        return max(0, baseSeconds + Double(now - base) / 90_000)
    }

    public var canSeek: Bool {
        guard kind == .recording, resource != nil else { return false }
        switch state {
        case .playing, .paused, .waiting, .starting, .ended: return true
        case .idle, .failed: return false
        }
    }

    public var displaySeconds: Double? {
        if state.isStarting { return requestedSeconds }
        if state == .ended { return durationSeconds ?? positionSeconds }
        return positionSeconds ?? reconnectPosition
    }

    public func play(_ resource: TitleResource, durationSeconds: Double?, from seconds: Double = 0, growth: RecordingGrowth? = nil) {
        guard !state.isStarting else { return }   // 二重に始めない
        prepareNew(.recording, resource, listedDuration: durationSeconds, growth: growth)
        log("再生を頼んだ（画質 \(resource.quality ?? "元")・\(Self.seconds(seconds)) から・長さ \(Self.seconds(durationSeconds))\(growth == nil ? "" : "・録画中")）")
        onRequest?(.recording, resource.quality)
        restart(resource, from: seconds)
    }

    public func playLive(_ resource: TitleResource) {
        // 前の録画の位置は、呼び出し側が替える前に記録する（AppEnvironment.playLive）
        prepareNew(.live, resource, listedDuration: nil, growth: nil)
        log("ライブを頼んだ（画質 \(resource.quality ?? "元")）")
        onRequest?(.live, resource.quality)
        restart(resource, from: 0)
    }

    /// 新しい録画・ライブを始める前に、前の再生で選んだもの（音声・二重音声・速さ）と状態を戻し、始めている状態にする。
    /// 止めた時刻も捨てる（読むのは止めている間の再開だけで、始めた後に止めると付け直すので、前の値は読まれない）
    private func prepareNew(_ kind: PlaybackKind, _ resource: TitleResource, listedDuration: Double?, growth: RecordingGrowth?) {
        self.kind = kind
        self.resource = resource
        self.listedDuration = listedDuration
        self.growth = growth
        preferredAudio = nil
        dualMonoChannel = .initial
        engine.dualMonoChannel = .initial
        resetRate()
        pauseWhenStarted = false
        reconnectPosition = nil
        pausedAt = nil
        hasStarted = false
        state = .starting(.credentials)
    }

    /// いまの再生を `position` から張り直す（再開・音声と画質の切り替え・シーク。新しく始めるのは `restart` を直に呼ぶ）。
    ///
    /// 止めている間に頼んだら（始め直している途中で、始まったら止める予定のときも）、始まったところで止める。
    /// `keepsPaused` を渡すと、それに従う（再開は false）。ログの文は呼ぶ側が、状態を変える前の値で作って渡す
    private func reconnect(_ resource: TitleResource, from position: Double, keepsPaused: Bool? = nil, log message: String) {
        pauseWhenStarted = keepsPaused ?? (state == .paused || (state.isStarting && pauseWhenStarted))
        reconnectPosition = nil
        state = .starting(.request)
        log(message)
        restart(resource, from: position)
    }

    /// 一時停止。ライブは受信を切って止めた絵を出し続け、再開すると今の放送から見直す（チューナーを空ける。2026-11-20 に決めた）
    public func pause() {
        guard state == .playing || state == .waiting else { return }
        if kind == .live {
            generation += 1   // 待っている始め直しを古くする
            pauseWhenStarted = false
            pausedAt = nil
            reconnectPosition = 0   // 再開で張り直す（ライブは位置に関わらず今の放送から）
            state = .paused
            log("ライブを止めた（受信を切る。再開で今の放送から見直す）")
            enqueue { [weak self] in await self?.closeSessionKeepingPicture() }
            return
        }
        engine.pause()
        pausedAt = .now
        state = .paused
        log("一時停止（\(Self.seconds(positionSeconds))）")
        recordCheckpoint(.paused)
    }

    public func resume() {
        guard state == .paused else { return }
        // スリープの前に止めていたら、受信と接続を閉じてあるので、止めた位置から張り直す。
        // 長く止めていたら nasne が受信を切っている見込みなので、いまの位置から張り直す
        let pausedLong = pausedAt.map { ContinuousClock.now - $0 > PlaybackTimingPolicy.reconnectAfterPause } ?? false
        if let resource, let position = reconnectPosition ?? (pausedLong ? positionSeconds : nil) {
            pausedAt = nil
            reconnect(resource, from: position, keepsPaused: false,
                      log: "再開：\(reconnectPosition != nil ? "スリープの前に閉じた" : "長く止めていた")ので \(Self.seconds(position)) から張り直す")
            return
        }
        pausedAt = nil
        engine.resume()
        state = .playing
        log("再開")
    }

    public var canChangeRate: Bool {
        PlaybackRatePolicy.canChange(kind: kind, isGrowing: growth != nil)
    }

    public func setRate(_ rate: Double) {
        guard canChangeRate, PlaybackRatePolicy.rates.contains(rate), rate != playbackRate else { return }
        playbackRate = rate
        engine.setRate(Float(rate))
        log("速さ \(PlaybackRatePolicy.label(rate))")
    }

    public func cycleRate() {
        setRate(PlaybackRatePolicy.next(after: playbackRate))
    }

    /// 等速に戻す（新しい録画・ライブを始めるとき）
    private func resetRate() {
        playbackRate = PlaybackRatePolicy.normal
        engine.setRate(Float(PlaybackRatePolicy.normal))
    }

    /// 次の音声 ES へ切り替える。
    ///
    /// 再生系に任せる（`selectAudio`）と、出力の音声を捨ててから新しい音声が届くまで、先読みの約 3 秒ぶん途切れる
    /// （先読みは前の音声だけで受け取り済みのため。2026-11-19 実機）。そこで、いまの位置から時間指定で張り直し、
    /// 新しい音声で始める（途切れは張り直しの約 1 秒）
    public func cycleAudio() {
        let status = engine.audioStatus
        guard status.tracks.count > 1, let resource, let position = positionSeconds ?? reconnectPosition,
              state == .playing || state == .paused || state == .waiting else { return }
        let next = status.tracks[((status.selectedIndex ?? 0) + 1) % status.tracks.count]
        preferredAudio = next
        reconnect(resource, from: position,
                  log: "音声を \((status.selectedIndex ?? 0) + 1) から次へ切り替える。\(Self.seconds(position)) から張り直す")
    }

    /// 二重音声の主・副を選ぶ。
    ///
    /// 再生系は復号するときに主・副を振り分けるので、選び直しても、先読みの約 3 秒ぶん（復号して出力に渡し済み）は
    /// 前の選択のまま鳴る。そこで音声の切り替え（`cycleAudio`）と同じく、いまの位置から張り直す（途切れは約 1 秒）。
    /// 二重音声を再生していなければ、選択だけ覚えておく
    public func selectDualMono(_ channel: DualMonoChannel) {
        guard channel != dualMonoChannel else { return }
        let previous = dualMonoChannel
        dualMonoChannel = channel
        engine.dualMonoChannel = channel
        guard engine.audioStatus.layout == .dualMono, let resource, let position = positionSeconds ?? reconnectPosition,
              state == .playing || state == .paused || state == .waiting else { return }
        reconnect(resource, from: position, log: "二重音声を \(previous) から \(channel) へ切り替える。\(Self.seconds(position)) から張り直す")
    }

    /// 別の画質へ張り直す。音声の切り替えと同じく、いまの位置から時間指定で張り直す
    /// （ライブは今の放送から）。一時停止中は始まったところで止める。字幕の表示はそのまま（`CaptionOverlayModel` が持つ）。
    /// 選んでいた音声は既定に戻す（モバイルは音声を作り直してあり、本数・形が違うため）。
    /// ライブを止めている間（受信を切っている）は画質だけを替え、再開で新しい画質から見直す
    public func switchQuality(_ newResource: TitleResource) {
        guard let current = resource, newResource != current else { return }
        if kind == .live, state == .paused {
            resource = newResource
            log("ライブの画質を \(current.quality ?? "元") から \(newResource.quality ?? "元") へ（再開で見直す）")
            return
        }
        let position: Double
        switch state {
        case .starting:
            position = requestedSeconds
        case .playing, .paused, .waiting:
            position = positionSeconds ?? reconnectPosition ?? requestedSeconds
        case .idle, .ended, .failed:
            return
        }
        resource = newResource
        preferredAudio = nil
        reconnect(newResource, from: position,
                  log: "画質を \(current.quality ?? "元") から \(newResource.quality ?? "元") へ切り替える。\(Self.seconds(kind == .live ? nil : position)) から張り直す")
    }

    /// 指定の位置から張り直す。
    ///
    /// 張り直しは `restart` だけで行う（頼んだ回数で、続けて頼んだときは最後の 1 回だけが始まる）。
    /// 止めている間に飛んだら、始まったところで止める
    public func seek(to seconds: Double) {
        guard canSeek, let resource else { return }
        let target = SeekPolicy.clamp(seconds, duration: durationSeconds,
                                      margin: growth == nil ? SeekPolicy.endMargin : SeekPolicy.growingEdgeMargin)
        reconnect(resource, from: target, log: "\(Self.seconds(target)) へ飛ぶ（張り直す）")
    }

    /// いまの位置（始め直している間は頼んだ位置）から前後へ飛ぶ。続けて押すと、頼んだ位置からさらに進む
    public func skip(by seconds: Double) {
        guard canSeek, let base = displaySeconds else { return }
        seek(to: base + seconds)
    }

    public func stop() {
        recordCheckpoint(.left)
        if state != .idle { log("止めた") }
        generation += 1
        resource = nil
        reconnectPosition = nil
        state = .idle
        enqueue { [weak self] in await self?.stopSession() }
    }

    public func suspendForSleep() {
        let position: Double
        switch state {
        case .playing, .waiting, .paused:
            position = positionSeconds ?? reconnectPosition ?? baseSeconds
        case .starting:
            // まだ始まっていなければ、頼んだ位置から
            position = positionSeconds ?? requestedSeconds
        case .idle, .ended, .failed:
            return
        }
        guard resource != nil else { return }
        generation += 1   // 待っている始め直しを古くする
        pauseWhenStarted = false
        pausedAt = nil
        reconnectPosition = position
        state = .paused
        recordCheckpoint(.left)
        log("スリープの前に受信と接続を閉じる（\(Self.seconds(position))。再開で張り直す）")
        enqueue { [weak self] in await self?.closeSessionKeepingPicture() }
    }

    /// いまの位置（始め直している間は頼んだ位置・最後までなら長さ）を止めどころとして知らせる。
    /// 始まる前・止めた後・失敗した後は知らせない。
    /// 録画中の録画は、長さを知らせない（終わり近くで止めても「見終わった」にしない。配信が本当に終わったら見終わった。2026-11-20）
    public func recordCheckpoint(_ occasion: PlaybackCheckpoint.Occasion = .periodic) {
        guard kind == .recording, hasStarted, resource != nil, let position = displaySeconds else { return }
        switch state {
        case .playing, .paused, .waiting, .starting, .ended:
            onCheckpoint?(PlaybackCheckpoint(position: position, duration: growth == nil ? durationSeconds : nil,
                                             ended: state == .ended, occasion: occasion))
        case .idle, .failed:
            return
        }
    }

    /// 受信・接続・再生の後始末が要るか（終了の前に待つか）
    public var needsShutdown: Bool { session != nil || state.isStarting }

    /// 止めて、受信の手順が止まり終わる（接続を閉じ、鍵を捨てる）まで待つ（終了の前）
    public func shutdown() async {
        stop()
        await operation?.value
    }

    /// いまの再生系を空にしてから、`seconds` の位置から始める（張り直しも同じ）。
    /// 待っている間にスリープ・停止で古くなったら始めない
    /// ライブは位置が無いので、いつも今の放送から（時間指定の見出しを付けない）
    private func restart(_ resource: TitleResource, from requested: Double) {
        let seconds = kind == .live ? 0 : requested
        generation += 1
        let requested = generation
        requestedSeconds = seconds
        enqueue { [weak self] in
            await self?.stopSession()
            guard let self, generation == requested else { return }
            start(resource, from: seconds)
        }
    }

    /// 前の操作が終わってから行う
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = operation
        operation = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    // MARK: - ログ（段の遷移・位置・所要時間だけ。URL・アドレス・鍵は出さない）

    private func log(_ message: String) {
        diagnostics(.playback, message)
    }

    /// 秒をログ用に（無ければ「-」）
    static func seconds(_ value: Double?) -> String {
        value.map { String(format: "%.1f 秒", $0) } ?? "-"
    }

    /// 誤りの要約（分類・コード）。`detail` と下にある誤り（URL を含みうる）は出さない
    static func summary(_ error: any Error) -> String {
        switch error {
        case let dtcp as DTCPError:
            "DTCP \(dtcp.category.rawValue)\(dtcp.code.map { " \($0)" } ?? "")"
        case is AKEConnectionClosed:
            "AKE の接続が閉じた"
        default:
            NasneDiagnostics.summary(error)
        }
    }

    // MARK: - 中

    private func start(_ resource: TitleResource, from seconds: Double) {
        guard let url = URL(string: resource.url) else {
            state = .failed(ErrorText.present(NasneError.parse("playback", "the res URL is not valid")), .head)
            return
        }
        baseSeconds = seconds
        basePTS = nil
        startedAt = .now
        if !state.isStarting { state = .starting(.credentials) }
        // 選んだ音声は、再生系を空にした後（stop で既定に戻る）、受信を始める前に伝える
        if let preferredAudio { engine.selectAudio(preferredAudio) }
        // ライブは時計を止めたまま始め、先読みが溜まってから動かす（`liveStartAhead`）。再生系を空にすると一時停止の印も戻るので、その後に立てる
        if kind == .live { engine.pause() }
        let session = PlaybackSession(url: url, startSeconds: seconds, credentialStore: credentialStore, client: client,
                                      engine: engine, diagnostics: diagnostics) { [weak self] event in
            await self?.handle(event)
        }
        self.session = session
        session.run()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: PlaybackTimingPolicy.monitorInterval)
                self?.watch()
            }
        }
    }

    /// 受信を止め、止め終わってから再生系を空にする（鍵と接続も捨てる）
    private func stopSession() async {
        monitor?.cancel()
        monitor = nil
        if let session {
            self.session = nil
            await session.cancelAndWait()
        }
        engine.stop()
        pausedAt = nil
        basePTS = nil
    }

    /// 受信と接続を閉じ（鍵も捨てる）、再生系は時計を止めたまま残す（止めた絵を出し続ける。スリープの前）
    private func closeSessionKeepingPicture() async {
        monitor?.cancel()
        monitor = nil
        engine.pause()
        if let session {
            self.session = nil
            await session.cancelAndWait()
        }
    }

    /// 受信を止めて、失敗として出す
    private func fail(_ error: any Error, _ stage: PlaybackStage) {
        let error = kind == .live ? LivePlaybackErrors.translate(error) : error
        log("失敗（\(stage.rawValue) の段・\(Self.summary(error))）")
        let presented = ErrorText.present(error)
        enqueue { [weak self] in
            await self?.stopSession()
            self?.state = .failed(presented, stage)
        }
    }

    /// 受信の側からの知らせ
    private func handle(_ event: PlaybackSession.Event) {
        switch event {
        case .stage(let stage):
            if state.isStarting { state = .starting(stage) }
            log("段：\(stage.rawValue)")
        case .seekStart(let seconds):
            // nasne は時間指定を少し後ろに合わせて返す。返った位置を基準にする
            baseSeconds = seconds
            log("時間指定の応答：\(Self.seconds(seconds)) から")
        case .finished where kind == .live:
            // ライブに終わりは無い。nasne が配信を止めた（録画を優先したなど）ので、理由を出す
            log("ライブの配信が終わった")
            monitor?.cancel()
            fail(LivePlaybackErrors.stopped, .receiving)
        case .finished:
            // 出し切ったら時計を止める（止めないと、最後の絵のまま再生位置が数え続けた。2026-11-19 実機）。
            // 一時停止中ならそのまま（時計は止まっている）
            if state != .paused {
                engine.pause()
                state = .ended
                recordCheckpoint(.left)
            }
            log("最後まで受け取った")
            monitor?.cancel()
        case .failed(let error, let stage):
            fail(error, stage)
        }
    }

    /// 始まったか・詰まったか・戻ったかを見る
    private func watch() {
        guard let session else { return }
        if state.isStarting, engine.startPTS != nil {
            // ライブは先読みが溜まるまで時計を止めたまま（溜まるまでは下の「黙っている」の見張りだけ続ける）
            let buffering = kind == .live && engine.isPaused && (engine.bufferedAhead ?? 0) < PlaybackTimingPolicy.liveStartAhead
            if !buffering {
                if kind == .live, engine.isPaused {
                    engine.resume()
                    log("ライブ：先読みが \(Self.seconds(Double(engine.bufferedAhead ?? 0) / 90_000)) 溜まったので時計を動かす")
                }
                state = .playing
                hasStarted = true
                if basePTS == nil { basePTS = engine.startPTS }   // 再生位置の基準（この後に時計を張り直しても変えない）
                log("再生が始まった（頼んでから \(startedAt.map { "\($0.elapsedMilliseconds) ms" } ?? "-")）")
                if pauseWhenStarted {
                    pauseWhenStarted = false
                    pause()
                }
                return
            }
        }
        if session.silentFor > PlaybackTimingPolicy.silenceLimit, state != .paused {
            monitor?.cancel()
            fail(NasneError(category: .unreachable, source: "playback:receive", retryable: true, messageKey: "error.stalled"),
                 .receiving)
            return
        }
        guard !session.isFinished, let ahead = engine.bufferedAhead else { return }
        if state == .playing, ahead < PlaybackTimingPolicy.stallBelow {
            engine.pause()
            state = .waiting
            log("先読みが尽きたので待つ")
        } else if state == .waiting, ahead >= PlaybackTimingPolicy.resumeAbove {
            engine.resume()
            state = .playing
            log("先読みが溜まったので再開")
        }
    }
}
