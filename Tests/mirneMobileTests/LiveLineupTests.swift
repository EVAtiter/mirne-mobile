import Foundation
import Synchronization
import Testing

// ライブで見る局。番組表の局とライブの局の突き合わせ、↑↓ と数字キーの選び方、
// 始めるときの局、ライブの受信の再生の制御（位置なし・一時停止なし・511 の文言）

/// チャンネル一覧だけを返す本体情報（呼ばれた回数を数える）
private final class LiveChannelsOnly: DeviceInfoService, Sendable {
    let channels: [Channel]
    private let count = Mutex(0)
    init(channels: [Channel]) { self.channels = channels }

    var calls: Int { count.withLock { $0 } }
    func channels(broadcastingType: Int) async throws -> [Channel] {
        count.withLock { $0 += 1 }
        return channels
    }
    func deviceInfo() async throws -> DeviceInfo { throw NasneError.validation("test", "使わない") }
    func hddList() async throws -> [HDDEntry] { [] }
    func hddInfo(id: Int) async throws -> HDDInfo { throw NasneError.validation("test", "使わない") }
    func liveStatus() async throws -> LiveStatus { throw NasneError.validation("test", "使わない") }
    func recNgList() async throws -> [RecNgItem] { [] }
    func titleCounts() async throws -> (count: Int, max: Int) { (0, 0) }
}

/// 地上の帯域の局だけを返すライブの一覧（ほかの帯域を頼まれたら失敗にする）
private final class TerrestrialOnly: LiveCatalogService, Sendable {
    let live: [LiveChannel]
    private let state = Mutex((calls: 0, bands: [Int]()))
    init(live: [LiveChannel]) { self.live = live }

    var calls: Int { state.withLock { $0.calls } }
    var bands: [Int] { state.withLock { $0.bands } }
    func bands() async throws -> [LiveBand] { throw NasneError.validation("test", "全部の帯域は読まない") }
    func channels(broadcastingType: Int) async throws -> [LiveChannel] {
        state.withLock {
            $0.calls += 1
            $0.bands.append(broadcastingType)
        }
        return live
    }
}

private func channel(_ serviceID: Int, tsid: Int, key: Int?) -> Channel {
    Channel(broadcastingType: BroadcastingType.terrestrial, networkID: 0x7E00 + tsid, transportStreamID: tsid,
            serviceID: serviceID, serviceType: Channel.televisionServiceType, channelNumber: serviceID,
            serviceName: "テスト局\(serviceID)", remoteControlKeyID: key)
}

/// ライブの素材（地上の局）の res のうち、その画質のもの（dr・x3・mobile）
private func liveResource(_ quality: String) -> TitleResource {
    let items = try! DIDLItem.parseDocument(NasneFixture.text("dlna/browse_0_video_LiveTuner_DTTB.xml"), source: "test")
    return items[0].resources.first { $0.quality == quality }!
}

/// ライブの局（`resources` が空なら配信の在りかが無い局）
private func live(_ channel: Channel, title: String = "", resources: [TitleResource] = [liveResource("dr"), liveResource("mobile")]) -> LiveChannel {
    LiveChannel(id: "0/video/LiveTuner/DTTB/ch?svid=\(channel.serviceID)", bandID: "0/video/LiveTuner/DTTB",
                networkID: channel.networkID, transportStreamID: channel.transportStreamID, serviceID: channel.serviceID,
                programTitle: title, resources: resources)
}

/// 5 局：キー 1・2・4 の本チャンネル、キー 4 の局のサブチャンネル（キー 0）、キーの無い局
private let channels = [
    channel(0x4011, tsid: 1, key: 4),
    channel(0x4012, tsid: 1, key: 0),
    channel(0x4010, tsid: 3, key: 1),
    channel(0x4030, tsid: 4, key: 2),
    channel(0x4020, tsid: 2, key: nil),
]

private func key(_ serviceID: Int) -> LiveStationKey {
    LiveStationKey(channels.first { $0.serviceID == serviceID }!)
}

@Suite("ライブで見る局")
struct LiveLineupTests {
    /// キー 2 の局はライブの一覧に無く、キーの無い局は配信の在りかが無い
    static let liveChannels = [
        live(channels[0], title: "番組A"), live(channels[1]), live(channels[2]), live(channels[4], resources: []),
    ]

    static func stations(showsSubchannels: Bool) -> [LiveStation] {
        LiveLineup.stations(channels: channels, live: liveChannels, showsSubchannels: showsSubchannels)
    }

