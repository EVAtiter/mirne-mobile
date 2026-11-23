import Foundation
import Synchronization
import Testing

// 番組表の取り直し。版数表が同じなら EPGGet を送らないこと・失敗の出し方・
// 二重に送らないこと・登録を外したときに番組表のファイルを全部消すことを確かめる

/// 版数表と EPGGet の呼ばれた回数を数える番組表のサービス
private final class CountingGuide: ProgramGuideService, Sendable {
    private struct State {
        var table = SyntheticEPG.versionTable([SyntheticEPG.service])
        var versionCalls = 0
        var fetchCalls = 0
        var fails = false
        var fetchDelay: Duration = .zero
    }
    private let state = Mutex(State())

    var versionCalls: Int { state.withLock { $0.versionCalls } }
    var fetchCalls: Int { state.withLock { $0.fetchCalls } }
    func changeTable() { state.withLock { $0.table = SyntheticEPG.versionTable([SyntheticEPG.service, SyntheticEPG.otherService]) } }
    func setFails(_ fails: Bool) { state.withLock { $0.fails = fails } }
    func setFetchDelay(_ delay: Duration) { state.withLock { $0.fetchDelay = delay } }

    func versionTable(broadcastingType: Int) async throws -> Data {
        let (table, fails) = state.withLock { state -> (Data, Bool) in
            state.versionCalls += 1
            return (state.table, state.fails)
        }
        if fails { throw NasneError.unreachable("webapi:/status/EPGVersionInfoGet", cause: URLError(.timedOut)) }
        return table
    }

    func fetch(versionTable: Data) async throws -> EPGFetchResult {
        let delay = state.withLock { state -> Duration in
            state.fetchCalls += 1
            return state.fetchDelay
        }
        if delay > .zero { try? await Task.sleep(for: delay) }
        let (sections, skipped) = EPGFormat.sections(inPlaintext: SyntheticEPG.plaintext())
        return EPGFetchResult(sections: sections, serviceCount: 1, responseBytes: 100, plaintextBytes: 100, skippedBytes: skipped)
    }

    func logos(broadcastingType: Int) async throws -> [Int: Data] { [:] }
}

extension SyntheticEPG {
    static var service: EPGServiceRef {
        EPGServiceRef(networkID: Int(networkID), transportStreamID: Int(transportStreamID), serviceID: Int(serviceID))
    }
    static var otherService: EPGServiceRef {
        EPGServiceRef(networkID: Int(networkID), transportStreamID: Int(transportStreamID), serviceID: Int(serviceID) + 1)
    }
}

/// 一時のフォルダーの番組表（試験の後で消す）
private func temporaryStoreURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("mirne-mobile-guide-\(UUID().uuidString)")
        .appendingPathComponent("epg.sqlite")
}

/// 合成の番組の日（EPGStore は受け取った時刻から 1 日より前に終わった番組を消すので、受け取った時刻を番組の日にする）
private let programDay = Date(timeIntervalSince1970: 1_794_790_500)

@MainActor
@Suite("番組表の取り直し")
struct ProgramGuideModelTests {
    @Test("初めは取り、版数表が同じなら EPGGet を送らず、変わったら取り直す")
    func skipsWhenVersionTableIsUnchanged() async throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let guide = CountingGuide()
        let model = ProgramGuideModel(service: guide, store: try EPGStore(fileURL: url),
                                      versions: MemoryProgramGuideVersionStore(), now: { programDay })
        await model.refresh()
        #expect(guide.fetchCalls == 1)
        #expect(model.state == .updated(at: programDay, changed: true))
        #expect(model.store.storedServices().count == 1)
        #expect(model.revision == 1)   // 画面はこれが変わったら読み直す

        await model.refresh()
        #expect(guide.versionCalls == 2)
        #expect(guide.fetchCalls == 1)   // 同じ版数表なので送らない
        #expect(model.state == .updated(at: programDay, changed: false))
        #expect(model.revision == 1)   // 書き込んでいないので読み直させない

