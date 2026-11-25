import Foundation
import Testing

// 録画の再生のサービス。実機の AKE と受信は計測コマンドで確かめた形のまま使うので、
// ここでは手前の段の失敗の出し方・二重の開始・時間指定の応答の読み方を確かめる。

private func resource() -> TitleResource {
    let items = try! DIDLItem.parseDocument(NasneFixture.text("dlna/browse_0_video_all.xml"), source: "test")
    return items[0].resources[0]
}

@MainActor
private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(5)) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
}

@MainActor
@Suite("録画の再生のサービス")
struct PlaybackControllerTests {
    @Test("資格情報が無ければ、資格情報の段で止まり、nasne に何も送らない")
    func noCredentials() async {
        let http = MockHTTP()
        let controller = PlaybackController(credentialStore: DTCPMemoryCredentialStore(), client: http,
                                            diagnostics: DTCPDiagnostics { _, _ in })
        controller.play(resource(), durationSeconds: 300, from: 0)
        await waitUntil { if case .failed = controller.state { true } else { false } }
        guard case .failed(let error, let stage) = controller.state else {
            Issue.record("失敗になっていない: \(controller.state)")
            return
        }
        #expect(stage == .credentials)
        #expect(error.title == ErrorText.nasneMessages["error.noCredentials"]?.title)
        #expect(http.sentRequests.isEmpty)
    }

    @Test("HEAD が 404 なら、接続先の確認の段で止まる。始めている間はもう一度押しても始めない")
    func headFails() async throws {
        let http = MockHTTP()
        let store = DTCPMemoryCredentialStore(authorityKeys: testAuthority)
        try store.save(certificate: hexBytes(DTCPTestVectors.katSinkCert), privateKey: hexBytes(DTCPTestVectors.katSinkPriv))
        let controller = PlaybackController(credentialStore: store, client: http, diagnostics: DTCPDiagnostics { _, _ in })
        let target = resource()
        controller.play(target, durationSeconds: 300, from: 0)
        #expect(controller.state.isStarting)
        controller.play(target, durationSeconds: 300, from: 0)   // 二重に押しても始めない
        await waitUntil { if case .failed = controller.state { true } else { false } }
        guard case .failed(let error, let stage) = controller.state else {
            Issue.record("失敗になっていない: \(controller.state)")
            return
        }
        #expect(stage == .head)
        #expect(error.code != nil)
        #expect(http.sentRequests.filter { $0.httpMethod == "HEAD" }.count == 1)
        controller.stop()
        #expect(controller.state == .idle)
    }

    @Test("時間指定の応答の始めの秒を読む")
    func nptStart() {
        #expect(PlaybackSession.nptStart("npt=60.057-294.792/294.794") == 60.057)
        #expect(PlaybackSession.nptStart("npt=0.000-") == 0)
        #expect(PlaybackSession.nptStart("bytes=0-") == nil)
    }

    @Test("録画中の録画は、長さが今の時刻とともに伸び、番組の終わりで止まる。一覧の長さより短くしない。録画中でなければ一覧の長さのまま")
    func growingDuration() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let growth = RecordingGrowth(recordingStart: start, limit: start.addingTimeInterval(1800))
        #expect(growth.duration(base: 600, at: start.addingTimeInterval(900)) == 900)    // 録り始めて 15 分
        #expect(growth.duration(base: 600, at: start.addingTimeInterval(300)) == 600)    // 一覧の長さより短くしない
        #expect(growth.duration(base: 600, at: start.addingTimeInterval(4000)) == 1800)  // 番組の終わりで止まる
        #expect(RecordingGrowth(recordingStart: start, limit: nil).duration(base: nil, at: start.addingTimeInterval(4000)) == 4000)

