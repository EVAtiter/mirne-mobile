import Foundation
import SQLite3
import Synchronization
import Testing

// 録画一覧と詳細。

/// 素材の xsrs と DIDL を返す
private func catalogHTTP() -> MockHTTP {
    let http = MockHTTP()
    http.reply("/XSRS", method: "POST", body: NasneFixture.data("soap/title_list.xml"))
    let envelope = """
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">\
        <Result>\(XMLTree.escapeText(NasneFixture.text("dlna/browse_0_video_all.xml")))</Result>\
        <NumberReturned>2</NumberReturned></u:BrowseResponse></s:Body></s:Envelope>
        """
    http.reply("/MediaServer_ContentDirectory/control", method: "POST", body: Data(envelope.utf8))
    return http
}

private func services(_ http: MockHTTP) throws -> NasneServices {
    try NasneServices.live(registration: RegisteredNasne(host: NasneFixture.host, udn: "uuid:test", friendlyName: "test",
                                                         macAddress: "00:00:5e:00:53:01"),
                           device: NasneDevice.direct(host: NasneFixture.host), client: http)
}

@MainActor
@Suite("録画一覧")
struct RecordingsModelTests {
    @Test("DIDL を結合した一覧を読み込み、ジャンル（複数）も持つ。並べ替えは日時")
    func loadsAndSorts() async throws {
        let model = RecordingsModel(services: try services(catalogHTTP()))
        await model.reload()
        let titles = try #require(model.titles.value)
        #expect(titles.count == 2)
        #expect(titles.allSatisfy { !$0.genres.isEmpty })
        #expect(titles.contains { $0.genres.count == 2 })
        let newest = model.visibleTitles.compactMap(\.start)
        #expect(newest == newest.sorted(by: >))
        model.sortOrder = .oldestFirst
        let oldest = model.visibleTitles.compactMap(\.start)
        #expect(oldest == oldest.sorted())
    }