    @Test("番組表と同じ順に並べ、nid・tsid・svid の組でライブの局を突き合わせる。無い局・在りかの無い局は理由を添える")
    func matchesLiveChannels() {
        let stations = Self.stations(showsSubchannels: false)
        #expect(stations.map(\.channel.serviceID) == [0x4010, 0x4030, 0x4011, 0x4020])
        #expect(stations[0].resource?.quality == "dr")   // 元画質
        #expect(stations[0].unavailableReason == nil)
        #expect(stations[1].unavailableReason == LiveText.notInLiveList)
        #expect(stations[3].unavailableReason == LiveText.noResource)
        #expect(Self.stations(showsSubchannels: true).map(\.channel.serviceID) == [0x4010, 0x4030, 0x4011, 0x4012, 0x4020])
    }

    @Test("↑↓：見られる局だけを順に動き、端では反対の端へ回る")
    func stepsThroughAvailableStations() {
        let visible = Self.stations(showsSubchannels: false)
        let all = Self.stations(showsSubchannels: true)
        #expect(LiveLineup.step(from: key(0x4010), offset: 1, visible: visible, all: all)?.channel.serviceID == 0x4011)  // キー 2 を飛ばす
        #expect(LiveLineup.step(from: key(0x4011), offset: 1, visible: visible, all: all)?.channel.serviceID == 0x4010)  // 在りかの無い局を飛ばして回る
        #expect(LiveLineup.step(from: key(0x4010), offset: -1, visible: visible, all: all)?.channel.serviceID == 0x4011)
        #expect(LiveLineup.step(from: nil, offset: 1, visible: visible, all: all)?.channel.serviceID == 0x4010)
        #expect(LiveLineup.step(from: nil, offset: -1, visible: visible, all: all)?.channel.serviceID == 0x4011)
        // サブチャンネルを並べていれば、サブにも止まる
        #expect(LiveLineup.step(from: key(0x4011), offset: 1, visible: all, all: all)?.channel.serviceID == 0x4012)
    }

    @Test("↑↓：番組表から隠したサブチャンネルを見ているときは、その位置から向きのとおりに並べている局へ動く")
    func stepsFromHiddenSubchannel() {
        let visible = Self.stations(showsSubchannels: false)
        let all = Self.stations(showsSubchannels: true)
        #expect(LiveLineup.step(from: key(0x4012), offset: 1, visible: visible, all: all)?.channel.serviceID == 0x4010)
        #expect(LiveLineup.step(from: key(0x4012), offset: -1, visible: visible, all: all)?.channel.serviceID == 0x4011)
    }

    @Test("数字キー：1〜9・0（10）・-（11）・^（12）をリモコンキーの局にする。キーの局が見られなければ選ばない")
    func remoteKeys() {
        #expect(LiveRemoteKeys.number(for: "1") == 1)
        #expect(LiveRemoteKeys.number(for: "0") == 10)
        #expect(LiveRemoteKeys.number(for: "-") == 11)
        #expect(LiveRemoteKeys.number(for: "^") == 12)
        #expect(LiveRemoteKeys.number(for: "a") == nil)
        let visible = Self.stations(showsSubchannels: false)
        #expect(LiveLineup.station(remoteKey: 4, in: visible)?.channel.serviceID == 0x4011)
        #expect(LiveLineup.station(remoteKey: 2, in: visible) == nil)   // ライブの一覧に無い
        #expect(LiveLineup.station(remoteKey: 3, in: visible) == nil)
    }

    @Test("始めるとき：前に見た局が見られればそれ（隠したサブでも）、無ければ最初の見られる局")
    func initialStation() {
        let visible = Self.stations(showsSubchannels: false)
        let all = Self.stations(showsSubchannels: true)
        #expect(LiveLineup.initialStation(last: key(0x4011), visible: visible, all: all)?.channel.serviceID == 0x4011)
        #expect(LiveLineup.initialStation(last: key(0x4012), visible: visible, all: all)?.channel.serviceID == 0x4012)
        #expect(LiveLineup.initialStation(last: key(0x4030), visible: visible, all: all)?.channel.serviceID == 0x4010)
        #expect(LiveLineup.initialStation(last: nil, visible: visible, all: all)?.channel.serviceID == 0x4010)
        #expect(LiveLineup.initialStation(last: nil, visible: [], all: []) == nil)
    }

