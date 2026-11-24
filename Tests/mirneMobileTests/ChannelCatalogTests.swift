import Foundation
import Synchronization
import Testing

// 局の一覧（ChannelCatalog）を録画・予約・番組表・ライブの画面で共通に持つ（2026-11-21）。
// 前は 4 つのモデルがそれぞれ nasne から取っていた

/// チャンネル一覧を返し、頼まれた回数を数える本体情報。`next` で返す一覧と失敗を替えられる
private final class CountingChannels: DeviceInfoService, Sendable {
    private struct State {
        var channels: [Channel]
        var fails = false
        var calls = 0
    }

    private let state: Mutex<State>

    init(_ channels: [Channel]) {
        state = Mutex(State(channels: channels))
    }

    var calls: Int { state.withLock { $0.calls } }

    func next(_ channels: [Channel]? = nil, fails: Bool = false) {
        state.withLock {
            if let channels { $0.channels = channels }
            $0.fails = fails
        }
    }

    func channels(broadcastingType: Int) async throws -> [Channel] {
        let (channels, fails) = state.withLock { state -> ([Channel], Bool) in
            state.calls += 1
            return (state.channels, state.fails)
        }
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

/// 予約の一覧（空）
private struct NoSchedules: ScheduleService {
    func schedules() async throws -> [RecordSchedule] { [] }
    func conflicts(for schedule: NewRecordSchedule) async throws -> [RecordSchedule] { [] }
    func create(_ schedule: NewRecordSchedule) async throws -> String { "" }
    func update(_ update: ScheduleUpdate) async throws {}
    func delete(id: String) async throws {}
}

/// テスト局（地上・テレビ）
private func station(_ serviceID: Int, name: String, key: Int) -> Channel {
    Channel(broadcastingType: BroadcastingType.terrestrial, networkID: 0x7E00 + key, transportStreamID: key,
            serviceID: serviceID, serviceType: Channel.televisionServiceType, channelNumber: key, serviceName: name,
            remoteControlKeyID: key)
}

@MainActor
struct ChannelCatalogTests {
    private let first = [station(0x4010, name: "テスト局1", key: 1), station(0x4020, name: "テスト局2", key: 2)]
    private let second = [station(0x4010, name: "テスト局1", key: 1)]

    @Test func screensShareOneRequest() async {
        let device = CountingChannels(first)
        let catalog = ChannelCatalog(deviceInfo: device)
        let lineup = GuideLineupModel(channels: catalog)
        let schedules = SchedulesModel(schedules: NoSchedules(), channels: catalog, liveStatus: LiveStatusMonitor(deviceInfo: device, initialLink: .online))
        // 続けて読んでも、読んでいる途中のものを待ち、読めた後は読み直さない
        async let a: Void = lineup.load()
        async let b: Void = schedules.reload()
        _ = await (a, b)
        await lineup.load()
        #expect(device.calls == 1)
        #expect(lineup.lineup.map(\.serviceID) == [0x4010, 0x4020])
        #expect(schedules.channels.map(\.serviceID) == [0x4010, 0x4020])
    }

    @Test func reloadUpdatesEveryScreen() async {
        let device = CountingChannels(first)
        let catalog = ChannelCatalog(deviceInfo: device)
        let lineup = GuideLineupModel(channels: catalog)
        await lineup.load()
        device.next(second)
        await catalog.load(reload: true)
        #expect(device.calls == 2)
        #expect(lineup.lineup.map(\.serviceID) == [0x4010])
    }

    @Test func failedReloadKeepsPreviousList() async {
        let device = CountingChannels(first)
        let catalog = ChannelCatalog(deviceInfo: device)
        await catalog.load()
        device.next(fails: true)
        await catalog.load(reload: true)
        #expect(catalog.channels.value?.count == 2)
        #expect(catalog.channels.error == nil)
    }

    @Test func failureIsShownUntilLoaded() async {
        let device = CountingChannels(first)
        device.next(fails: true)
        let catalog = ChannelCatalog(deviceInfo: device)
        let schedules = SchedulesModel(schedules: NoSchedules(), channels: catalog, liveStatus: LiveStatusMonitor(deviceInfo: device, initialLink: .online))
        await catalog.load()
        #expect(catalog.channels.error != nil)
        #expect(schedules.channelName(ScheduleChannel(broadcastingType: 2, channelType: 2, serviceID: 0x4010)) == "サービス 0x4010")
        // 失敗していたら、reload でなくても読み直す
        device.next()
        await catalog.load()
        #expect(device.calls == 2)
        #expect(schedules.channelName(ScheduleChannel(broadcastingType: 2, channelType: 2, serviceID: 0x4010)) == "テスト局1")
    }
}