        let controller = PlaybackController(credentialStore: DTCPMemoryCredentialStore(), client: MockHTTP(),
                                            diagnostics: DTCPDiagnostics { _, _ in })
        var clock = start.addingTimeInterval(700)
        controller.now = { clock }
        controller.play(resource(), durationSeconds: 600, from: 0, growth: growth)
        #expect(controller.durationSeconds == 700)
        clock = start.addingTimeInterval(760)
        #expect(controller.durationSeconds == 760)
        controller.stop()
        controller.play(resource(), durationSeconds: 600, from: 0)
        #expect(controller.durationSeconds == 600 && controller.growth == nil)
        controller.stop()
    }

    @Test("止めた・一時停止の操作は、再生していなければ何もしない")
    func idleOperations() {
        let controller = PlaybackController(credentialStore: DTCPMemoryCredentialStore(), client: MockHTTP(),
                                            diagnostics: DTCPDiagnostics { _, _ in })
        controller.pause()
        #expect(controller.state == .idle)
        controller.resume()
        #expect(controller.state == .idle)
        controller.cycleAudio()          // 再生していなければ張り直さない
        #expect(controller.state == .idle)
        controller.suspendForSleep()     // 再生していなければスリープの前にも何もしない
        #expect(controller.state == .idle)
        #expect(!controller.needsShutdown)
        #expect(controller.positionSeconds == nil)
    }

    @Test("二重音声の選択：再生していなければ張り直さずに覚え、別の録画を再生すると主音声に戻す")
    func dualMonoSelection() async {
        let http = MockHTTP()
        let controller = PlaybackController(credentialStore: DTCPMemoryCredentialStore(), client: http,
                                            diagnostics: DTCPDiagnostics { _, _ in })
        #expect(controller.dualMonoChannel == .main)
        controller.selectDualMono(.sub)
        #expect(controller.state == .idle)              // 二重音声を再生していないので張り直さない
        #expect(controller.dualMonoChannel == .sub)
        #expect(controller.engine.dualMonoChannel == .sub)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(http.sentRequests.isEmpty)
        controller.play(resource(), durationSeconds: 300, from: 0)
        #expect(controller.dualMonoChannel == .main)
        #expect(controller.engine.dualMonoChannel == .main)
        controller.stop()
    }

    @Test("再生速度：段を回して再生系の時計の速さも替える。新しい録画・ライブで等速に戻す。録画中の録画とライブは替えられない")
    func playbackRate() {
        let controller = PlaybackController(credentialStore: DTCPMemoryCredentialStore(), client: MockHTTP(),
                                            diagnostics: DTCPDiagnostics { _, _ in })
        #expect(controller.playbackRate == 1 && controller.engine.rate == 1)
        #expect(controller.canChangeRate)
        controller.setRate(1.5)
        #expect(controller.playbackRate == 1.5 && controller.engine.rate == 1.5)
        controller.cycleRate()
        #expect(controller.playbackRate == 2)
        controller.cycleRate()
        #expect(controller.playbackRate == 1 && controller.engine.rate == 1)
        controller.setRate(3)                       // 段に無い速さは受けない
        #expect(controller.playbackRate == 1)

        // 新しい録画は等速から
        controller.setRate(2)
        controller.play(resource(), durationSeconds: 300, from: 0)
        #expect(controller.playbackRate == 1 && controller.engine.rate == 1)
        controller.setRate(1.25)
        #expect(controller.playbackRate == 1.25)
        controller.stop()

        // 録画中の録画は等速だけ
        let start = Date()
        controller.play(resource(), durationSeconds: 300, from: 0, growth: RecordingGrowth(recordingStart: start, limit: nil))
        #expect(!controller.canChangeRate)
        controller.setRate(1.5)
        controller.cycleRate()
        #expect(controller.playbackRate == 1 && controller.engine.rate == 1)
        controller.stop()

        // ライブは替えられない
        controller.playLive(resource())
        #expect(!controller.canChangeRate)
        controller.setRate(2)
        #expect(controller.playbackRate == 1)
        controller.stop()
    }

    @Test("飛ぶ先は録画の中に収める（0 より前にせず、終わりの手前で止める）")
    func seekClamp() {
        #expect(SeekPolicy.clamp(-5, duration: 300) == 0)
        #expect(SeekPolicy.clamp(120, duration: 300) == 120)
        #expect(SeekPolicy.clamp(400, duration: 300) == 300 - SeekPolicy.endMargin)
        #expect(SeekPolicy.clamp(400, duration: nil) == 400)
        // 録画中の録画は、録れているところの手前までしか飛ばさない
        #expect(SeekPolicy.clamp(400, duration: 300, margin: SeekPolicy.growingEdgeMargin) == 300 - SeekPolicy.growingEdgeMargin)
    }

    @Test("シーク：再生していなければ飛ばない。始めている途中に続けて飛ぶと、頼んだ位置からさらに進む")
    func seekAndSkip() {
        let controller = PlaybackController(credentialStore: DTCPMemoryCredentialStore(), client: MockHTTP(),
                                            diagnostics: DTCPDiagnostics { _, _ in })
        #expect(!controller.canSeek)
        controller.skip(by: SeekPolicy.skipSeconds)
        controller.seek(to: 60)
        #expect(controller.state == .idle)
        #expect(controller.displaySeconds == nil)

        controller.play(resource(), durationSeconds: 300, from: 100)
        #expect(controller.canSeek)
        #expect(controller.displaySeconds == 100)
        controller.skip(by: SeekPolicy.skipSeconds)
        controller.skip(by: SeekPolicy.skipSeconds)
        #expect(controller.state.isStarting)
        #expect(controller.displaySeconds == 120)
        controller.skip(by: -500)
        #expect(controller.displaySeconds == 0)
        controller.seek(to: 1000)
        #expect(controller.displaySeconds == 300 - SeekPolicy.endMargin)
        controller.stop()
        #expect(!controller.canSeek)
    }

    @Test("始めている途中でスリープしたら、nasne に何も送らずに一時停止で待ち、再開を押したら始め直す")
    func suspendWhileStarting() async throws {
        let http = MockHTTP()
        let store = DTCPMemoryCredentialStore(authorityKeys: testAuthority)
        try store.save(certificate: hexBytes(DTCPTestVectors.katSinkCert), privateKey: hexBytes(DTCPTestVectors.katSinkPriv))
        let controller = PlaybackController(credentialStore: store, client: http, diagnostics: DTCPDiagnostics { _, _ in })
        controller.play(resource(), durationSeconds: 300, from: 0)
        controller.suspendForSleep()
        #expect(controller.state == .paused)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(controller.state == .paused)           // 勝手に再生を始めない
        #expect(http.sentRequests.isEmpty)             // 待っていた始め直しは捨てた
        controller.resume()
        #expect(controller.state.isStarting)
        await waitUntil { if case .failed = controller.state { true } else { false } }
        guard case .failed(_, let stage) = controller.state else {
            Issue.record("始め直していない: \(controller.state)")
            return
        }
        #expect(stage == .head)
        #expect(http.sentRequests.filter { $0.httpMethod == "HEAD" }.count == 1)
    }

    @Test("始まる前に止めた・スリープしたときは、視聴の位置を知らせない")
    func noCheckpointBeforeStart() async throws {
        let store = DTCPMemoryCredentialStore(authorityKeys: testAuthority)
        try store.save(certificate: hexBytes(DTCPTestVectors.katSinkCert), privateKey: hexBytes(DTCPTestVectors.katSinkPriv))
        let controller = PlaybackController(credentialStore: store, client: MockHTTP(), diagnostics: DTCPDiagnostics { _, _ in })
        var checkpoints: [PlaybackCheckpoint] = []
        controller.onCheckpoint = { checkpoints.append($0) }
        controller.recordCheckpoint()
        controller.play(resource(), durationSeconds: 300, from: 14)
        controller.suspendForSleep()
        controller.recordCheckpoint()
        controller.stop()
        #expect(checkpoints.isEmpty)
    }

    @Test("終了の前の後始末は、止め終わるまで待って何も残さない")
    func shutdown() async throws {
        let http = MockHTTP()
        let store = DTCPMemoryCredentialStore(authorityKeys: testAuthority)
        try store.save(certificate: hexBytes(DTCPTestVectors.katSinkCert), privateKey: hexBytes(DTCPTestVectors.katSinkPriv))
        let controller = PlaybackController(credentialStore: store, client: http, diagnostics: DTCPDiagnostics { _, _ in })
        controller.play(resource(), durationSeconds: 300, from: 0)
        #expect(controller.needsShutdown)
        await controller.shutdown()
        #expect(controller.state == .idle)
        #expect(!controller.needsShutdown)
    }
}