    @Test("見回り：録画の一覧の世代が同じなら読まず、違えば 1 段目だけを読み直す（全件の番組の情報は読まない）。届かなくても知らせない")
    func refreshWhenGenerationChanges() async throws {
        let http = catalogHTTP()
        let generation = Mutex(186)
        http.respond("/status/liveStreamStatusListGet") { _ in
            MockHTTP.Reply(status: 200, body: Data(#"{"errorcode":0,"recContentsList":{"generation":\#(generation.withLock { $0 })}}"#.utf8))
        }
        let services = try services(http)
        let monitor = LiveStatusMonitor(deviceInfo: services.deviceInfo, initialLink: .online)
        let model = RecordingsModel(services: services, liveStatus: monitor)
        func count(_ path: String) -> Int { http.sentRequests.filter { $0.url?.path == path }.count }
        await monitor.poll()
        await model.reload()
        let lists = count("/XSRS")
        let browses = count("/MediaServer_ContentDirectory/control")
        await model.refreshIfChanged()
        #expect(count("/XSRS") == lists)
        generation.withLock { $0 = 191 }
        await monitor.poll()
        await model.refreshIfChanged()
        #expect(count("/XSRS") == lists + 1)
        #expect(count("/MediaServer_ContentDirectory/control") == browses)
        #expect(model.titles.value?.count == 2)
        // 見回りからの取り直しが届かなくても、誤りを知らせず一覧を残す
        generation.withLock { $0 = 192 }
        await monitor.poll()
        http.failNext("/XSRS", method: "POST", count: 10)
        await model.refreshIfChanged()
        #expect(model.refreshError == nil)
        #expect(!model.showsRefreshProgress)
        #expect(model.titles.value?.count == 2)
    }

    @Test("番組名・局名で絞り込む。視聴の状態でも絞り込める")
    func filters() async throws {
        let model = RecordingsModel(services: try services(catalogHTTP()))
        await model.reload()
        let all = model.visibleTitles
        model.searchText = all[0].title
        #expect(model.visibleTitles.map(\.id) == [all[0].id])
        model.searchText = "テスト局1"
        #expect(model.visibleTitles.count == 2)
        model.searchText = "当てはまらない文字"
        #expect(model.visibleTitles.isEmpty)
        model.searchText = ""
        // 素材の 2 件は新着の印が無く、nasne の再開位置（16 秒・14 秒）があるので途中まで（手元の記録が無いとき）
        #expect(model.visibleTitles.map { model.viewingState(of: $0) }.allSatisfy { $0.resumeSeconds != nil })
        model.viewingFilter = .unwatched
        #expect(model.visibleTitles.isEmpty)
        model.viewingFilter = .interrupted
        #expect(model.visibleTitles.count == 2)
    }

    @Test("選んだ録画は、読み込み直してもあれば選んだまま。無くなれば外す")
    func keepsSelection() async throws {
        let http = catalogHTTP()
        let model = RecordingsModel(services: try services(http))
        await model.reload()
        let first = try #require(model.visibleTitles.first)
        model.selectedID = first.id
        #expect(model.selectedTitle?.id == first.id)
        await model.reload()
        #expect(model.selectedID == first.id)
        model.selectedID = "存在しない"
        await model.reload()
        #expect(model.selectedID == nil)
    }

    @Test("読み込みが失敗したら誤りを持つ")
    func failure() async throws {
        let http = MockHTTP()
        http.reply("/XSRS", method: "POST", status: 500, body: Data())
        let model = RecordingsModel(services: try services(http))
        await model.reload()
        guard case .failed(let error) = model.titles else {
            Issue.record("失敗になっていない")
            return
        }
        #expect(error.code == "500")
    }
}

/// 架空の録画（番組名・日時・局・ジャンル・新着）
private func fictitiousTitle(_ id: String, _ title: String, day: Int, serviceID: Int? = nil, channelName: String? = nil,
                             genre: String? = nil, isNew: Bool = false, lastPlayback: String? = nil, resume: Int? = nil) throws -> RecordedTitle {
    let start = String(format: "2026-01-%02dT21:00:00+09:00", day)
    var fields = ["title": title, "scheduledStartDateTime": start, "scheduledDuration": "1800", "titleNewFlag": isNew ? "1" : "0"]
    var attributes: [String: [String: String]] = [:]
    if let lastPlayback {
        fields["lastPlaybackTime"] = lastPlayback
        attributes["lastPlaybackTime"] = ["resumePoint": String(resume ?? 0)]
    }
    if let serviceID { fields["scheduledChannelID"] = String(format: "0x%04x", serviceID) }
    var recorded = try RecordedTitle(item: XSRSItem(id: id, fields: fields, attributes: attributes), source: "test")
    recorded.channelName = channelName
    recorded.genres = genre.map { [$0] } ?? []
    return recorded
}

@MainActor
@Suite("録画一覧の並べ替えとまとめ")
struct RecordingsArrangementTests {
    private func model() throws -> RecordingsModel {
        let defaults = try #require(UserDefaults(suiteName: "RecordingsArrangementTests.\(UUID().uuidString)"))
        return RecordingsModel(services: try services(MockHTTP()), defaults: defaults)
    }

    @Test("局は番組表の並びの順（同じ局は新しい順）。並びに無い局は後ろ")
    func sortsByChannel() throws {
        let model = try model()
        model.channelOrder = [0x4002: 0, 0x4001: 1]
        let titles = [
            try fictitiousTitle("a", "架空A", day: 1, serviceID: 0x4001, channelName: "テスト局1"),
            try fictitiousTitle("b", "架空B", day: 2, serviceID: 0x4002, channelName: "テスト局2"),
            try fictitiousTitle("c", "架空C", day: 3, serviceID: 0x4001, channelName: "テスト局1"),
            try fictitiousTitle("d", "架空D", day: 4, serviceID: 0x4999, channelName: "テスト局9"),
        ]
        model.sortOrder = .channel
        #expect(model.arrange(titles).map(\.id) == ["b", "c", "a", "d"])
    }

    @Test("ジャンルは ARIB の大分類の順（同じジャンルは新しい順）。知らない名前・ジャンルの無い録画は後ろ")
    func sortsByGenre() throws {
        let model = try model()
        let titles = [
            try fictitiousTitle("a", "架空A", day: 1, genre: "アニメ／特撮"),
            try fictitiousTitle("b", "架空B", day: 2, genre: "ニュース／報道"),
            try fictitiousTitle("c", "架空C", day: 3),
            try fictitiousTitle("d", "架空D", day: 4, genre: "ドラマ"),
            try fictitiousTitle("e", "架空E", day: 5, genre: "ドラマ"),
            try fictitiousTitle("f", "架空F", day: 6, genre: "知らないジャンル"),
        ]
        model.sortOrder = .genre
        #expect(model.arrange(titles).map(\.id) == ["b", "e", "d", "a", "f", "c"])
    }

    @Test("まとめ：名前で 1 段目、1 件だけのものどうしは空白の前の頭で 2 段目。絞り込みはまとめの中に効く")
    func groups() throws {
        let model = try model()
        let titles = [
            try fictitiousTitle("1", "架空ドラマ #1「始まり」[字]", day: 1),
            try fictitiousTitle("2", "架空ドラマ #2「嵐」[字]", day: 8, isNew: true),
            try fictitiousTitle("3", "架空紀行　港町を歩く", day: 2),
            try fictitiousTitle("4", "架空紀行　山あいの宿", day: 9),
            try fictitiousTitle("5", "架空映画劇場", day: 3),
            try fictitiousTitle("6", "単発 特番", day: 4),
        ]
        let names = RecordingNameGrouping.groupNames(titles)
        #expect(names["1"] == "架空ドラマ" && names["2"] == "架空ドラマ")
        #expect(names["3"] == "架空紀行" && names["4"] == "架空紀行")
        #expect(names["6"] == "単発 特番")    // 頭が同じほかの録画が無ければ削らない

        let groups = model.groups(titles)
        #expect(groups.map(\.name) == ["架空紀行", "架空ドラマ", "単発 特番", "架空映画劇場"])
        let drama = try #require(groups.first { $0.name == "架空ドラマ" })
        #expect(drama.titles.map(\.id) == ["2", "1"])
        #expect(drama.unwatchedCount == 1)
        #expect(drama.latestStart == titles[1].displayStart)

        // 絞り込むと、当てはまる録画の無いまとめは消え、まとめ方は変わらない
        model.viewingFilter = .unwatched
        #expect(model.groups(titles).map(\.name) == ["架空ドラマ"])
        #expect(model.groups(titles).first?.titles.map(\.id) == ["2"])
    }

    @Test("視聴の状態で絞り込む：未再生・途中まで。この Mac で見た記録が nasne の値より優先し、まとめの未再生の件数も変わる")
    func filtersByViewingState() throws {
        let defaults = try #require(UserDefaults(suiteName: "RecordingsArrangementTests.\(UUID().uuidString)"))
        let viewing = ViewingRecorder(udn: "uuid:test", library: nil)
        let model = RecordingsModel(services: try services(MockHTTP()), viewing: viewing, defaults: defaults)
        let titles = [
            try fictitiousTitle("1", "架空ドラマ #1", day: 1, isNew: true),
            try fictitiousTitle("2", "架空ドラマ #2", day: 2, isNew: true),
            try fictitiousTitle("3", "架空ドラマ #3", day: 3, lastPlayback: "2026-01-04T10:00:00+09:00", resume: 600),
            try fictitiousTitle("4", "架空紀行", day: 4),
        ]
        model.viewingFilter = .unwatched
        #expect(model.arrange(titles).map(\.id) == ["2", "1"])
        model.viewingFilter = .interrupted
        #expect(model.arrange(titles).map(\.id) == ["3"])
        #expect(model.groups(titles).first?.unwatchedCount == 0)

        // この Mac で 1 を途中まで見た
        viewing.begin(titles[0])
        viewing.record(PlaybackCheckpoint(position: 300, duration: 1800, ended: false))
        #expect(model.arrange(titles).map(\.id) == ["3", "1"])
        model.viewingFilter = .all
        #expect(model.groups(titles).first { $0.name == "架空ドラマ" }?.unwatchedCount == 1)
    }

    @Test("まとめる・まとめないの選択は保存する（既定はまとめない）")
    func remembersGrouping() throws {
        let defaults = try #require(UserDefaults(suiteName: "RecordingsArrangementTests.\(UUID().uuidString)"))
        let first = RecordingsModel(services: try services(MockHTTP()), defaults: defaults)
        #expect(!first.groupsByName)
        first.groupsByName = true
        let second = RecordingsModel(services: try services(MockHTTP()), defaults: defaults)
        #expect(second.groupsByName)
    }
}

@Suite("録画の表示の決まり")
struct RecordingFormatTests {
    @Test("長さ・画質・res の画質の表記")
    func formats() {
        #expect(RecordingFormat.duration(3900) == "1 時間 5 分")
        #expect(RecordingFormat.duration(7200) == "2 時間")
        #expect(RecordingFormat.duration(1500) == "25 分")
        #expect(RecordingFormat.duration(45) == "45 秒")
        #expect(RecordingFormat.duration(0) == nil && RecordingFormat.duration(nil) == nil)
        #expect(RecordingFormat.quality(100) == "DR" && RecordingFormat.quality(230) == "3倍" && RecordingFormat.quality(101) == "101")
        #expect(RecordingFormat.resourceQuality("dr") == "DR" && RecordingFormat.resourceQuality("x3") == "3倍")
        #expect(RecordingFormat.resourceQuality("mobile") == "モバイル" && RecordingFormat.resourceQuality("hd") == "hd")
        #expect(RecordingFormat.resourceQuality(nil) == "元画質")
        // 残りコピー回数：0 は「コピーできない」と読めないように添え書きをする
        #expect(RecordingFormat.copyCount(10) == "10 回")
        #expect(RecordingFormat.copyCount(0) == "0 回（ムーブは残っていることがあります）")
        #expect(RecordingFormat.copyCount(nil) == nil)
    }
}

/// 試験ごとの一時の保存先（終わったら `LibraryStore.delete` で消す）
private func temporaryLibraryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("LibraryStoreTests-\(UUID().uuidString)")
        .appendingPathComponent("library.sqlite")
}

@Suite("録画一覧のキャッシュ")
struct LibraryStoreTests {
    /// 素材の xsrs と DIDL を結合した録画（res も入る）
    private func fixtureTitles() async throws -> [RecordedTitle] {
        try await services(catalogHTTP()).titles.titles()
    }