    @Test("録画中の局：録画中の録画の局が見られればそれ。録画中でない・局が見られない・放送の種別が違えば nil")
    func recordingStation() throws {
        func title(_ id: String, serviceID: Int, recording: Bool, type: Int = BroadcastingType.terrestrial) throws -> RecordedTitle {
            try RecordedTitle(item: XSRSItem(id: id, fields: ["title": "架空番組", "scheduledChannelID": String(format: "0x%04x", serviceID),
                                                               "recordingFlag": recording ? "1" : "0"],
                                             attributes: ["scheduledChannelID": ["broadcastingType": String(type), "channelType": String(type)]]),
                              source: "test")
        }
        let all = Self.stations(showsSubchannels: true)
        #expect(LiveLineup.recordingStation([try title("1", serviceID: 0x4010, recording: false),
                                             try title("2", serviceID: 0x4011, recording: true)], in: all)?.channel.serviceID == 0x4011)
        #expect(LiveLineup.recordingStation([try title("1", serviceID: 0x4011, recording: false)], in: all) == nil)
        #expect(LiveLineup.recordingStation([try title("1", serviceID: 0x4011, recording: true, type: BroadcastingType.bs)], in: all) == nil)
        // ライブの一覧に無い（見られない）局を録画しているときは選ばない
        let unavailable = try #require(all.first { $0.unavailableReason != nil })
        #expect(LiveLineup.recordingStation([try title("1", serviceID: unavailable.channel.serviceID, recording: true)], in: all) == nil)
    }

    @Test("局の鍵は 10 進の「ネットワーク-TS-サービス」で保存して読み戻せる")
    func keyStorage() {
        let original = key(0x4011)
        #expect(LiveStationKey(storageValue: original.storageValue) == original)
        #expect(LiveStationKey(storageValue: "1-2") == nil)
    }
}

@MainActor
@Suite("ライブで見る局のモデル")
struct LiveModelTests {
    private func defaults() -> UserDefaults {
        let name = "LiveModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("読むまでは見られるか分からない。読んだら局ごとに見られるか・理由が分かる。ライブの一覧は地上の帯域だけを読む")
    func availability() async {
        let catalog = TerrestrialOnly(live: LiveLineupTests.liveChannels)
        let model = LiveModel(channels: ChannelCatalog(deviceInfo: LiveChannelsOnly(channels: channels)), catalog: catalog, programGuide: nil, defaults: defaults())
        #expect(model.availability(of: channels[2]) == .unknown)
        await model.load()
        #expect(model.availability(of: channels[2]) == .available)
        #expect(model.availability(of: channels[3]) == .unavailable(LiveText.notInLiveList))
        #expect(model.availability(of: channels[4]) == .unavailable(LiveText.noResource))
        #expect(catalog.bands == [BroadcastingType.terrestrial])
    }

    @Test("読み終えていれば読み直さず、ライブのボタン（reload）のときだけ読み直す。番組表が無ければ番組名はライブの item から")
    func reloadAndPrograms() async {
        let device = LiveChannelsOnly(channels: channels)
        let catalog = TerrestrialOnly(live: LiveLineupTests.liveChannels)
        let model = LiveModel(channels: ChannelCatalog(deviceInfo: device), catalog: catalog, programGuide: nil, defaults: defaults())
        await model.load()
        await model.load()
        #expect(device.calls == 1 && catalog.calls == 1)
        await model.load(reload: true)
        #expect(device.calls == 2 && catalog.calls == 2)
        #expect(model.programs[key(0x4011)] == "番組A")
        #expect(model.programs[key(0x4010)] == nil)   // 番組名の無い局
    }

    @Test("前に見た局を覚える")
    func remembersLastStation() {
        let store = defaults()
        let model = LiveModel(channels: ChannelCatalog(deviceInfo: LiveChannelsOnly(channels: channels)), catalog: TerrestrialOnly(live: []),
                              programGuide: nil, defaults: store)
        #expect(model.lastStation == nil)
        model.lastStation = key(0x4030)
        #expect(LiveModel(channels: ChannelCatalog(deviceInfo: LiveChannelsOnly(channels: channels)), catalog: TerrestrialOnly(live: []),
                          programGuide: nil, defaults: store).lastStation == key(0x4030))
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(5)) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
}

@MainActor
@Suite("ライブの受信の再生の制御")
struct LivePlaybackTests {
    private func controller(_ http: MockHTTP) throws -> PlaybackController {
        let store = DTCPMemoryCredentialStore(authorityKeys: testAuthority)
        try store.save(certificate: hexBytes(DTCPTestVectors.katSinkCert), privateKey: hexBytes(DTCPTestVectors.katSinkPriv))
        return PlaybackController(credentialStore: store, client: http, diagnostics: DTCPDiagnostics { _, _ in })
    }

    @Test("ライブは位置が無く、飛べず、視聴の位置を知らせない。始めている途中は止められない")
    func liveHasNoPosition() async throws {
        let controller = try controller(MockHTTP())
        var checkpoints: [PlaybackCheckpoint] = []
        controller.onCheckpoint = { checkpoints.append($0) }
        controller.playLive(liveResource("dr"))
        #expect(controller.kind == .live)
        #expect(controller.durationSeconds == nil)
        #expect(!controller.canSeek)
        #expect(controller.state.isStarting)
        controller.pause()
        controller.recordCheckpoint()
        controller.stop()
        #expect(checkpoints.isEmpty)
        // 録画を再生すれば録画に戻る
        controller.play(liveResource("dr"), durationSeconds: 300, from: 0)
        #expect(controller.kind == .recording)
        controller.stop()
    }

