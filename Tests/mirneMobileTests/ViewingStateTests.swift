import Foundation
import SQLite3
import Testing

// 視聴の状態。録画は架空のもの

/// 架空の録画（長さ 1800 秒。新着の印・nasne の前回の再生の時刻と再開位置を指定できる）
private func title(_ id: String = "1", isNew: Bool = false, lastPlayback: String? = nil, resume: Int? = nil,
                   start: String = "2026-01-05T21:00:00+09:00") throws -> RecordedTitle {
    var fields = ["title": "架空番組", "scheduledStartDateTime": start, "scheduledDuration": "1800", "titleNewFlag": isNew ? "1" : "0"]
    var attributes: [String: [String: String]] = [:]
    if let lastPlayback {
        fields["lastPlaybackTime"] = lastPlayback
        attributes["lastPlaybackTime"] = ["resumePoint": String(resume ?? 0)]
    }
    return try RecordedTitle(item: XSRSItem(id: id, fields: fields, attributes: attributes), source: "test")
}

private func date(_ text: String) throws -> Date { try #require(NasneDateTime.parse(text)) }

@Suite("視聴の状態の決まり")
struct ViewingPolicyTests {
    @Test("残りが 60 秒を切っていれば完了、切っていなければ途中まで。長さが分からなければ途中まで")
    func completion() {
        #expect(ViewingPolicy.state(position: 1741, duration: 1800) == .completed)
        #expect(ViewingPolicy.state(position: 1740, duration: 1800) == .interrupted(seconds: 1740))
        #expect(ViewingPolicy.state(position: 1790, duration: nil) == .interrupted(seconds: 1790))
    }

    @Test("手元の記録が無ければ nasne の値から：再開位置があれば途中まで、新着なら未再生、どちらも無ければ完了")
    func withoutLocalRecord() throws {
        #expect(ViewingPolicy.resolve(try title(isNew: true), local: nil) == .unwatched)
        #expect(ViewingPolicy.resolve(try title(lastPlayback: "2026-01-06T10:00:00+09:00", resume: 600), local: nil)
                == .interrupted(seconds: 600))
        // 新着の印が残っていても、再開位置があれば途中まで（実機で 2 件あった形）
        #expect(ViewingPolicy.resolve(try title(isNew: true, lastPlayback: "2026-01-06T10:00:00+09:00", resume: 65), local: nil)
                == .interrupted(seconds: 65))
        // 再開位置が終わり近くなら完了
        #expect(ViewingPolicy.resolve(try title(lastPlayback: "2026-01-06T10:00:00+09:00", resume: 1780), local: nil) == .completed)
        // 新着の印が消えていて再開位置が 0
        #expect(ViewingPolicy.resolve(try title(lastPlayback: "2026-01-06T10:00:00+09:00", resume: 0), local: nil) == .completed)
        #expect(ViewingPolicy.resolve(try title(), local: nil) == .completed)
        // 新着の印が残っていても、前回の再生の時刻があれば未再生にしない（ほかの端末で見終えて 0 を書き戻した形）
        #expect(ViewingPolicy.resolve(try title(isNew: true, lastPlayback: "2026-01-06T10:00:00+09:00", resume: 0), local: nil)
                == .completed)
    }

    @Test("手元の記録より nasne の前回の再生が新しければ nasne の値、古ければ手元の記録")
    func localAndNasne() throws {
        let recorded = try title(isNew: true, lastPlayback: "2026-01-06T10:00:00+09:00", resume: 300)
        let local = ViewingRecord(key: ViewingKey(recorded), state: .interrupted(seconds: 900),
                                  updatedAt: try date("2026-01-07T10:00:00+09:00"))
        #expect(ViewingPolicy.resolve(recorded, local: local) == .interrupted(seconds: 900))
        let older = ViewingRecord(key: ViewingKey(recorded), state: .completed, updatedAt: try date("2026-01-05T23:00:00+09:00"))
        #expect(ViewingPolicy.resolve(recorded, local: older) == .interrupted(seconds: 300))
        // nasne が新しく再開位置が 0 なら完了（新着の印が残っていても未再生には戻さない）
        let watchedOnNasne = try title(isNew: true, lastPlayback: "2026-01-08T10:00:00+09:00", resume: 0)
        #expect(ViewingPolicy.resolve(watchedOnNasne, local: local) == .completed)
        // nasne に前回の再生が無ければ手元の記録
        #expect(ViewingPolicy.resolve(try title(isNew: true), local: local) == .interrupted(seconds: 900))
    }

    @Test("表記：未再生・見終わった・途中まで（位置と残り）")
    func format() {
        #expect(RecordingFormat.viewing(.unwatched, duration: 1800) == "未再生")
        #expect(RecordingFormat.viewing(.completed, duration: 1800) == "見終わった")
        #expect(RecordingFormat.viewing(.interrupted(seconds: 720), duration: 1800) == "途中まで（12 分・残り 18 分）")
        #expect(RecordingFormat.viewing(.interrupted(seconds: 720), duration: nil) == "途中まで（12 分）")
        #expect(RecordingFormat.remainingSeconds(.completed, duration: 1800) == nil)
    }
}