    @Test("保存した一覧を同じ順・同じ中身（詳細の項目と res も）で読める。件数と上限・取った時刻も")
    func roundTrip() async throws {
        let url = temporaryLibraryURL()
        defer { try? LibraryStore.delete(fileURL: url) }
        let titles = try await fixtureTitles()
        #expect(!titles.isEmpty && titles.contains { !$0.resources.isEmpty })
        let list = SavedTitleList(titles: titles, fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), counts: (count: 2, max: 3000))
        let store = try LibraryStore(fileURL: url)
        #expect(await store.titleList(udn: "uuid:a") == nil)
        await store.saveTitleList(list, udn: "uuid:a")
        #expect(await store.titleList(udn: "uuid:a") == list)
        // 開き直しても残っている
        let reopened = try LibraryStore(fileURL: url)
        #expect(await reopened.titleList(udn: "uuid:a") == list)
    }

    @Test("1 台の登録を外すと、その台の一覧だけを消し、ほかの台の一覧は残る")
    func deletesOneDevice() async throws {
        let url = temporaryLibraryURL()
        defer { try? LibraryStore.delete(fileURL: url) }
        let titles = try await fixtureTitles()
        let list = SavedTitleList(titles: titles, fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), counts: nil)
        let store = try LibraryStore(fileURL: url)
        await store.saveTitleList(list, udn: "uuid:a")
        await store.saveTitleList(list, udn: "uuid:b")
        try await store.delete(udn: "uuid:a")
        #expect(await store.titleList(udn: "uuid:a") == nil)
        #expect(await store.titleList(udn: "uuid:b") == list)
    }

    @Test("差し替えると消えた録画はキャッシュからも消える。nasne（UDN）ごとに分かれる")
    func replacesPerDevice() async throws {
        let url = temporaryLibraryURL()
        defer { try? LibraryStore.delete(fileURL: url) }
        let titles = try await fixtureTitles()
        let store = try LibraryStore(fileURL: url)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        await store.saveTitleList(SavedTitleList(titles: titles, fetchedAt: start), udn: "uuid:a")
        await store.saveTitleList(SavedTitleList(titles: Array(titles.prefix(1)), fetchedAt: start), udn: "uuid:b")
        let later = SavedTitleList(titles: Array(titles.suffix(1)), fetchedAt: start.addingTimeInterval(60))
        await store.saveTitleList(later, udn: "uuid:a")
        #expect(await store.titleList(udn: "uuid:a") == later)
        #expect(await store.titleList(udn: "uuid:a")?.counts == nil)
        #expect(await store.titleList(udn: "uuid:b")?.titles.map(\.id) == titles.prefix(1).map(\.id))
    }

    @Test("閉じた後は読み書きしない。消すと隣のファイルも残らない")
    func closeAndDelete() async throws {
        let url = temporaryLibraryURL()
        let store = try LibraryStore(fileURL: url)
        await store.saveTitleList(SavedTitleList(titles: try await fixtureTitles(), fetchedAt: Date()), udn: "uuid:a")
        await store.close()
        #expect(await store.titleList(udn: "uuid:a") == nil)
        await store.saveTitleList(SavedTitleList(titles: [], fetchedAt: Date()), udn: "uuid:a")
        try LibraryStore.delete(fileURL: url)
        let left = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(left.isEmpty)
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("表の作りの版が違えば作り直す（保存した一覧は無いものになる）")
    func rebuildsOnSchemaChange() async throws {
        let url = temporaryLibraryURL()
        defer { try? LibraryStore.delete(fileURL: url) }
        let store = try LibraryStore(fileURL: url)
        await store.saveTitleList(SavedTitleList(titles: try await fixtureTitles(), fetchedAt: Date()), udn: "uuid:a")
        await store.close()
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "PRAGMA user_version = 99", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        #expect(await (try LibraryStore(fileURL: url)).titleList(udn: "uuid:a") == nil)
    }
}