    @Test("ライブの HEAD が 511 のままなら、頼み直しを使い切ってから「ほかの機器が配信を使っている」と出す。始めている途中でも局を替えられ、最後の局だけを始める")
    func inUse() async throws {
        let http = MockHTTP()
        http.reply("/web/video/ch", method: "HEAD", status: LivePlaybackErrors.inUseStatus, body: Data())
        let controller = try controller(http)
        controller.playLive(liveResource("dr"))
        controller.playLive(liveResource("x3"))   // 続けて替えた
        await waitUntil { if case .failed = controller.state { true } else { false } }
        guard case .failed(let error, let stage) = controller.state else {
            Issue.record("失敗になっていない: \(controller.state)")
            return
        }
        #expect(stage == .head)
        #expect(error.title == ErrorText.nasneMessages["error.liveInUse"]?.title)
        #expect(error.code == String(LivePlaybackErrors.inUseStatus))
        let heads = http.sentRequests.filter { $0.httpMethod == "HEAD" }
        // 511 は間を置いて頼み直す（InUseRetryPolicy。2026-11-20）。頼むのは最後の局だけ
        #expect(heads.count == InUseRetryPolicy.delays.count + 1)
        #expect(heads.allSatisfy { $0.url?.query?.contains("x3") == true })
        // ライブは時間指定の見出しを付けない
        #expect(heads.allSatisfy { $0.value(forHTTPHeaderField: "TimeSeekRange.dlna.org") == nil })
    }

    @Test("ライブの途中で配信が終わったときの文言がある")
    func stoppedText() {
        let presented = ErrorText.present(LivePlaybackErrors.stopped)
        #expect(presented.title == ErrorText.nasneMessages["error.liveStopped"]?.title)
    }
}

@Suite("画質の切り替えの順と既定")
struct PlaybackQualityTests {
    @Test("Q キーの次の画質：並びの順に回り、最後なら最初へ。今の画質が無ければ最初。選べる画質が 1 つなら無し")
    func cycles() {
        let choices = [liveResource("dr"), liveResource("x3"), liveResource("mobile")]
        #expect(PlaybackQuality.next(after: choices[0], in: choices)?.quality == "x3")
        #expect(PlaybackQuality.next(after: choices[2], in: choices)?.quality == "dr")
        #expect(PlaybackQuality.next(after: nil, in: choices)?.quality == "dr")
        #expect(PlaybackQuality.next(after: choices[0], in: [choices[0]]) == nil)
    }

    @Test("ライブの局は DR・3倍・モバイルを選べ、無い画質を頼んだら元画質。設定の値が知らないものなら DR")
    func liveChoices() {
        let station = LiveStation(channel: channels[0], live: live(channels[0], resources: [liveResource("dr"), liveResource("x3"), liveResource("mobile")]))
        #expect(station.qualityChoices.map(\.quality) == ["dr", "x3", "mobile"])
        #expect(station.resource(preferring: "mobile")?.quality == "mobile")
        let drOnly = LiveStation(channel: channels[0], live: live(channels[0], resources: [liveResource("dr")]))
        #expect(drOnly.resource(preferring: "x3")?.quality == "dr")
        #expect(LiveQuality.saved(nil) == .dr)
        #expect(LiveQuality.saved("x3") == .x3)
        #expect(LiveQuality.saved("unknown") == .dr)
        #expect(LiveQuality.allCases.map(\.label) == ["DR", "3倍", "モバイル"])
    }
}

@MainActor
@Suite("再生中の画質の切り替え")
struct QualitySwitchTests {
    private func controller(_ http: MockHTTP) throws -> PlaybackController {
        let store = DTCPMemoryCredentialStore(authorityKeys: testAuthority)
        try store.save(certificate: hexBytes(DTCPTestVectors.katSinkCert), privateKey: hexBytes(DTCPTestVectors.katSinkPriv))
        return PlaybackController(credentialStore: store, client: http, diagnostics: DTCPDiagnostics { _, _ in })
    }

    @Test("再生していなければ切り替えない。始めている途中に切り替えたら、新しい画質だけを始める")
    func switchesWhileStarting() async throws {
        let http = MockHTTP()
        let controller = try controller(http)
        controller.switchQuality(liveResource("mobile"))
        #expect(controller.state == .idle && controller.currentResource == nil)
        controller.playLive(liveResource("dr"))
        controller.switchQuality(liveResource("mobile"))
        #expect(controller.currentResource?.quality == "mobile")
        #expect(controller.state.isStarting)
        await waitUntil { if case .failed = controller.state { true } else { false } }
        let heads = http.sentRequests.filter { $0.httpMethod == "HEAD" }
        #expect(heads.count == 1)
        #expect(heads.first?.url?.query?.contains("quality=mobile") == true)
    }
}
