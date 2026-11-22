import Foundation
import Synchronization
import Testing

// 局のロゴの共通の置き場。

/// 放送の種類ごとに違うロゴを返す（種類を失敗させることもできる）
private final class BandLogos: ProgramGuideService, Sendable {
    private struct State {
        var logos: [Int: [Int: Data]]
        var failing: Set<Int> = []
    }
    private let state: Mutex<State>

    init(_ logos: [Int: [Int: Data]]) { state = Mutex(State(logos: logos)) }
    func setFailing(_ bands: Set<Int>) { state.withLock { $0.failing = bands } }
    func setLogos(_ logos: [Int: [Int: Data]]) { state.withLock { $0.logos = logos } }

    func logos(broadcastingType: Int) async throws -> [Int: Data] {
        let (logos, fails) = state.withLock { ($0.logos[broadcastingType] ?? [:], $0.failing.contains(broadcastingType)) }
        if fails { throw NasneError.unreachable("webapi:/chEpg/channelLogoDataGet", cause: URLError(.timedOut)) }
        return logos
    }
    func versionTable(broadcastingType: Int) async throws -> Data { throw NasneError.validation("test", "使わない") }
    func fetch(versionTable: Data) async throws -> EPGFetchResult { throw NasneError.validation("test", "使わない") }
}

private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
private let otherPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x02])

@MainActor
@Suite("局のロゴの置き場")
struct ChannelLogoModelTests {
    private func temporaryStore() throws -> (EPGStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("logos-\(UUID().uuidString).sqlite")
        return (try EPGStore(fileURL: url), url)
    }

    private func remove(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix)) }
    }

    @Test("地上・BS・CS を読み、種類と serviceID を鍵にして持つ（serviceID が重なっても別のロゴ）")
    func keysByBandAndService() async {
        let source = BandLogos([BroadcastingType.terrestrial: [0x0400: png], BroadcastingType.bs: [0x0400: otherPNG],
                                BroadcastingType.cs: [0x0200: png]])
        let model = ChannelLogoModel(source: source, store: nil)
        await model.refresh()
        #expect(model.logos.count == 3)
        #expect(model.logos[ChannelLogoKey(broadcastingType: BroadcastingType.terrestrial, serviceID: 0x0400)] == png)
        #expect(model.logos[ChannelLogoKey(broadcastingType: BroadcastingType.bs, serviceID: 0x0400)] == otherPNG)
        #expect(model.terrestrial == [0x0400: png])
        #expect(model.fetched)
    }

    @Test("読めなかった種類は前のロゴのまま。読めた種類だけ差し替える")
    func failedBandKeepsPrevious() async {
        let source = BandLogos([BroadcastingType.terrestrial: [1: png], BroadcastingType.bs: [2: png]])
        let model = ChannelLogoModel(source: source, store: nil)
        await model.refresh()
        source.setLogos([BroadcastingType.terrestrial: [3: otherPNG], BroadcastingType.bs: [4: otherPNG]])
        source.setFailing([BroadcastingType.bs])
        await model.refresh()
        let keys = Set(model.logos.keys)
        #expect(keys == [ChannelLogoKey(broadcastingType: BroadcastingType.terrestrial, serviceID: 3),
                         ChannelLogoKey(broadcastingType: BroadcastingType.bs, serviceID: 2)])
    }

    @Test("読めたロゴは番組表の保存先に入り、次に起動したときは保存したロゴをすぐ出す")
    func savesAndLoads() async throws {
        let (store, url) = try temporaryStore()
        defer { remove(url) }
        let source = BandLogos([BroadcastingType.terrestrial: [1: png], BroadcastingType.cs: [5: otherPNG]])
        let first = ChannelLogoModel(source: source, store: store)
        await first.refresh()
        store.flush()
        let next = ChannelLogoModel(source: nil, store: store)
        next.loadSaved()
        #expect(next.logos == first.logos)
        #expect(next.revision == 1)
    }

    @Test("保存し直すと、その種類のロゴは丸ごと差し替わる（nasne から消えた局のロゴは残らない）")
    func saveReplacesBand() throws {
        let (store, url) = try temporaryStore()
        defer { remove(url) }
        store.saveLogos([1: png, 2: png], broadcastingType: BroadcastingType.terrestrial, receivedAt: Date())
        store.saveLogos([9: png], broadcastingType: BroadcastingType.bs, receivedAt: Date())
        store.saveLogos([2: otherPNG], broadcastingType: BroadcastingType.terrestrial, receivedAt: Date())
        let saved = store.logos()
        #expect(saved == [ChannelLogoKey(broadcastingType: BroadcastingType.terrestrial, serviceID: 2): otherPNG,
                          ChannelLogoKey(broadcastingType: BroadcastingType.bs, serviceID: 9): png])
    }

    @Test("読めないままなら空で、読めたことにしない")
    func allFail() async {
        let source = BandLogos([:])
        source.setFailing(Set(ChannelLogoModel.bands))
        let model = ChannelLogoModel(source: source, store: nil)
        await model.refresh()
        #expect(model.logos.isEmpty)
        #expect(!model.fetched)
        #expect(model.revision == 0)
    }
}