/// 試験ごとの一時の保存先
private func temporaryLibraryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ViewingStateTests-\(UUID().uuidString)")
        .appendingPathComponent("library.sqlite")
}

@Suite("視聴の記録の保存")
struct ViewingStoreTests {
    @Test("1 件ずつ上書きして読める（鍵はタイトル ID と録画の開始日時。nasne ごとに分かれる）")
    func roundTrip() async throws {
        let url = temporaryLibraryURL()
        defer { try? LibraryStore.delete(fileURL: url) }
        let store = try LibraryStore(fileURL: url)
        let first = try title("1")
        let reused = try title("1", start: "2026-02-01T21:00:00+09:00")   // 同じ ID で別の録画
        let at = try date("2026-01-07T10:00:00+09:00")
        await store.saveViewing(ViewingRecord(key: ViewingKey(first), state: .interrupted(seconds: 120), updatedAt: at), udn: "uuid:a")
        await store.saveViewing(ViewingRecord(key: ViewingKey(first), state: .interrupted(seconds: 600.5), updatedAt: at), udn: "uuid:a")
        await store.saveViewing(ViewingRecord(key: ViewingKey(reused), state: .completed, updatedAt: at), udn: "uuid:a")
        let unknownStart = ViewingKey(titleID: "9", recordedStart: nil)
        await store.saveViewing(ViewingRecord(key: unknownStart, state: .completed, updatedAt: at), udn: "uuid:a")
        let records = await (try LibraryStore(fileURL: url)).viewingRecords(udn: "uuid:a")
        #expect(records.count == 3)
        #expect(records[ViewingKey(first)]?.state == .interrupted(seconds: 600.5))
        #expect(records[ViewingKey(reused)]?.state == .completed)
        #expect(records[unknownStart]?.updatedAt == at)
        #expect(await store.viewingRecords(udn: "uuid:b").isEmpty)
    }

    @Test("一覧を差し替えると、nasne から消えた録画の記録も消える")
    func prunesWithList() async throws {
        let url = temporaryLibraryURL()
        defer { try? LibraryStore.delete(fileURL: url) }
        let store = try LibraryStore(fileURL: url)
        let kept = try title("1"), gone = try title("2")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        for recorded in [kept, gone] {
            await store.saveViewing(ViewingRecord(key: ViewingKey(recorded), state: .completed, updatedAt: at), udn: "uuid:a")
        }
        await store.saveViewing(ViewingRecord(key: ViewingKey(gone), state: .completed, updatedAt: at), udn: "uuid:b")
        await store.saveTitleList(SavedTitleList(titles: [kept], fetchedAt: at), udn: "uuid:a")
        #expect(Set(await store.viewingRecords(udn: "uuid:a").keys) == [ViewingKey(kept)])
        #expect(await store.viewingRecords(udn: "uuid:b").count == 1)   // ほかの nasne の記録は触らない
    }

    @Test("表の作りが版 1（キャッシュだけ）なら、キャッシュを残して視聴の表を足す")
    func migratesFromVersion1() async throws {
        let url = temporaryLibraryURL()
        defer { try? LibraryStore.delete(fileURL: url) }
        let store = try LibraryStore(fileURL: url)
        let list = SavedTitleList(titles: [try title("1")], fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))
        await store.saveTitleList(list, udn: "uuid:a")
        await store.close()
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "DROP TABLE viewing; PRAGMA user_version = 1", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let reopened = try LibraryStore(fileURL: url)
        #expect(await reopened.titleList(udn: "uuid:a") == list)
        let record = ViewingRecord(key: ViewingKey(titleID: "1", recordedStart: nil), state: .completed, updatedAt: Date(timeIntervalSince1970: 1))
        await reopened.saveViewing(record, udn: "uuid:a")
        #expect(await reopened.viewingRecords(udn: "uuid:a").count == 1)
    }
}