@MainActor
@Suite("録画一覧の画面とキャッシュ")
struct RecordingsCacheTests {
    @Test("保存した一覧があれば先に出し、その間は再生させない。取り直したら差し替えて保存し、再生させる")
    func showsSavedListThenRefreshes() async throws {
        let url = temporaryLibraryURL()
        defer { try? LibraryStore.delete(fileURL: url) }
        let store = try LibraryStore(fileURL: url)
        let titles = try await services(catalogHTTP()).titles.titles()
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        // 前回は 1 件だけだった（もう 1 件は後で録られた）
        await store.saveTitleList(SavedTitleList(titles: Array(titles.prefix(1)), fetchedAt: savedAt, counts: (count: 1, max: 3000)),
                                  udn: "uuid:test")

        // nasne に届かないと、保存した一覧を出したまま誤りを立てる
        let unreachable = MockHTTP()
        unreachable.failNext("/XSRS", method: "POST", count: 10)
        let offline = RecordingsModel(services: try services(unreachable), library: store)
        await offline.reload()
        #expect(offline.titles.value?.map(\.id) == titles.prefix(1).map(\.id))
        #expect(offline.isShowingSavedList && !offline.canPlay)
        #expect(offline.fetchedAt == savedAt)
        #expect(offline.counts?.max == 3000)
        #expect(offline.refreshError != nil)
        #expect(!offline.isRefreshing)

        // 届けば差し替えて保存する
        let fetchedAt = savedAt.addingTimeInterval(3600)
        let online = RecordingsModel(services: try services(catalogHTTP()), library: store, now: { fetchedAt })
        await online.reload()
        #expect(online.titles.value == titles)
        #expect(!online.isShowingSavedList && online.canPlay)
        #expect(online.fetchedAt == fetchedAt)
        #expect(online.refreshError == nil)
        #expect(await store.titleList(udn: "uuid:test") == SavedTitleList(titles: titles, fetchedAt: fetchedAt, counts: nil))
    }

    @Test("この起動で取り直した後に取り直しが失敗しても、一覧は消さずに誤りを立てる（再生はさせたまま）")
    func keepsFreshListOnLaterFailure() async throws {
        let http = catalogHTTP()
        let model = RecordingsModel(services: try services(http))
        await model.reload()
        let loaded = try #require(model.titles.value)
        http.failNext("/XSRS", method: "POST", count: 10)
        await model.reload()
        #expect(model.titles.value == loaded)
        #expect(model.refreshError != nil)
        #expect(model.canPlay)
    }
}

@Suite("一覧の下の欄の再生のボタン")
struct RecordingPlayPanelTests {
    /// 架空の録画に素材の res を付ける（`mobile` ならモバイルの版のある録画）。番組の開始は録り始めの 14 秒後
    private func title(mobile: Bool) throws -> RecordedTitle {
        let items = try DIDLItem.parseDocument(NasneFixture.text("dlna/browse_0_video_all.xml"), source: "test")
        // 素材の録画はどれもモバイルの版があるので、無い録画はモバイルの res を除いて作る
        let item = try #require(items.first { $0.resources.contains { $0.quality == TitleResource.mobileQuality } })
        var recorded = try fictitiousTitle("a", "架空A", day: 1)
        recorded.resources = mobile ? item.resources : item.resources.filter { $0.quality != TitleResource.mobileQuality }
        recorded.programStart = recorded.start?.addingTimeInterval(14)
        return recorded
    }