        guide.changeTable()
        await model.refresh()
        #expect(guide.fetchCalls == 2)
        #expect(model.state == .updated(at: programDay, changed: true))
    }

    @Test("版数表が同じでも、番組表が空なら取る（消したあとなど）")
    func fetchesWhenStoreIsEmpty() async throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let guide = CountingGuide()
        let table = try await guide.versionTable(broadcastingType: BroadcastingType.terrestrial)
        let versions = MemoryProgramGuideVersionStore(digest: ProgramGuideModel.digest(table))
        let model = ProgramGuideModel(service: guide, store: try EPGStore(fileURL: url), versions: versions, now: { programDay })
        await model.refresh()
        #expect(guide.fetchCalls == 1)
    }

    @Test("届かなければ失敗を出し、控えを書かない（次は取り直す）")
    func failureKeepsVersion() async throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let guide = CountingGuide()
        guide.setFails(true)
        let versions = MemoryProgramGuideVersionStore()
        let model = ProgramGuideModel(service: guide, store: try EPGStore(fileURL: url), versions: versions, now: { programDay })
        await model.refresh()
        guard case .failed(let error) = model.state else {
            Issue.record("失敗になっていない: \(model.state)")
            return
        }
        #expect(error.canRetry)
        #expect(versions.load() == nil)
        guide.setFails(false)
        await model.refresh()
        #expect(guide.fetchCalls == 1)
        #expect(versions.load() != nil)
    }

    @Test("見回りの取り直しは状態を変えない（届かなくても失敗を出さず、版数表が同じなら前の状態のまま）")
    func quietFailureKeepsState() async throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let guide = CountingGuide()
        let model = ProgramGuideModel(service: guide, store: try EPGStore(fileURL: url),
                                      versions: MemoryProgramGuideVersionStore(), now: { programDay })
        await model.refresh()
        let before = model.state
        guide.setFails(true)
        await model.refreshQuietly()
        #expect(model.state == before)
        // 版数表が同じなら、状態を変えずに終える（読んでいる間も checking にしない）
        guide.setFails(false)
        await model.refreshQuietly()
        #expect(model.state == before)
    }

    @Test("取り直している間にもう一度頼んでも、EPGGet は 1 回だけ")
    func doesNotFetchTwice() async throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let guide = CountingGuide()
        guide.setFetchDelay(.milliseconds(200))
        let model = ProgramGuideModel(service: guide, store: try EPGStore(fileURL: url),
                                      versions: MemoryProgramGuideVersionStore(), now: { programDay })
        async let first: Void = model.refresh()
        async let second: Void = model.refresh()
        _ = await (first, second)
        #expect(guide.fetchCalls == 1)
        #expect(guide.versionCalls == 1)
    }

    @Test("登録を外すときは、番組表・その隣の記録・版数表の控えを全部消す")
    func deletesAllFiles() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let versionURL = ProgramGuideFiles.versionURL(storeURL: url)
        let paths = [url.path, url.path + "-wal", url.path + "-shm", versionURL.path]
        for path in paths { FileManager.default.createFile(atPath: path, contents: Data("x".utf8)) }
        let neighbor = url.deletingLastPathComponent().appendingPathComponent("registration.json")
        FileManager.default.createFile(atPath: neighbor.path, contents: Data("{}".utf8))
        try ProgramGuideFiles.delete(storeURL: url)
        for path in paths { #expect(!FileManager.default.fileExists(atPath: path), "残っている: \(path)") }
        #expect(FileManager.default.fileExists(atPath: neighbor.path))   // 番組表のほかは消さない
        try ProgramGuideFiles.delete(storeURL: url)   // 無くても誤りにしない
    }

    @Test("控えのファイルの行き来")
    func versionFile() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let versions = FileProgramGuideVersionStore(fileURL: ProgramGuideFiles.versionURL(storeURL: url))
        #expect(versions.load() == nil)
        try versions.save("abc")
        #expect(versions.load() == "abc")
        try versions.delete()
        #expect(versions.load() == nil)
    }
}