@Suite("同じ録画の張り直しでの認証の使い回し")
struct PlaybackAuthenticationPolicyTests {
    private let recording = URL(string: "http://nasne.invalid:64220/a")!
    private let other = URL(string: "http://nasne.invalid:64220/b")!

    /// 同じ録画の張り直し（シーク・音声の切り替え）だけ使い回す
    @Test func reusesOnlyForTheSameRecording() {
        #expect(PlaybackAuthenticationPolicy.canReuse(cachedURL: recording, url: recording, kind: .recording))
        // 画質を替えると URL が変わるので認証し直す
        #expect(!PlaybackAuthenticationPolicy.canReuse(cachedURL: recording, url: other, kind: .recording))
        // ライブは使い回さない
        #expect(!PlaybackAuthenticationPolicy.canReuse(cachedURL: recording, url: recording, kind: .live))
        #expect(!PlaybackAuthenticationPolicy.canReuse(cachedURL: nil, url: recording, kind: .recording))
    }
}

@Suite("配信の HEAD の HTTP 511 の頼み直し")
struct InUseRetryPolicyTests {
    /// 決めた順に、511・ほかの誤り・成功を返す偽の HEAD
    final class Heads: @unchecked Sendable {
        var results: [Int?]
        var calls = 0
        var slept: [Duration] = []
        init(_ results: [Int?]) { self.results = results }