    @Test("元画質は画質の名前で「DR再生」、モバイルの版があれば「モバイル再生」。番組の開始から")
    func buttons() throws {
        let panel = RecordingPlayPanel.make(title: try title(mobile: true), state: .unwatched, canPlay: true, isStarting: false)
        guard case .actions(let actions, let fromStart) = panel else {
            Issue.record("ボタンになっていない: \(panel)")
            return
        }
        #expect(actions.map(\.label) == ["DR再生", "モバイル再生"])
        // 浮かべるボタンの名前は画質だけ（メニューの項目は「再生」付きのまま）
        #expect(actions.map(\.buttonLabel) == ["DR", "モバイル"])
        #expect(actions.map(\.resource.quality) == ["dr", TitleResource.mobileQuality])
        #expect(actions.allSatisfy { $0.from == 14 })
        #expect(fromStart == nil)
        #expect(panel.primary?.label == "DR再生")
        let single = RecordingPlayPanel.make(title: try title(mobile: false), state: .completed, canPlay: true, isStarting: false)
        #expect(single.primary?.label == "DR再生")
        if case .actions(let actions, _) = single { #expect(actions.count == 1) }
    }

    @Test("途中まで見た録画はどのボタンも続きから。元画質の「最初から」は番組の開始から")
    func resumes() throws {
        let panel = RecordingPlayPanel.make(title: try title(mobile: true), state: .interrupted(seconds: 600), canPlay: true, isStarting: false)
        guard case .actions(let actions, let fromStart) = panel else {
            Issue.record("ボタンになっていない: \(panel)")
            return
        }
        #expect(actions.allSatisfy { $0.from == 600 })
        #expect(fromStart?.label == RecordingPlayPanel.fromStartLabel)
        #expect(fromStart?.from == 14)
        #expect(fromStart?.resource.quality == "dr")
        #expect(fromStart?.startsOver == true)              // 再生中の録画でも頭から始め直す
        #expect(actions.allSatisfy { !$0.startsOver })      // 画質のボタンは再生中なら切り替え
        #expect(PlaybackQuality.choices(of: try title(mobile: true)).map(\.quality) == ["dr", TitleResource.mobileQuality])
        #expect(PlaybackQuality.choices(of: try title(mobile: false)).map(\.quality) == ["dr"])
    }

    @Test("押せないときは理由：選んでいない・前回の一覧で取り直し中／取り直しに失敗・始めている途中・再生できる版が無い")
    func blocked() throws {
        #expect(RecordingPlayPanel.make(title: nil, state: .unwatched, canPlay: true, isStarting: false)
                == .blocked(RecordingPlayPanel.Reason.noSelection))
        let recorded = try title(mobile: true)
        #expect(RecordingPlayPanel.make(title: recorded, state: .unwatched, canPlay: false, isStarting: false, isRefreshing: true)
                == .blocked(RecordingPlayPanel.Reason.savedList))
        #expect(RecordingPlayPanel.make(title: recorded, state: .unwatched, canPlay: false, isStarting: false, isRefreshing: false)
                == .blocked(RecordingPlayPanel.Reason.savedListFailed))
        #expect(RecordingPlayPanel.make(title: recorded, state: .unwatched, canPlay: true, isStarting: true)
                == .blocked(RecordingPlayPanel.Reason.starting))
        var bare = recorded
        bare.resources = []
        let panel = RecordingPlayPanel.make(title: bare, state: .unwatched, canPlay: true, isStarting: false)
        #expect(panel == .blocked(RecordingPlayPanel.Reason.noResource))
        #expect(panel.primary == nil)
    }
}

/// 録画の削除の試験の偽の nasne：X_DeleteTitle を受けたら、次からの一覧に消した録画を載せない（`removes` が偽なら載せたまま）
private final class DeletingNasne: @unchecked Sendable {
    private let lock = NSLock()
    private var deleted: Set<String> = []
    private let removes: Bool
    let http: MockHTTP

    init(removes: Bool = true, deleteStatus: Int = 200) {
        self.removes = removes
        http = catalogHTTP()
        let list = NasneFixture.text("soap/title_list.xml")
        http.respond("/XSRS", method: "POST") { [self] request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if body.contains("X_DeleteTitle") {
                guard deleteStatus == 200 else {
                    return MockHTTP.Reply(status: deleteStatus, body: NasneFixture.data("soap/conflict_fault.xml"))
                }
                if let start = body.range(of: "<TitleID>"), let end = body.range(of: "</TitleID>") {
                    let id = String(body[start.upperBound..<end.lowerBound])
                    if self.removes { lock.withLock { _ = deleted.insert(id) } }
                }
                return MockHTTP.Reply(status: 200, body: Data("""
                    <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
                    <u:X_DeleteTitleResponse xmlns:u="urn:schemas-xsrs-org:service:X_ScheduledRecording:2"/></s:Body></s:Envelope>
                    """.utf8))
            }
            return MockHTTP.Reply(status: 200, body: Data(Self.list(list, without: lock.withLock { deleted }).utf8))
        }
    }

