import Foundation
import Synchronization
import Testing

// 番組表に並べる局。テレビのサービスだけ・サブチャンネルは既定で隠す・リモコンキーの順。
// 局のロゴは 1 回だけ読み、手動の更新で読み直し、読めなくても前のロゴを残す

/// チャンネル一覧だけを返す本体情報（ほかは使わない）
private struct ChannelsOnly: DeviceInfoService {
    let channels: [Channel]
    var fails = false

    func channels(broadcastingType: Int) async throws -> [Channel] {
        if fails { throw NasneError.unreachable("webapi:/status/channelListGet", cause: URLError(.timedOut)) }
        return channels
    }
    func deviceInfo() async throws -> DeviceInfo { throw NasneError.validation("test", "使わない") }
    func hddList() async throws -> [HDDEntry] { [] }
    func hddInfo(id: Int) async throws -> HDDInfo { throw NasneError.validation("test", "使わない") }
    func liveStatus() async throws -> LiveStatus { throw NasneError.validation("test", "使わない") }
    func recNgList() async throws -> [RecNgItem] { [] }
    func titleCounts() async throws -> (count: Int, max: Int) { (0, 0) }
}

/// ロゴだけを返す番組表のサービス（呼ばれた回数を数える）
private final class LogosOnly: ProgramGuideService, Sendable {
    private struct State {
        var logos: [Int: Data] = [0x4010: Data([0x89, 0x50, 0x4E, 0x47])]
        var calls = 0
        var fails = false
    }
    private let state = Mutex(State())

    var calls: Int { state.withLock { $0.calls } }
    func setFails(_ fails: Bool) { state.withLock { $0.fails = fails } }
    func setLogos(_ logos: [Int: Data]) { state.withLock { $0.logos = logos } }

    func logos(broadcastingType: Int) async throws -> [Int: Data] {
        let (logos, fails) = state.withLock { state -> ([Int: Data], Bool) in
            state.calls += 1
            return (state.logos, state.fails)
        }
        if fails { throw NasneError.unreachable("webapi:/chEpg/channelLogoDataGet", cause: URLError(.timedOut)) }
        return logos
    }
    func versionTable(broadcastingType: Int) async throws -> Data { throw NasneError.validation("test", "使わない") }
    func fetch(versionTable: Data) async throws -> EPGFetchResult { throw NasneError.validation("test", "使わない") }
}

private func channel(_ serviceID: Int, tsid: Int, type: Int = Channel.televisionServiceType, key: Int?) -> Channel {
    Channel(broadcastingType: BroadcastingType.terrestrial, networkID: 0x7E00 + tsid, transportStreamID: tsid,
            serviceID: serviceID, serviceType: type, channelNumber: serviceID, serviceName: "テスト局\(serviceID)",
            remoteControlKeyID: key)
}

/// 4 つの TS：TS 1 は本とサブ 2 つ（nasne はサブのキーを 0 で返す）、TS 2 は本だけ（キーなし）、TS 3 は本とデータ放送、
/// TS 4 は本（キー 2）とサブ 1 つ
private let sample = [
    channel(0x4010, tsid: 3, key: 1),
    channel(0x4012, tsid: 1, key: 0),
    channel(0x4011, tsid: 1, key: 4),
    channel(0x4013, tsid: 1, key: 0),
    channel(0x4020, tsid: 2, key: nil),
    channel(0x4019, tsid: 3, type: 0xC0, key: 1),
    channel(0x4031, tsid: 4, key: 0),
    channel(0x4030, tsid: 4, key: 2),
]

@MainActor
@Suite("番組表に並べる局")
struct GuideLineupModelTests {
    @Test("テレビのサービスだけを、リモコンキーの順に並べ、サブチャンネルは既定で隠す")
    func hidesSubchannelsByDefault() async {
        let model = GuideLineupModel(channels: ChannelCatalog(deviceInfo: ChannelsOnly(channels: sample)))
        await model.load()
        #expect(model.lineup.map(\.serviceID) == [0x4010, 0x4030, 0x4011, 0x4020])
    }

    @Test("設定でサブチャンネルも出す（キー 0 のサブは、同じ局の本チャンネルのすぐ右）")
    func showsSubchannels() async {
        let model = GuideLineupModel(channels: ChannelCatalog(deviceInfo: ChannelsOnly(channels: sample)), showsSubchannels: true)
        await model.load()
        #expect(model.lineup.map(\.serviceID) == [0x4010, 0x4030, 0x4031, 0x4011, 0x4012, 0x4013, 0x4020])
        model.showsSubchannels = false
        #expect(model.lineup.map(\.serviceID) == [0x4010, 0x4030, 0x4011, 0x4020])
        #expect(sample.first { $0.serviceID == 0x4012 }?.remoteControlKey == nil)   // 0 はキー無し
    }

    @Test("読めなければ失敗を出し、もう一度読める")
    func failureCanBeRetried() async {
        let failing = GuideLineupModel(channels: ChannelCatalog(deviceInfo: ChannelsOnly(channels: sample, fails: true)))
        await failing.load()
        guard case .failed(let error) = failing.channels else {
            Issue.record("失敗になっていない: \(failing.channels)")
            return
        }
        #expect(error.canRetry)
        #expect(failing.lineup.isEmpty)
    }

    @Test("ロゴは 1 回だけ読み、手動の更新のときだけ読み直す（読むのは共通の置き場。地上・BS・CS の 3 回）")
    func loadsLogosOnce() async {
        let source = LogosOnly()
        let logos = ChannelLogoModel(source: source, store: nil)
        let model = GuideLineupModel(channels: ChannelCatalog(deviceInfo: ChannelsOnly(channels: sample)), logos: logos)
        await model.loadLogos()
        #expect(model.logos.keys.sorted() == [0x4010])
        #expect(source.calls == ChannelLogoModel.bands.count)
        await model.loadLogos()
        #expect(source.calls == ChannelLogoModel.bands.count)   // 開き直しでは読み直さない
        source.setLogos([0x4010: Data([0x89, 0x50, 0x4E, 0x47]), 0x4011: Data([0x89, 0x50, 0x4E, 0x47])])
        await model.loadLogos(reload: true)
        #expect(source.calls == 2 * ChannelLogoModel.bands.count)
        #expect(model.logos.keys.sorted() == [0x4010, 0x4011])
    }

    @Test("ロゴが読めなくても誤りにせず前のロゴを残し、次に開いたときに読み直す")
    func logoFailureKeepsPrevious() async {
        let source = LogosOnly()
        source.setFails(true)
        let logos = ChannelLogoModel(source: source, store: nil)
        let model = GuideLineupModel(channels: ChannelCatalog(deviceInfo: ChannelsOnly(channels: sample)), logos: logos)
        await model.loadLogos()
        #expect(model.logos.isEmpty)
        source.setFails(false)
        await model.loadLogos()   // 読めていないので、開き直しで読み直す
        #expect(source.calls == 2 * ChannelLogoModel.bands.count)
        #expect(model.logos.count == 1)
        source.setFails(true)
        await model.loadLogos(reload: true)
        #expect(model.logos.count == 1)   // 失敗しても前のロゴを残す
    }

    @Test("ロゴの置き場が無ければ、ロゴは空のまま（番組表は出す）")
    func withoutLogoModel() async {
        let model = GuideLineupModel(channels: ChannelCatalog(deviceInfo: ChannelsOnly(channels: sample)))
        await model.loadLogos(reload: true)
        #expect(model.logos.isEmpty)
    }
}