        /// nil なら成功（呼んだ回数を返す）。数なら、その HTTP の状態の誤り（HEAD と同じ形）
        func run() async throws -> Int {
            let index = calls
            calls += 1
            if let status = results[min(index, results.count - 1)] {
                throw DTCPError(.unreachable, "dtcp:http", "HEAD returned HTTP \(status)", code: String(status))
            }
            return index
        }
    }

    @Test("511 が続いたら間を置いてやり直し、通ったらその結果を返す")
    func retriesUntilOK() async throws {
        let heads = Heads([511, 511, nil])
        var retries: [Int] = []
        let value = try await InUseRetryPolicy.run(sleep: { heads.slept.append($0) }, onRetry: { retries.append($0) }) {
            try await heads.run()
        }
        #expect(value == 2)
        #expect(heads.slept == Array(InUseRetryPolicy.delays.prefix(2)))
        #expect(retries == [1, 2])
    }

    @Test("使い切っても 511 なら 511 の誤りを投げる（ライブでは「ほかの機器が使っています」になる）")
    func givesUp() async throws {
        let heads = Heads([511])
        await #expect(throws: DTCPError.self) {
            try await InUseRetryPolicy.run(sleep: { heads.slept.append($0) }) { try await heads.run() }
        }
        #expect(heads.calls == InUseRetryPolicy.delays.count + 1)
        #expect(heads.slept == InUseRetryPolicy.delays)
    }

    @Test("511 でない誤り（404 など）はやり直さない")
    func otherErrorsAreNotRetried() async throws {
        let heads = Heads([404, nil])
        await #expect(throws: DTCPError.self) {
            try await InUseRetryPolicy.run(sleep: { heads.slept.append($0) }) { try await heads.run() }
        }
        #expect(heads.calls == 1 && heads.slept.isEmpty)
    }
}