    /// 素材の一覧から、消した録画の item を抜く（件数も減らす）
    static func list(_ text: String, without ids: Set<String>) -> String {
        var text = text
        for id in ids {
            guard let start = text.range(of: "&lt;item id=&quot;\(id)&quot;&gt;"),
                  let end = text.range(of: "&lt;/item&gt;", range: start.upperBound..<text.endIndex) else { continue }
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        let count = 2 - ids.count
        return text.replacingOccurrences(of: "<NumberReturned>2</NumberReturned>", with: "<NumberReturned>\(count)</NumberReturned>")
            .replacingOccurrences(of: "<TotalMatches>2</TotalMatches>", with: "<TotalMatches>\(count)</TotalMatches>")
    }

    /// 送った X_DeleteTitle の本文
    var deleteRequests: [String] {
        http.sentRequests.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }.filter { $0.contains("X_DeleteTitle") }
    }
}

@MainActor
@Suite("録画の削除")
struct RecordingDeletionTests {
    @Test("一覧の ID のまま X_DeleteTitle を 1 回送り、読み直した一覧から消えて、選択も外れる")
    func deletes() async throws {
        let nasne = DeletingNasne()
        let model = RecordingsModel(services: try services(nasne.http))
        await model.reload()
        let target = try #require(model.titles.value?.first)
        model.selectedID = target.id
        #expect(model.deletionBlocker(target) == nil)

        let error = await model.delete(target)
        #expect(error == nil)
        #expect(nasne.deleteRequests.count == 1)
        #expect(nasne.deleteRequests[0].contains("<TitleID>\(target.id)</TitleID>"))
        #expect(model.titles.value?.contains { $0.id == target.id } == false)
        #expect(model.titles.value?.count == 1)
        #expect(model.selectedID == nil)
        #expect(model.deletingID == nil)
    }

    @Test("受け付けられても一覧に残っていれば、残っていると知らせる")
    func stillListed() async throws {
        let nasne = DeletingNasne(removes: false)
        let model = RecordingsModel(services: try services(nasne.http))
        await model.reload()
        let target = try #require(model.titles.value?.first)
        #expect(await model.delete(target) == RecordingDeletion.stillListed)
    }

    @Test("断られたら誤りを返し（再試行しない）、一覧は読み直す")
    func refused() async throws {
        let nasne = DeletingNasne(deleteStatus: 500)
        let model = RecordingsModel(services: try services(nasne.http))
        await model.reload()
        let target = try #require(model.titles.value?.first)
        let listRequestsBefore = nasne.http.sentRequests.count
        let error = await model.delete(target)
        #expect(error?.title == ErrorText.present(NasneError.soapFault(errorCode: "402", errorDescription: nil, source: "test")).title)
        #expect(nasne.deleteRequests.count == 1)
        #expect(nasne.http.sentRequests.count > listRequestsBefore + 1)
        #expect(model.titles.value?.contains { $0.id == target.id } == true)
    }

    @Test("保護・録画中の録画と、保存した一覧を出している間は送らない")
    func blockers() async throws {
        let nasne = DeletingNasne()
        let model = RecordingsModel(services: try services(nasne.http))
        await model.reload()
        var protected = try #require(model.titles.value?.first)
        protected.isProtected = true
        var recording = try #require(model.titles.value?.first)
        recording.isRecording = true
        #expect(model.deletionBlocker(protected) == .protected)
        #expect(model.deletionBlocker(recording) == .recording)
        #expect(await model.delete(protected) == nil)
        #expect(await model.delete(recording) == nil)
        #expect(nasne.deleteRequests.isEmpty)
        // 保護を録画中より先に言う。保存した一覧の間は取り直してから
        protected.isRecording = true
        #expect(RecordingDeletion.blocker(protected, isShowingSavedList: true) == .protected)
        #expect(RecordingDeletion.blocker(try #require(model.titles.value?.last), isShowingSavedList: true) == .savedList)
        // 削除の途中・取り直しの途中は、ほかの録画も消さない（1 件ずつ・消えたかを読み直して確かめるため）
        let other = try #require(model.titles.value?.last)
        #expect(RecordingDeletion.blocker(other, isShowingSavedList: false, isDeleting: true) == .deleting)
        #expect(RecordingDeletion.blocker(other, isShowingSavedList: false, isRefreshing: true) == .refreshing)
        #expect(RecordingDeletion.blocker(other, isShowingSavedList: false) == nil)
        // nasne に届かない間は、削除・保護・再生をさせない（保護・録画中は先に言う）
        #expect(RecordingDeletion.blocker(other, isShowingSavedList: false, isOffline: true) == .offline)
        #expect(RecordingDeletion.blocker(protected, isShowingSavedList: false, isOffline: true) == .protected)
        #expect(RecordingProtection.blocker(other, isShowingSavedList: true, isOffline: true) == .offline)
        #expect(RecordingPlayPanel.make(title: other, state: .unwatched, canPlay: false, isStarting: false, isOffline: true)
                == .blocked(RecordingPlayPanel.Reason.offline))
    }
}

/// 録画の保護の試験の偽の nasne：X_UpdateTitle を受けたら、送られた item の保護の印を次からの一覧に載せる（`applies` が偽なら載せない）
private final class ProtectingNasne: @unchecked Sendable {
    private let lock = NSLock()
    private var flags: [String: String] = [:]
    private let applies: Bool
    let http: MockHTTP