@MainActor
@Suite("視聴の記録")
struct ViewingRecorderTests {
    @Test("再生している録画の止めどころを記録して保存する。最後までなら完了。始める前の止めどころは記録しない")
    func records() async throws {
        let url = temporaryLibraryURL()
        defer { try? LibraryStore.delete(fileURL: url) }
        let store = try LibraryStore(fileURL: url)
        let at = try date("2026-01-07T10:00:00+09:00")
        let recorder = ViewingRecorder(udn: "uuid:a", library: store, now: { at })
        let first = try title("1", isNew: true), second = try title("2", isNew: true)
        recorder.record(PlaybackCheckpoint(position: 100, duration: 1800, ended: false))   // まだ何も再生していない
        #expect(recorder.records.isEmpty)
        #expect(recorder.state(of: first) == .unwatched)

        recorder.begin(first)
        recorder.record(PlaybackCheckpoint(position: 300, duration: 1800, ended: false))
        #expect(recorder.state(of: first) == .interrupted(seconds: 300))
        recorder.begin(second)
        recorder.record(PlaybackCheckpoint(position: 1800, duration: 1800, ended: true))
        #expect(recorder.state(of: second) == .completed)
        #expect(recorder.state(of: first) == .interrupted(seconds: 300))
        await recorder.flush()

        let reloaded = ViewingRecorder(udn: "uuid:a", library: store)
        await reloaded.load()
        #expect(reloaded.state(of: first) == .interrupted(seconds: 300))
        #expect(reloaded.state(of: second) == .completed)
    }
}

/// 試験で進める時計
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

/// 書き戻しの偽の送り先（送った録画の ID と位置を順に覚える）
private actor ResumeWrites: ResumePositionService {
    private(set) var sent: [(id: String, seconds: Double)] = []
    func setResumePosition(id: String, seconds: Double) async throws { sent.append((id, seconds)) }
}

@MainActor
@Suite("再開位置の書き戻し")
struct ResumeWriteBackTests {
    /// 毎回別の UserDefaults（設定の鍵を試験の間で持ち越さない）
    private func defaults() throws -> UserDefaults {
        let name = "ResumeWriteBackTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("録画から離れたときだけ書き戻す：途中までは止めた位置、見終わったら 0。定期の記録と一時停止では送らない")
    func writesOnLeave() async throws {
        let writes = ResumeWrites()
        let clock = TestClock(try date("2026-01-07T10:00:00+09:00"))
        let recorder = ViewingRecorder(udn: "uuid:a", library: nil, resumePositions: writes, defaults: try defaults(), now: { clock.now })
        recorder.begin(try title("1"))
        recorder.record(PlaybackCheckpoint(position: 100, duration: 1800, ended: false))
        recorder.record(PlaybackCheckpoint(position: 200, duration: 1800, ended: false, occasion: .paused))
        recorder.record(PlaybackCheckpoint(position: 300.7, duration: 1800, ended: false, occasion: .left))
        clock.advance(60)
        recorder.begin(try title("2"))
        recorder.record(PlaybackCheckpoint(position: 1790, duration: 1800, ended: false, occasion: .left))   // 残り 60 秒を切った
        clock.advance(60)
        recorder.begin(try title("3"))
        recorder.record(PlaybackCheckpoint(position: 1800, duration: 1800, ended: true, occasion: .left))
        await recorder.flush()
        let sent = await writes.sent
        #expect(sent.map(\.id) == ["1", "2", "3"])
        #expect(sent.map(\.seconds) == [300.7, 0, 0])
    }

    @Test("同じ録画・同じ位置を続けて送らない（1 回の操作で二度知らせが来る）。間を置けば送る")
    func skipsDuplicate() async throws {
        let writes = ResumeWrites()
        let clock = TestClock(try date("2026-01-07T10:00:00+09:00"))
        let recorder = ViewingRecorder(udn: "uuid:a", library: nil, resumePositions: writes, defaults: try defaults(), now: { clock.now })
        recorder.begin(try title("1"))
        recorder.record(PlaybackCheckpoint(position: 300, duration: 1800, ended: false, occasion: .left))
        recorder.record(PlaybackCheckpoint(position: 300.4, duration: 1800, ended: false, occasion: .left))
        clock.advance(ViewingPolicy.writeBackDuplicateWindow + 1)
        recorder.record(PlaybackCheckpoint(position: 300, duration: 1800, ended: false, occasion: .left))
        await recorder.flush()
        #expect(await writes.sent.count == 2)
    }

    @Test("設定で切ってある・録画中の録画・送り先が無いときは送らない（手元の記録はする）")
    func doesNotWrite() async throws {
        let writes = ResumeWrites()
        let off = try defaults()
        off.set(false, forKey: ViewingSettingsKey.writesResumePosition)
        let disabled = ViewingRecorder(udn: "uuid:a", library: nil, resumePositions: writes, defaults: off)
        disabled.begin(try title("1"))
        disabled.record(PlaybackCheckpoint(position: 300, duration: 1800, ended: false, occasion: .left))
        #expect(disabled.state(of: try title("1")) == .interrupted(seconds: 300))

        let recorder = ViewingRecorder(udn: "uuid:a", library: nil, resumePositions: writes, defaults: try defaults())
        var recording = try title("2")
        recording.isRecording = true
        recorder.begin(recording)
        recorder.record(PlaybackCheckpoint(position: 300, duration: nil, ended: false, occasion: .left))
        await disabled.flush()
        await recorder.flush()
        #expect(await writes.sent.isEmpty)
    }
}