@Suite("配信の GET の HTTP 512 の頼み直し")
struct BusyRetryPolicyTests {
    /// 決めた順に状態を返す偽の要求
    final class Attempts: @unchecked Sendable {
        var statuses: [Int]
        var opened = 0
        var discarded: [Int] = []
        var slept: [Duration] = []
        init(_ statuses: [Int]) { self.statuses = statuses }

        func run() async throws -> (value: Int, status: Int) {
            let index = opened
            opened += 1
            return (index, statuses[min(index, statuses.count - 1)])
        }
    }

    @Test("512 が続いたら間を置いて開き直し、200 になったらその応答を返す。断られた要求は閉じる")
    func retriesUntilOK() async throws {
        let attempts = Attempts([512, 512, 200])
        var retries: [Int] = []
        let opened = try await BusyRetryPolicy.open(
            sleep: { attempts.slept.append($0) }, onRetry: { retries.append($0) },
            attempt: { try await attempts.run() }, discard: { attempts.discarded.append($0) })
        #expect(opened.status == 200 && opened.value == 2)
        #expect(attempts.opened == 3)
        #expect(attempts.discarded == [0, 1])
        #expect(attempts.slept == Array(BusyRetryPolicy.delays.prefix(2)))
        #expect(retries == [1, 2])
    }

    @Test("頼み直しを使い切ったら 512 の応答を返す（呼び出し側が誤りにする）")
    func givesUp() async throws {
        let attempts = Attempts([512])
        let opened = try await BusyRetryPolicy.open(
            sleep: { attempts.slept.append($0) },
            attempt: { try await attempts.run() }, discard: { attempts.discarded.append($0) })
        #expect(opened.status == 512)
        #expect(attempts.opened == BusyRetryPolicy.delays.count + 1)
        #expect(attempts.slept == BusyRetryPolicy.delays)
        // 最後の応答は閉じずに返す（呼び出し側が持つ）
        #expect(attempts.discarded.count == BusyRetryPolicy.delays.count)
    }

    @Test("512 でない断り（406 など）は頼み直さない")
    func otherStatusesAreNotRetried() async throws {
        let attempts = Attempts([406, 200])
        let opened = try await BusyRetryPolicy.open(
            sleep: { attempts.slept.append($0) },
            attempt: { try await attempts.run() }, discard: { attempts.discarded.append($0) })
        #expect(opened.status == 406)
        #expect(attempts.opened == 1 && attempts.slept.isEmpty && attempts.discarded.isEmpty)
    }
}

@Suite("再生速度の決まり")
struct PlaybackRatePolicyTests {
    @Test("段は 1・1.25・1.5・2 倍で、S キーは 2 倍の次に 1 倍へ戻る。知らない速さからは等速へ")
    func cycle() {
        #expect(PlaybackRatePolicy.rates == [1, 1.25, 1.5, 2])
        #expect(PlaybackRatePolicy.next(after: 1) == 1.25)
        #expect(PlaybackRatePolicy.next(after: 1.5) == 2)
        #expect(PlaybackRatePolicy.next(after: 2) == 1)
        #expect(PlaybackRatePolicy.next(after: 0.75) == 1)
    }

    @Test("名前は末尾の 0 を落とす（「1倍」「1.25倍」「1.5倍」「2倍」）")
    func labels() {
        #expect(PlaybackRatePolicy.rates.map(PlaybackRatePolicy.label) == ["1倍", "1.25倍", "1.5倍", "2倍"])
    }

    @Test("替えられるのは録画だけで、録画中の録画は等速だけ")
    func canChange() {
        #expect(PlaybackRatePolicy.canChange(kind: .recording, isGrowing: false))
        #expect(!PlaybackRatePolicy.canChange(kind: .recording, isGrowing: true))
        #expect(!PlaybackRatePolicy.canChange(kind: .live, isGrowing: false))
    }
}