    init(applies: Bool = true, updateStatus: Int = 200) {
        self.applies = applies
        http = catalogHTTP()
        let list = NasneFixture.text("soap/title_list.xml")
        http.respond("/XSRS", method: "POST") { [self] request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if body.contains("X_UpdateTitle") {
                guard updateStatus == 200 else {
                    return MockHTTP.Reply(status: updateStatus, body: NasneFixture.data("soap/conflict_fault.xml"))
                }
                if self.applies, let id = Self.capture(body, after: "&lt;item id=\"", before: "\""),
                   let flag = Self.capture(body, after: "&lt;titleProtectFlag&gt;", before: "&lt;") {
                    lock.withLock { flags[id] = flag }
                }
                return MockHTTP.Reply(status: 200, body: Data("""
                    <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
                    <u:X_UpdateTitleResponse xmlns:u="urn:schemas-xsrs-org:service:X_ScheduledRecording:2"><Result></Result>\
                    </u:X_UpdateTitleResponse></s:Body></s:Envelope>
                    """.utf8))
            }
            return MockHTTP.Reply(status: 200, body: Data(Self.list(list, flags: lock.withLock { flags }).utf8))
        }
    }

    static func capture(_ text: String, after open: String, before close: String) -> String? {
        guard let start = text.range(of: open), let end = text.range(of: close, range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// 素材の一覧の、その録画の item の保護の印を書き換える
    static func list(_ text: String, flags: [String: String]) -> String {
        var text = text
        for (id, flag) in flags {
            guard let start = text.range(of: "&lt;item id=&quot;\(id)&quot;&gt;"),
                  let end = text.range(of: "&lt;/item&gt;", range: start.upperBound..<text.endIndex),
                  let old = text.range(of: "&lt;titleProtectFlag&gt;0&lt;/titleProtectFlag&gt;", range: start.upperBound..<end.lowerBound)
                    ?? text.range(of: "&lt;titleProtectFlag&gt;1&lt;/titleProtectFlag&gt;", range: start.upperBound..<end.lowerBound)
            else { continue }
            text.replaceSubrange(old, with: "&lt;titleProtectFlag&gt;\(flag)&lt;/titleProtectFlag&gt;")
        }
        return text
    }

    /// 送った X_UpdateTitle の本文
    var updateRequests: [String] {
        http.sentRequests.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }.filter { $0.contains("X_UpdateTitle") }
    }
}

@MainActor
@Suite("録画の保護の切り替え")
struct RecordingProtectionTests {
    @Test("一覧の item を受け取ったまま保護の印だけ変えて 1 回送り、読み直した一覧で保護が付く。外すのも同じ")
    func protectsAndUnprotects() async throws {
        let nasne = ProtectingNasne()
        let model = RecordingsModel(services: try services(nasne.http))
        await model.reload()
        let target = try #require(model.titles.value?.first)
        #expect(!target.isProtected)
        #expect(model.protectionBlocker(target) == nil)

        #expect(await model.setProtection(target, protect: true) == nil)
        #expect(nasne.updateRequests.count == 1)
        let sent = nasne.updateRequests[0]
        #expect(sent.contains("&lt;item id=\"\(target.id)\"&gt;"))
        #expect(sent.contains("&lt;titleProtectFlag&gt;1&lt;/titleProtectFlag&gt;"))
        // 保護の印のほかは、一覧で受け取ったまま（属性も）
        #expect(sent.contains("&lt;portableRecordFile target=\"MOB\" transferPath=\"IP\"&gt;"))
        #expect(sent.contains("&lt;recordSize&gt;521&lt;/recordSize&gt;"))
        let protected = try #require(model.titles.value?.first { $0.id == target.id })
        #expect(protected.isProtected)
        #expect(model.protectingID == nil)
        // 保護した録画は消せない
        #expect(model.deletionBlocker(protected) == .protected)

        #expect(await model.setProtection(protected, protect: false) == nil)
        try #require(nasne.updateRequests.count == 2)
        #expect(nasne.updateRequests[1].contains("&lt;titleProtectFlag&gt;0&lt;/titleProtectFlag&gt;"))
        #expect(model.titles.value?.first { $0.id == target.id }?.isProtected == false)
    }

    @Test("受け付けられても一覧の保護の印が変わらなければ、変わっていないと知らせる")
    func unchanged() async throws {
        let nasne = ProtectingNasne(applies: false)
        let model = RecordingsModel(services: try services(nasne.http))
        await model.reload()
        let target = try #require(model.titles.value?.first)
        #expect(await model.setProtection(target, protect: true) == RecordingProtection.unchanged)
        #expect(model.titles.value?.first { $0.id == target.id }?.isProtected == false)
    }

    @Test("断られたら誤りを返し（再試行しない）、一覧の保護の印は変えない")
    func refused() async throws {
        let nasne = ProtectingNasne(updateStatus: 500)
        let model = RecordingsModel(services: try services(nasne.http))
        await model.reload()
        let target = try #require(model.titles.value?.first)
        let error = await model.setProtection(target, protect: true)
        #expect(error != nil)
        #expect(nasne.updateRequests.count == 1)
        #expect(model.titles.value?.first { $0.id == target.id }?.isProtected == false)
    }

    @Test("録画中の録画・保存した一覧の間・今と同じ状態には送らない。削除や切り替えの途中も待つ")
    func blockers() async throws {
        let nasne = ProtectingNasne()
        let model = RecordingsModel(services: try services(nasne.http))
        await model.reload()
        var recording = try #require(model.titles.value?.first)
        recording.isRecording = true
        #expect(model.protectionBlocker(recording) == .recording)
        #expect(await model.setProtection(recording, protect: true) == nil)
        let target = try #require(model.titles.value?.first)
        #expect(await model.setProtection(target, protect: false) == nil)
        #expect(nasne.updateRequests.isEmpty)
        #expect(RecordingProtection.blocker(target, isShowingSavedList: true) == .savedList)
        #expect(RecordingProtection.blocker(target, isShowingSavedList: false, isDeleting: true) == .deleting)
        #expect(RecordingProtection.blocker(target, isShowingSavedList: false, isProtecting: true) == .protecting)
        #expect(RecordingProtection.blocker(target, isShowingSavedList: false, isRefreshing: true) == .refreshing)
        // 保護した録画も、保護を外すことはできる（削除と違って保護は理由にならない）
        var protected = target
        protected.isProtected = true
        #expect(RecordingProtection.blocker(protected, isShowingSavedList: false) == nil)
        #expect(RecordingDeletion.blocker(target, isShowingSavedList: false, isProtecting: true) == .protecting)
    }
}

@MainActor
@Suite("録画一覧の 2 段の取り直し")
struct RecordingListMergeTests {
    /// 架空の録画（xsrs の値だけ。`resources` を足すと番組の情報を持つ形になる）
    private func title(_ id: String, start: String = "2026-01-05T21:00:00+09:00", protected: Bool = false,
                       serviceID: Int = 0x4010) throws -> RecordedTitle {
        try RecordedTitle(item: XSRSItem(id: id, fields: ["title": "架空番組\(id)", "scheduledStartDateTime": start,
                                                          "scheduledChannelID": String(format: "0x%04x", serviceID),
                                                          "titleProtectFlag": protected ? "1" : "0"],
                                         attributes: ["scheduledChannelID": ["broadcastingType": "2", "channelType": "2"]]),
                          source: "test")
    }

    private func withMetadata(_ title: RecordedTitle, description: String) throws -> RecordedTitle {
        var copy = title
        copy.description = description
        copy.channelName = "保存した局名"
        copy.resources = try #require(try DIDLItem.parseDocument(NasneFixture.text("dlna/browse_0_video_all.xml"), source: "test").first).resources
        return copy
    }

    private let channels = [Channel(broadcastingType: 2, networkID: 0x7E01, transportStreamID: 0x7E01, serviceID: 0x4020,
                                    serviceType: Channel.televisionServiceType, channelNumber: 1, serviceName: "テスト局",
                                    remoteControlKeyID: 1)]

    @Test("1 段目：消えた録画を外し、前からある録画は番組の情報を引き継いで nasne の値に直し、新しい録画は局名を引いて補う印を付ける")
    func merge() throws {
        let kept = try withMetadata(try title("1"), description: "説明1")
        let gone = try withMetadata(try title("2"), description: "説明2")
        let reused = try withMetadata(try title("3"), description: "説明3")
        let listed = [try title("1", protected: true), try title("3", start: "2026-02-01T21:00:00+09:00"),
                      try title("4", serviceID: 0x4020)]
        let merged = RecordingListMerge.merge(shown: [kept, gone, reused], listed: listed, channels: channels)
        #expect(merged.titles.map(\.id) == ["1", "3", "4"])
        #expect(merged.titles[0].isProtected)
        #expect(merged.titles[0].description == "説明1")
        #expect(merged.titles[0].resources == kept.resources)
        // 同じ ID でも録り始めが違えば別の録画（引き継がない）
        #expect(merged.titles[1].description == nil)
        #expect(merged.titles[2].channelName == "テスト局")
        #expect(merged.needsMetadata == ["3", "4"])
    }

    @Test("2 段目：番組の情報から入る項目だけを足し込み、保護などは出している一覧のまま。読み込みの間に増えた録画は後ろに足す")
    func completing() throws {
        let shown = [try title("1", protected: true), try title("2")]
        let full = [try withMetadata(try title("1", protected: false), description: "説明1"), try withMetadata(try title("5"), description: "説明5")]
        let list = RecordingListMerge.completing(shown: shown, withMetadataFrom: full)
        #expect(list.map(\.id) == ["1", "2", "5"])
        #expect(list[0].isProtected)
        #expect(list[0].description == "説明1")
        #expect(list[1].description == nil)
    }

    @Test("1 段目だけで返す読み直し：新しい録画は 1 件ずつ番組の情報（BrowseMetadata）で補い、再生できる")
    func firstStageFillsNewTitles() async throws {
        let http = catalogHTTP()
        let model = RecordingsModel(services: try services(http))
        await model.reload(waitsForMetadata: false)
        let list = try #require(model.titles.value)
        #expect(list.count == 2)
        #expect(list.allSatisfy { !$0.resources.isEmpty })
        #expect(model.canPlay)
        let metadataRequests = http.sentRequests.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
            .filter { $0.contains("<BrowseFlag>BrowseMetadata</BrowseFlag>") }
        #expect(metadataRequests.count == 2)
        #expect(metadataRequests.contains { $0.contains("<ObjectID>0/video/all/pvr?id=\(list[0].id)</ObjectID>") })
    }
}
