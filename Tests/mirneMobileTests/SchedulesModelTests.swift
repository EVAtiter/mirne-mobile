import Foundation
import Synchronization
import Testing

// 予約の一覧と詳細。50 件ずつの頁送り・eventId・開始の早い順・局名・読めないとき・時期。
// 手動の予約の作成。ひな形・競合の確認・作成・再試行しないこと・誤りの文言。
// 画質の変更・削除。疎な更新の形・読み直し・削除の後の読み直し

/// xsrs の予約の item（素材の schedule_list_one.xml と同じ形。番組名は入れない）
private func scheduleItem(id: Int, start: String, duration: Int = 300, serviceID: Int = 0x41f0, eventID: Int = 0,
                          quality: Int = QualityMode.dr, destination: String = "HDD", condition: String = "1") -> String {
    """
    <item id="\(id)"><scheduledStartDateTime>\(start)</scheduledStartDateTime>\
    <scheduledDuration>\(duration)</scheduledDuration><scheduledConditionID>\(condition)</scheduledConditionID>\
    <scheduledChannelID broadcastingType="2" channelType="2">\(String(format: "0x%04x", serviceID))</scheduledChannelID>\
    <desiredMatchingID type="SI_PROGRAMID">0x7e00,0x7e00,\(String(format: "0x%04x", serviceID)),\(String(format: "0x%04x", eventID))</desiredMatchingID>\
    <desiredQualityMode>\(quality)</desiredQualityMode><reservationCreatorID>2000</reservationCreatorID>\
    <priorityFlag>0</priorityFlag><recordDestinationID>\(destination)</recordDestinationID></item>
    """
}

private func xsrs(_ items: [String]) -> String {
    #"<?xml version="1.0"?><xsrs xmlns="urn:schemas-xsrs-org:metadata-1-0/x_srs/">"# + items.joined() + "</xsrs>"
}

private func schedules(_ items: [String]) throws -> [RecordSchedule] {
    try XSRSItem.parseDocument(xsrs(items), source: "test").map { try RecordSchedule(item: $0, source: "test") }
}

/// 予約の一覧の SOAP の応答
private func listEnvelope(_ items: [String], total: Int) -> Data {
    Data("""
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <u:X_GetRecordScheduleListResponse xmlns:u="urn:schemas-xsrs-org:service:X_ScheduledRecording:2">\
        <Result>\(XMLTree.escapeText(xsrs(items)))</Result><NumberReturned>\(items.count)</NumberReturned>\
        <TotalMatches>\(total)</TotalMatches><UpdateID>0</UpdateID></u:X_GetRecordScheduleListResponse></s:Body></s:Envelope>
        """.utf8)
}

/// 決まった予約を返す（読めないこともある）。競合の確認と作成は、呼ばれた回数を数え、決めた結果を返す
private final class FixedSchedules: ScheduleService, Sendable {
    private struct State {
        var list: [RecordSchedule]
        var fails = false
        var conflicts: [RecordSchedule] = []
        var conflictError: NasneError?
        var createError: NasneError?
        var conflictCalls = 0
        /// 重なる予約の確かめで送った予約
        var checked: [NewRecordSchedule] = []
        var created: [NewRecordSchedule] = []
        var updates: [ScheduleUpdate] = []
        var deleted: [String] = []
        var updateError: NasneError?
        var deleteError: NasneError?
        /// 更新を一覧の値に映すか（nasne は受け付けても変えないことがある）
        var reflectsUpdates = true
    }
    private let state: Mutex<State>
    init(_ list: [RecordSchedule] = []) { state = Mutex(State(list: list)) }
    func set(_ list: [RecordSchedule]) { state.withLock { $0.list = list } }
    func setFails(_ fails: Bool) { state.withLock { $0.fails = fails } }
    func setConflicts(_ conflicts: [RecordSchedule]) { state.withLock { $0.conflicts = conflicts } }
    func setConflictError(_ error: NasneError?) { state.withLock { $0.conflictError = error } }
    func setCreateError(_ error: NasneError?) { state.withLock { $0.createError = error } }
    var conflictCalls: Int { state.withLock { $0.conflictCalls } }
    var checked: [NewRecordSchedule] { state.withLock { $0.checked } }
    var created: [NewRecordSchedule] { state.withLock { $0.created } }
    var updates: [ScheduleUpdate] { state.withLock { $0.updates } }
    var deleted: [String] { state.withLock { $0.deleted } }
    func setUpdateError(_ error: NasneError?) { state.withLock { $0.updateError = error } }
    func setDeleteError(_ error: NasneError?) { state.withLock { $0.deleteError = error } }
    func setReflectsUpdates(_ reflects: Bool) { state.withLock { $0.reflectsUpdates = reflects } }

    func schedules() async throws -> [RecordSchedule] {
        let (list, fails) = state.withLock { ($0.list, $0.fails) }
        if fails { throw NasneError.unreachable("soap:X_GetRecordScheduleList", cause: URLError(.timedOut)) }
        return list
    }
    func conflicts(for schedule: NewRecordSchedule) async throws -> [RecordSchedule] {
        let (conflicts, error) = state.withLock { state -> ([RecordSchedule], NasneError?) in
            state.conflictCalls += 1
            state.checked.append(schedule)
            return (state.conflicts, state.conflictError)
        }
        if let error { throw error }
        return conflicts
    }
    func create(_ schedule: NewRecordSchedule) async throws -> String {
        let error = state.withLock { state -> NasneError? in
            state.created.append(schedule)
            return state.createError
        }
        if let error { throw error }
        return "10000000000000000003"
    }
    func update(_ update: ScheduleUpdate) async throws {
        let error = state.withLock { state -> NasneError? in
            state.updates.append(update)
            if state.updateError == nil, state.reflectsUpdates, let index = state.list.firstIndex(where: { $0.id == update.id }) {
                if let mode = update.desiredQualityMode { state.list[index].desiredQualityMode = mode }
                if let repeatMode = update.repeatMode { state.list[index].repeatMode = repeatMode }
            }
            return state.updateError
        }
        if let error { throw error }
    }
    func delete(id: String) async throws {
        let error = state.withLock { state -> NasneError? in
            state.deleted.append(id)
            if state.deleteError == nil { state.list.removeAll { $0.id == id } }
            return state.deleteError
        }
        if let error { throw error }
    }
}

/// チャンネル一覧だけを返す本体情報
/// 集約ステータスの予約の一覧の世代（試験の途中で変える。nil は読めない）
private final class FakeLiveGenerations: Sendable {
    private let state = Mutex<(generation: Int?, reads: Int)>((nil, 0))
    func set(_ generation: Int?) { state.withLock { $0.generation = generation } }
    var reads: Int { state.withLock { $0.reads } }
    func read() throws -> Int {
        let generation = state.withLock { state -> Int? in
            state.reads += 1
            return state.generation
        }
        guard let generation else { throw NasneError.unreachable("webapi:/status/liveStreamStatusListGet", cause: URLError(.timedOut)) }
        return generation
    }
}

private struct NamedChannels: DeviceInfoService {
    var fails = false
    /// 世代を返す（nil なら集約ステータスは読めない）
    var live: FakeLiveGenerations?
    /// HDD の一覧（nil なら読めない）
    var hdds: [HDDEntry]? = []
    func channels(broadcastingType: Int) async throws -> [Channel] {
        if fails { throw NasneError.unreachable("webapi:/status/channelListGet", cause: URLError(.timedOut)) }
        return [Channel(broadcastingType: BroadcastingType.terrestrial, networkID: 0x7E00, transportStreamID: 0x7E00,
                        serviceID: 0x41f0, serviceType: Channel.televisionServiceType, channelNumber: 1, serviceName: "テスト局1")]
    }
    func deviceInfo() async throws -> DeviceInfo { throw NasneError.validation("test", "使わない") }
    func hddList() async throws -> [HDDEntry] {
        guard let hdds else { throw NasneError.unreachable("webapi:/status/HDDListGet", cause: URLError(.timedOut)) }
        return hdds
    }
    func hddInfo(id: Int) async throws -> HDDInfo { throw NasneError.validation("test", "使わない") }
    func liveStatus() async throws -> LiveStatus {
        guard let live else { throw NasneError.validation("test", "使わない") }
        return LiveStatus(json: JSONObject(["tvTimerList": ["generation": try live.read()]]))
    }
    func recNgList() async throws -> [RecNgItem] { [] }
    func titleCounts() async throws -> (count: Int, max: Int) { (0, 0) }
}

private let sample = [
    scheduleItem(id: 3, start: "2026-11-21T21:00:00+09:00", duration: 3240, eventID: 0x1234, quality: QualityMode.threeTimes),
    scheduleItem(id: 1, start: "2026-11-20T04:00:00+09:00", serviceID: 0x4210),
    scheduleItem(id: 2, start: "2026-11-20T04:00:00+09:00"),
]

@MainActor
@Suite("予約の一覧")
struct SchedulesModelTests {
    @Test("一覧は 50 件ずつ頁を送り、TotalMatches まで集める")
    func pagesThroughList() async throws {
        let http = MockHTTP()
        let all = (0..<60).map { scheduleItem(id: 100 + $0, start: "2026-11-20T04:00:00+09:00") }
        let starts = Mutex<[String]>([])
        http.respond("/XSRS", method: "POST") { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let index = body.range(of: "<StartingIndex>0</StartingIndex>") != nil ? 0 : 50
            starts.withLock { $0.append(String(index)) }
            return MockHTTP.Reply(status: 200, body: listEnvelope(Array(all[index..<min(index + 50, all.count)]), total: all.count))
        }
        let catalog = RecordingCatalogService(soap: SOAPTransport(client: http), device: NasneDevice.direct(host: NasneFixture.host))
        let list = try await catalog.schedules()
        #expect(list.count == 60)
        #expect(starts.withLock { $0 } == ["0", "50"])
    }

    @Test("eventId は matchingID の最後の値。0 は時刻を指定した予約")
    func eventID() throws {
        let list = try schedules(sample)
        #expect(list.first { $0.id == "3" }?.eventID == 0x1234)
        #expect(list.first { $0.id == "3" }?.isLinkedToProgram == true)
        #expect(list.first { $0.id == "1" }?.eventID == 0)
        #expect(list.first { $0.id == "1" }?.isLinkedToProgram == false)
    }

    @Test("開始の早い順（同じ開始は局の serviceID の順）に並べ、局名を引く。引けない局は serviceID のまま")
    func sortsAndNames() async throws {
        let model = SchedulesModel(schedules: FixedSchedules(try schedules(sample)), channels: ChannelCatalog(deviceInfo: NamedChannels()), liveStatus: LiveStatusMonitor(deviceInfo: NamedChannels(), initialLink: .online))
        await model.reload()
        #expect(model.sortedSchedules.map(\.id) == ["2", "1", "3"])
        #expect(model.channelName(model.sortedSchedules[0].channel) == "テスト局1")
        #expect(model.channelName(model.sortedSchedules[1].channel) == "サービス 0x4210")
        #expect(QualityMode.label(model.sortedSchedules[2].desiredQualityMode) == "3倍")
    }

    @Test("局名が読めなくても予約の一覧は出す")
    func channelFailureKeepsList() async throws {
        let model = SchedulesModel(schedules: FixedSchedules(try schedules(sample)), channels: ChannelCatalog(deviceInfo: NamedChannels(fails: true)), liveStatus: LiveStatusMonitor(deviceInfo: NamedChannels(fails: true), initialLink: .online))
        await model.reload()
        #expect(model.sortedSchedules.count == 3)
        #expect(model.channelName(model.sortedSchedules[0].channel) == "サービス 0x41f0")
    }

    @Test("予約が読めなければ失敗を出す。選んだ予約は、読み直して無くなれば外す")
    func failureAndSelection() async throws {
        let service = FixedSchedules(try schedules(sample))
        let model = SchedulesModel(schedules: service, channels: ChannelCatalog(deviceInfo: NamedChannels()), liveStatus: LiveStatusMonitor(deviceInfo: NamedChannels(), initialLink: .online))
        await model.reload()
        model.selectedID = "3"
        #expect(model.selectedSchedule?.id == "3")
        service.set(try schedules(Array(sample.prefix(1))))
        await model.reload()
        #expect(model.selectedID == "3")   // まだある
        service.set(try schedules(Array(sample.suffix(2))))
        await model.reload()
        #expect(model.selectedID == nil)
        service.setFails(true)
        await model.reload()
        guard case .failed(let error) = model.schedules else {
            Issue.record("失敗になっていない: \(model.schedules)")
            return
        }
        #expect(error.canRetry)
    }

    @Test("見回り：世代が前と同じなら一覧を読まず、違えば読み込み中を挟まず差し替える。まだ読んでいなければ何もしない。選んだ予約は無くなれば外す")
    func refreshWhenGenerationChanges() async throws {
        let service = FixedSchedules(try schedules(sample))
        let live = FakeLiveGenerations()
        live.set(85)
        let device = NamedChannels(live: live)
        let monitor = LiveStatusMonitor(deviceInfo: device, initialLink: .online)
        let model = SchedulesModel(schedules: service, channels: ChannelCatalog(deviceInfo: device), liveStatus: monitor)
        await monitor.poll()
        await model.refreshIfChanged()
        #expect(model.schedules == .idle)   // 最初の読み込みは reload が受け持つ
        await model.reload()
        model.selectedID = "3"
        service.set(try schedules(Array(sample.suffix(2))))
        await model.refreshIfChanged()
        #expect(model.schedules.value?.count == 3)   // 世代が同じなので読まない
        live.set(86)
        await monitor.poll()
        await model.refreshIfChanged()
        #expect(model.schedules.value?.map(\.id) == ["1", "2"])
        #expect(model.selectedID == nil)
        // 一覧が読めなければ今の一覧を残し、世代も覚えない（次の見回りでもう一度読む）
        live.set(87)
        await monitor.poll()
        service.setFails(true)
        await model.refreshIfChanged()
        #expect(model.schedules.value?.map(\.id) == ["1", "2"])
        service.setFails(false)
        service.set(try schedules(Array(sample.suffix(1))))
        await model.refreshIfChanged()
        #expect(model.schedules.value?.map(\.id) == ["2"])
    }

    @Test("集約ステータスの見回り：読めたら世代を持ってつながる。2 回続けて読めなければオフラインにして世代を nil にする（1 回の取りこぼしでは消さない）。読めたら戻る")
    func monitorDropsGenerationOnFailure() async {
        let live = FakeLiveGenerations()
        let monitor = LiveStatusMonitor(deviceInfo: NamedChannels(live: live))
        #expect(monitor.link == .checking)
        #expect(!monitor.isOnline)
        live.set(85)
        await monitor.poll()
        #expect(monitor.generations?.schedules == 85)
        #expect(monitor.link == .online)
        live.set(nil)
        await monitor.poll()
        #expect(monitor.generations?.schedules == 85)   // 1 回目はまだ消さない
        #expect(monitor.link == .online)
        await monitor.poll()
        #expect(monitor.generations == nil)
        #expect(monitor.link == .offline)
        live.set(86)
        await monitor.poll()
        #expect(monitor.generations?.schedules == 86)
        #expect(monitor.link == .online)
    }

    @Test("起動したときに 2 回続けて読めなければ、確かめている状態からオフラインになる")
    func monitorStartsOffline() async {
        let monitor = LiveStatusMonitor(deviceInfo: NamedChannels(live: FakeLiveGenerations()))
        await monitor.poll()
        #expect(monitor.link == .checking)
        await monitor.poll()
        #expect(monitor.link == .offline)
    }

    @Test("読み直しの間：つながっている間は 2 秒、読めなかった直後はすぐ、オフラインは 1 分まで 5 秒・その後 30 秒、10 分で止める")
    func linkPolicy() {
        #expect(NasneLinkPolicy.nextDelay(link: .online, failures: 0, offlineFor: nil) == LiveStatusMonitorTiming.interval)
        #expect(NasneLinkPolicy.nextDelay(link: .online, failures: 1, offlineFor: nil) == .zero)
        #expect(NasneLinkPolicy.nextDelay(link: .checking, failures: 0, offlineFor: nil) == LiveStatusMonitorTiming.interval)
        #expect(NasneLinkPolicy.nextDelay(link: .checking, failures: 1, offlineFor: nil) == .zero)
        #expect(NasneLinkPolicy.nextDelay(link: .offline, failures: 2, offlineFor: .seconds(0)) == .seconds(5))
        #expect(NasneLinkPolicy.nextDelay(link: .offline, failures: 5, offlineFor: .seconds(59)) == .seconds(5))
        #expect(NasneLinkPolicy.nextDelay(link: .offline, failures: 9, offlineFor: .seconds(60)) == .seconds(30))
        #expect(NasneLinkPolicy.nextDelay(link: .offline, failures: 20, offlineFor: .seconds(599)) == .seconds(30))
        #expect(NasneLinkPolicy.nextDelay(link: .offline, failures: 21, offlineFor: .seconds(600)) == nil)
    }

    @Test("つながっていない間は予約の一覧を読まず、前に読んだ一覧を残す")
    func offlineKeepsList() async throws {
        let service = FixedSchedules(try schedules(sample))
        let live = FakeLiveGenerations()
        live.set(85)
        let device = NamedChannels(live: live)
        let monitor = LiveStatusMonitor(deviceInfo: device)
        let model = SchedulesModel(schedules: service, channels: ChannelCatalog(deviceInfo: device), liveStatus: monitor)
        await model.reload()
        #expect(model.schedules == .idle)   // 確かめる前は読まない
        await monitor.poll()
        await model.reload()
        #expect(model.schedules.value?.count == 3)
        live.set(nil)
        await monitor.poll()
        await monitor.poll()
        #expect(monitor.link == .offline)
        service.setFails(true)
        await model.reload()
        await model.refreshIfChanged()
        #expect(model.schedules.value?.count == 3)   // 失敗にせず、前の一覧のまま
    }

    @Test("読み直すかの判断：世代が読めれば前と違うときだけ。読めなければ前に読んでから決まった間が経ったら。まだ読んでいなければ読む")
    func refreshTracker() {
        var tracker = ListRefreshTracker(fallbackInterval: 15)
        let start = Date(timeIntervalSince1970: 0)
        #expect(tracker.needsRefresh(observed: nil, now: start))
        #expect(tracker.needsRefresh(observed: 5, now: start))
        tracker.noteRead(generation: 5, at: start)
        #expect(!tracker.needsRefresh(observed: 5, now: start.addingTimeInterval(100)))
        #expect(tracker.needsRefresh(observed: 6, now: start))
        #expect(!tracker.needsRefresh(observed: nil, now: start.addingTimeInterval(14)))
        #expect(tracker.needsRefresh(observed: nil, now: start.addingTimeInterval(15)))
    }

    @Test("見回り：世代が読めないときは、一覧を読んでから決まった間がたつまで読まない")
    func fallbackWithoutGeneration() async throws {
        let service = FixedSchedules(try schedules(sample))
        let live = FakeLiveGenerations()   // 読めない
        let device = NamedChannels(live: live)
        let clock = Mutex(Date(timeIntervalSince1970: 0))
        let model = SchedulesModel(schedules: service, channels: ChannelCatalog(deviceInfo: device), liveStatus: LiveStatusMonitor(deviceInfo: device, initialLink: .online),
                                   now: { clock.withLock { $0 } })
        await model.reload()
        service.set(try schedules(Array(sample.suffix(2))))
        clock.withLock { $0 = $0.addingTimeInterval(SchedulesRefresh.fallbackInterval - 1) }
        await model.refreshIfChanged()
        #expect(model.schedules.value?.count == 3)
        clock.withLock { $0 = $0.addingTimeInterval(1) }
        await model.refreshIfChanged()
        #expect(model.schedules.value?.count == 2)
    }

    @Test("時期：始まる前・録画中・終わった")
    func timing() throws {
        let schedule = try #require(try schedules([scheduleItem(id: 1, start: "2026-11-20T04:00:00+09:00", duration: 600)]).first)
        #expect(ScheduleTiming(schedule, now: schedule.start.addingTimeInterval(-1)) == .upcoming)
        #expect(ScheduleTiming(schedule, now: schedule.start) == .recording)
        #expect(ScheduleTiming(schedule, now: schedule.end) == .ended)
    }

}

/// 作成の試験の局（2 つの TS に同じ serviceID の局を置き、取り違えないことも確かめる）
private let creationChannels = [
    Channel(broadcastingType: BroadcastingType.terrestrial, networkID: 0x7E01, transportStreamID: 0x7E01, serviceID: 0x4010,
            serviceType: Channel.televisionServiceType, channelNumber: 1, serviceName: "テスト局1", remoteControlKeyID: 1),
    Channel(broadcastingType: BroadcastingType.terrestrial, networkID: 0x7E02, transportStreamID: 0x7E02, serviceID: 0x4010,
            serviceType: Channel.televisionServiceType, channelNumber: 2, serviceName: "テスト局2", remoteControlKeyID: 2),
]

/// 2026-11-20 20:41:30（日本時間）
private let creationNow = Date(timeIntervalSince1970: 1_795_174_890)

@MainActor
@Suite("手動の予約の作成")
struct ScheduleCreationTests {
    @Test("ひな形：日時は +09:00 のコロン形、録画先は画質によらず予約の値（既定は内蔵 HDD・外付けは USBHDD）、matchingID は ,,nid,eventId、番組名は送らない")
    func template() throws {
        let start = try #require(NasneDateTime.parse("2026-11-20T21:00:00+09:00"))
        var schedule = NewRecordSchedule(start: start, durationSeconds: 3600,
                                         channel: ScheduleChannel(broadcastingType: 2, channelType: 2, serviceID: 0x4010),
                                         networkID: 0x7E01)
        let document = NasneProfiles.standard.xsrs.document(for: schedule)
        #expect(document.contains("<scheduledStartDateTime>2026-11-20T21:00:00+09:00</scheduledStartDateTime>"))
        #expect(document.contains("<scheduledDuration>3600</scheduledDuration>"))
        #expect(document.contains(#"<scheduledChannelID broadcastingType="2" channelType="2">0x4010</scheduledChannelID>"#))
        #expect(document.contains(#"<desiredMatchingID type="SI_PROGRAMID">,,0x7e01,0x0000</desiredMatchingID>"#))
        #expect(document.contains("<desiredQualityMode>100</desiredQualityMode>"))
        #expect(document.contains("<recordDestinationID>HDD</recordDestinationID>"))
        #expect(document.contains("<reservationCreatorID>2000</reservationCreatorID>"))
        #expect(document.contains("<priorityFlag>0</priorityFlag>"))
        #expect(document.contains("<scheduledConditionID></scheduledConditionID>"))
        #expect(!document.contains("<title>"))
        let items = try XSRSItem.parseDocument(document, source: "test")
        #expect(items.count == 1 && items[0].id.isEmpty)
        schedule.desiredQualityMode = QualityMode.threeTimes
        let threeTimes = NasneProfiles.standard.xsrs.document(for: schedule)
        #expect(threeTimes.contains("<desiredQualityMode>230</desiredQualityMode>"))
        #expect(threeTimes.contains("<recordDestinationID>HDD</recordDestinationID>"))
        #expect(!threeTimes.contains("USBHDD"))
        schedule.recordDestination = .externalHDD
        schedule.desiredQualityMode = QualityMode.dr
        let external = NasneProfiles.standard.xsrs.document(for: schedule)
        #expect(external.contains("<recordDestinationID>USBHDD</recordDestinationID>"))
        #expect(external.contains("<desiredQualityMode>100</desiredQualityMode>"))
    }

    @Test("録画先：外付けが登録・マウントされていれば外付け。外付けが無い・つながっていない・一覧が読めなければ内蔵")
    func recordDestinationChoice() async {
        let internalDisk = HDDEntry(id: HDDIdentity.internalID, isInternal: true, isMounted: true, isRegistered: true)
        let external = HDDEntry(id: 1, isInternal: false, isMounted: true, isRegistered: true)
        #expect(RecordDestination.preferred(for: [internalDisk]) == .internalHDD)
        #expect(RecordDestination.preferred(for: [internalDisk, external]) == .externalHDD)
        var unmounted = external
        unmounted.isMounted = false
        #expect(RecordDestination.preferred(for: [internalDisk, unmounted]) == .internalHDD)
        var unregistered = external
        unregistered.isRegistered = false
        #expect(RecordDestination.preferred(for: [internalDisk, unregistered]) == .internalHDD)
        #expect(await RecordDestination.preferred(from: NamedChannels(hdds: [internalDisk, external])) == .externalHDD)
        #expect(await RecordDestination.preferred(from: NamedChannels(hdds: nil)) == .internalHDD)
    }

    @Test("作成のモデルは送る直前に録画先を決め、重なる予約の確かめと作成に同じ値を送る。決め方を渡さなければ内蔵")
    func creationSendsResolvedDestination() async throws {
        let service = FixedSchedules()
        service.setConflicts(try schedules([scheduleItem(id: 9, start: "2026-11-20T21:30:00+09:00")]))
        let model = ScheduleCreationModel(channels: creationChannels, service: service, destination: { .externalHDD },
                                          now: { creationNow })
        await model.submit()
        await model.confirmConflicts()
        #expect(service.checked.map(\.recordDestination) == [.externalHDD])
        #expect(service.created.map(\.recordDestination) == [.externalHDD])

        let plain = FixedSchedules()
        let defaulted = ScheduleCreationModel(channels: creationChannels, service: plain, now: { creationNow })
        await defaulted.submit()
        #expect(plain.created.map(\.recordDestination) == [.internalHDD])
    }

    @Test("競合の確認は重なる予約を読み、作成は応答の 0x を外した ID を返す")
    func conflictAndCreateOverSOAP() async throws {
        let http = MockHTTP()
        let catalog = RecordingCatalogService(soap: SOAPTransport(client: http), device: NasneDevice.direct(host: NasneFixture.host))
        let schedule = NewRecordSchedule(start: creationNow.addingTimeInterval(3600), durationSeconds: 300,
                                         channel: ScheduleChannel(broadcastingType: 2, channelType: 2, serviceID: 0x41f0),
                                         networkID: 0x7E00)
        http.reply("/XSRS", method: "POST", body: NasneFixture.data("soap/conflict_ok.xml"))
        let conflicts = try await catalog.conflicts(for: schedule)
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.channel.serviceID == 0x41f0)
        http.reply("/XSRS", method: "POST", body: NasneFixture.data("soap/create_response.xml"))
        #expect(try await catalog.create(schedule) == "10000000000000000003")
        #expect(NewRecordSchedule.normalizedID("0x123") == "123")
        #expect(NewRecordSchedule.normalizedID("123") == "123")
    }

    @Test("830（時刻を指定した予約がほかにある）と 836（上限）は、文言にする")
    func faultTexts() {
        let remains = ErrorText.present(NasneError.soapFault(errorCode: "830", errorDescription: nil, source: "soap:X_CreateRecordSchedule"))
        #expect(remains.title == "時刻を指定した予約がほかにあります")
        #expect(remains.message.contains("1 件しか置けません"))
        #expect(remains.code == "830")
        let limit = ErrorText.present(NasneError.soapFault(errorCode: "836", errorDescription: nil, source: "soap:X_CreateRecordSchedule"))
        #expect(limit.title == "予約の数が上限に達しています")
        #expect(limit.message.contains("100 件まで"))
        #expect(!limit.canRetry)
    }

    @Test("既定は次の正時・60 分・DR・先頭の局。過ぎた開始・0 分・局なしは送らない")
    func defaultsAndValidation() throws {
        let model = ScheduleCreationModel(channels: creationChannels, service: FixedSchedules(), now: { creationNow })
        #expect(NasneDateTime.format(model.start) == "2026-11-20T21:00:00+09:00")
        #expect(model.durationMinutes == 60)
        #expect(model.qualityMode == QualityMode.dr)
        #expect(model.channel?.serviceName == "テスト局1")
        #expect(model.validationMessage == nil)
        #expect(ScheduleCreationDefaults.start(after: try #require(NasneDateTime.parse("2026-11-20T21:00:00+09:00")))
                == NasneDateTime.parse("2026-11-20T22:00:00+09:00"))
        model.start = creationNow.addingTimeInterval(-60)
        #expect(model.draft == nil)
        model.start = creationNow.addingTimeInterval(3600)
        model.durationMinutes = 0
        #expect(model.draft == nil)
        model.durationMinutes = 30
        model.channelKey = "2:1:1:1"   // 選べる局に無い鍵はほかの局へ替えない
        #expect(model.channel == nil)
        #expect(model.draft == nil)
    }

    @Test("同じ serviceID の局を取り違えない（4 つ組の鍵で選ぶ）。手動の予約は eventId 0")
    func picksByCompositeKey() throws {
        let model = ScheduleCreationModel(channels: creationChannels, service: FixedSchedules(), now: { creationNow })
        model.channelKey = creationChannels[1].scheduleKey
        let draft = try #require(model.draft)
        #expect(draft.networkID == 0x7E02)
        #expect(draft.eventID == 0)
        #expect(draft.desiredMatchingID == ",,0x7e02,0x0000")
    }

    @Test("重ならなければそのまま作る。重なれば止まり、続ければ作り、やめれば作らない")
    func conflictsFlow() async throws {
        let service = FixedSchedules()
        let model = ScheduleCreationModel(channels: creationChannels, service: service, now: { creationNow })
        await model.submit()
        #expect(model.phase == .created("10000000000000000003"))
        #expect(service.created.count == 1)

        let conflicting = try schedules([scheduleItem(id: 9, start: "2026-11-20T21:30:00+09:00")])
        service.setConflicts(conflicting)
        let second = ScheduleCreationModel(channels: creationChannels, service: service, now: { creationNow })
        await second.submit()
        #expect(second.phase == .confirmingConflicts(conflicting))
        #expect(service.created.count == 1)   // まだ作らない
        second.cancelConflicts()
        #expect(second.phase == .editing)
        #expect(service.created.count == 1)
        await second.submit()
        await second.confirmConflicts()
        #expect(second.phase == .created("10000000000000000003"))
        #expect(service.created.count == 2)
    }

    @Test("作成は再試行しない。届かなければ「作られているかもしれない」、断られたらそうでない。確認の失敗では作らない")
    func failuresDoNotRetry() async throws {
        let service = FixedSchedules()
        service.setCreateError(.unreachable("soap:X_CreateRecordSchedule", cause: URLError(.timedOut)))
        let model = ScheduleCreationModel(channels: creationChannels, service: service, now: { creationNow })
        await model.submit()
        guard case .failed(_, let mayHaveCreated) = model.phase else {
            Issue.record("失敗になっていない: \(model.phase)")
            return
        }
        #expect(mayHaveCreated)
        #expect(service.created.count == 1)   // 1 回だけ

        service.setCreateError(.soapFault(errorCode: "836", errorDescription: nil, source: "soap:X_CreateRecordSchedule"))
        model.dismissFailure()
        await model.submit()
        #expect(model.phase == .failed(ErrorText.present(NasneError.soapFault(errorCode: "836", errorDescription: nil, source: "t")),
                                       mayHaveCreated: false))

        service.setConflictError(.unreachable("soap:X_GetConflictList", cause: URLError(.timedOut)))
        let created = service.created.count
        model.dismissFailure()
        await model.submit()
        guard case .failed(_, let unknown) = model.phase else {
            Issue.record("失敗になっていない: \(model.phase)")
            return
        }
        #expect(!unknown)
        #expect(service.created.count == created)   // 確かめられなければ作らない
    }

    @Test("番組表からの予約：eventId を matchingID に載せ、開始と長さは番組のまま。放送中は予約でき、終わった番組はできない")
    func programReservation() throws {
        let start = creationNow.addingTimeInterval(-600)   // 10 分前に始まった（放送中）
        let event = BroadcastEvent(tableID: 0x50, serviceID: 0x4010, eventID: 0x1A2B, start: start, duration: 3_330,
                                   title: "テスト番組", text: "", lossless: true)
        let program = try #require(ScheduleProgram(station: creationChannels[1], event: event))
        #expect(program.isReservable(at: creationNow))
        let model = ScheduleCreationModel(program: program, service: FixedSchedules(), now: { creationNow })
        #expect(model.validationMessage == nil)
        let draft = try #require(model.draft)
        #expect(draft.eventID == 0x1A2B)
        #expect(draft.desiredMatchingID == ",,0x7e02,0x1a2b")
        #expect(draft.start == start)
        #expect(draft.durationSeconds == 3_330)   // 分に丸めない
        #expect(draft.channel.serviceID == 0x4010)
        #expect(draft.desiredQualityMode == QualityMode.dr)
        model.qualityMode = QualityMode.threeTimes
        #expect(model.draft?.desiredQualityMode == QualityMode.threeTimes)

        let ended = ScheduleCreationModel(program: program, service: FixedSchedules(), now: { creationNow.addingTimeInterval(3_000) })
        #expect(ended.validationMessage == "番組が終わっています")
        #expect(ended.draft == nil)

        var unknown = event
        unknown.duration = nil
        #expect(ScheduleProgram(station: creationChannels[0], event: unknown) == nil)
    }

    @Test("番組表からの予約も、重なる予約を確かめてから作る")
    func programReservationChecksConflicts() async throws {
        let event = BroadcastEvent(tableID: 0x50, serviceID: 0x4010, eventID: 7, start: creationNow.addingTimeInterval(3600),
                                   duration: 1800, title: "テスト番組", text: "", lossless: true)
        let service = FixedSchedules()
        let model = ScheduleCreationModel(program: try #require(ScheduleProgram(station: creationChannels[0], event: event)),
                                          service: service, now: { creationNow })
        await model.submit()
        #expect(service.conflictCalls == 1)
        #expect(service.created.map(\.eventID) == [7])
        #expect(model.phase == .created("10000000000000000003"))
    }
}

@MainActor
@Suite("予約の変更・削除")
struct ScheduleWriteTests {
    @Test("画質の変更は疎な更新：priorityFlag は今の値、画質と録画先（予約の今の値のまま）だけ。変える項目が無ければ送らない")
    func qualityUpdateShape() async throws {
        let original = try #require(try schedules([scheduleItem(id: 5, start: "2026-11-21T21:00:00+09:00")]).first)
        let update = ScheduleUpdate.quality(QualityMode.threeTimes, of: original)
        let document = NasneProfiles.standard.xsrs.document(for: update)
        #expect(document.contains(#"<item id="5">"#))
        #expect(document.contains("<desiredQualityMode>230</desiredQualityMode>"))
        #expect(document.contains("<priorityFlag>0</priorityFlag>"))
        #expect(document.contains("<recordDestinationID>HDD</recordDestinationID>"))
        #expect(!document.contains("scheduledStartDateTime"))
        #expect(!document.contains("scheduledConditionID"))
        // 外付けの予約の画質を変えても、録画先は外付けのまま。録画先が空なら内蔵
        let external = try #require(try schedules([scheduleItem(id: 6, start: "2026-11-21T21:00:00+09:00",
                                                                 destination: "USBHDD")]).first)
        let keeps = NasneProfiles.standard.xsrs.document(for: ScheduleUpdate.quality(QualityMode.threeTimes, of: external))
        #expect(keeps.contains("<recordDestinationID>USBHDD</recordDestinationID>"))
        let empty = NasneProfiles.standard.xsrs.document(
            for: ScheduleUpdate(id: "6", priorityFlag: 0, desiredQualityMode: QualityMode.dr, recordDestinationID: ""))
        #expect(empty.contains("<recordDestinationID>HDD</recordDestinationID>"))

        let http = MockHTTP()
        let catalog = RecordingCatalogService(soap: SOAPTransport(client: http), device: NasneDevice.direct(host: NasneFixture.host))
        await #expect(throws: NasneError.self) { try await catalog.update(ScheduleUpdate(id: "5", priorityFlag: 0)) }
    }

    @Test("削除と更新は、一覧の ID をそのまま SOAP に載せる")
    func deleteAndUpdateOverSOAP() async throws {
        let http = MockHTTP()
        let bodies = Mutex<[String]>([])
        http.respond("/XSRS", method: "POST") { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            bodies.withLock { $0.append(body) }
            let action = body.contains("X_DeleteRecordSchedule") ? "X_DeleteRecordSchedule" : "X_UpdateRecordSchedule"
            let envelope = #"<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>"#
                + #"<u:\#(action)Response xmlns:u="urn:schemas-xsrs-org:service:X_ScheduledRecording:2"></u:\#(action)Response>"#
                + "</s:Body></s:Envelope>"
            return MockHTTP.Reply(status: 200, body: Data(envelope.utf8))
        }
        let catalog = RecordingCatalogService(soap: SOAPTransport(client: http), device: NasneDevice.direct(host: NasneFixture.host))
        try await catalog.delete(id: "10000000000000000004")
        let original = try #require(try schedules([scheduleItem(id: 7, start: "2026-11-21T21:00:00+09:00")]).first)
        try await catalog.update(ScheduleUpdate.quality(QualityMode.threeTimes, of: original))
        let sent = bodies.withLock { $0 }
        #expect(sent.count == 2)
        #expect(sent[0].contains("X_DeleteRecordSchedule") && sent[0].contains("<RecordScheduleID>10000000000000000004</RecordScheduleID>"))
        #expect(sent[1].contains("X_UpdateRecordSchedule") && sent[1].contains("desiredQualityMode&gt;230"))
    }

    @Test("画質の変更：送った後に読み直し、変わったか・変わらなかったか・無くなったかを出す。届かなければ変わったかもしれないと出す")
    func editReReads() async throws {
        let list = try schedules([scheduleItem(id: 5, start: "2026-11-21T21:00:00+09:00")])
        let service = FixedSchedules(list)
        let model = ScheduleEditModel(original: list[0], service: service)
        #expect(!model.hasChange)
        await model.submit()
        #expect(service.updates.isEmpty)   // 変えていなければ送らない

        model.qualityMode = QualityMode.threeTimes
        await model.submit()
        #expect(model.phase == .finished(reflected: true))
        #expect(model.reread?.desiredQualityMode == QualityMode.threeTimes)

        let unchangedService = FixedSchedules(list)
        unchangedService.setReflectsUpdates(false)
        let unchanged = ScheduleEditModel(original: list[0], service: unchangedService)
        unchanged.qualityMode = QualityMode.threeTimes
        await unchanged.submit()
        #expect(unchanged.phase == .finished(reflected: false))   // 受け付けても変わらない

        let goneService = FixedSchedules([])
        let gone = ScheduleEditModel(original: list[0], service: goneService)
        gone.qualityMode = QualityMode.threeTimes
        await gone.submit()
        #expect(gone.phase == .missing)

        let failingService = FixedSchedules(list)
        failingService.setUpdateError(.unreachable("soap:X_UpdateRecordSchedule", cause: URLError(.timedOut)))
        let failing = ScheduleEditModel(original: list[0], service: failingService)
        failing.qualityMode = QualityMode.threeTimes
        await failing.submit()
        guard case .failed(_, let mayHaveChanged) = failing.phase else {
            Issue.record("失敗になっていない: \(failing.phase)")
            return
        }
        #expect(mayHaveChanged)
        #expect(failingService.updates.count == 1)   // 再試行しない
    }

    @Test("削除：消したら一覧を読み直す。消せなければ誤りを返し、それでも読み直す")
    func deleteReloads() async throws {
        let list = try schedules(sample)
        let service = FixedSchedules(list)
        let model = SchedulesModel(schedules: service, channels: ChannelCatalog(deviceInfo: NamedChannels()), liveStatus: LiveStatusMonitor(deviceInfo: NamedChannels(), initialLink: .online))
        await model.reload()
        #expect(await model.delete(list[0]) == nil)
        #expect(model.sortedSchedules.count == 2)
        #expect(service.deleted == [list[0].id])

        service.setDeleteError(.soapFault(errorCode: "803", errorDescription: nil, source: "soap:X_DeleteRecordSchedule"))
        let error = await model.delete(list[1])
        #expect(error?.code == "803")
        #expect(model.sortedSchedules.count == 2)
    }
}

@Suite("番組表の予約済みの印")
struct ScheduleMarksTests {
    /// 局（地上・serviceID 0x41f0）
    private let station = Channel(broadcastingType: BroadcastingType.terrestrial, networkID: 0x7e00, transportStreamID: 0x7e00,
                                  serviceID: 0x41f0, serviceType: Channel.televisionServiceType, channelNumber: 1,
                                  serviceName: "テスト局1", remoteControlKeyID: 1)

    private func event(id: UInt16, start: String, minutes: Int) throws -> BroadcastEvent {
        let date = try #require(ISO8601DateFormatter().date(from: start))
        return BroadcastEvent(tableID: 0x50, serviceID: 0x41f0, eventID: id, start: date, duration: minutes * 60,
                              title: "テスト番組", text: "", lossless: true)
    }

    @Test("番組に紐付けた予約は、帯域・serviceID・eventId が同じ番組にだけ付く（時刻は見ない）")
    func linked() throws {
        let marks = ScheduleMarks(try schedules([scheduleItem(id: 1, start: "2026-11-21T21:00:00+09:00", duration: 3600, eventID: 0x1234)]))
        #expect(marks.mark(try event(id: 0x1234, start: "2026-11-21T21:05:00+09:00", minutes: 54), on: station) != nil)
        // 同じ時間の別の番組には付けない
        #expect(marks.mark(try event(id: 0x1235, start: "2026-11-21T21:00:00+09:00", minutes: 60), on: station) == nil)
        // 別の局の同じ eventId には付けない
        var other = station
        other.serviceID = 0x41f1
        #expect(marks.mark(try event(id: 0x1234, start: "2026-11-21T21:05:00+09:00", minutes: 54), on: other) == nil)
    }

    @Test("手動の予約は、同じ局で時間が重なる番組に付く（端が接しているだけは付けない）")
    func manual() throws {
        let marks = ScheduleMarks(try schedules([scheduleItem(id: 2, start: "2026-11-21T21:00:00+09:00", duration: 1800)]))
        #expect(marks.mark(try event(id: 1, start: "2026-11-21T20:45:00+09:00", minutes: 30), on: station) != nil)   // 前から重なる
        #expect(marks.mark(try event(id: 2, start: "2026-11-21T21:10:00+09:00", minutes: 60), on: station) != nil)   // 後ろへ重なる
        #expect(marks.mark(try event(id: 3, start: "2026-11-21T20:00:00+09:00", minutes: 60), on: station) == nil)  // 終わりが接する
        #expect(marks.mark(try event(id: 4, start: "2026-11-21T21:30:00+09:00", minutes: 30), on: station) == nil)  // 始まりが接する
        var other = station
        other.serviceID = 0x41f1
        #expect(marks.mark(try event(id: 2, start: "2026-11-21T21:10:00+09:00", minutes: 60), on: other) == nil)
    }

    @Test("手動の予約が番組の始まりから終わりまでを含めば全体の印、一部だけ重なれば一部の印。番組に紐付けた予約は全体の印")
    func manualWholeOrPart() throws {
        let marks = ScheduleMarks(try schedules([scheduleItem(id: 2, start: "2026-11-21T21:00:00+09:00", duration: 1800),
                                                 scheduleItem(id: 3, start: "2026-11-21T22:00:00+09:00", duration: 600, eventID: 0x55)]))
        #expect(marks.mark(try event(id: 1, start: "2026-11-21T21:00:00+09:00", minutes: 30), on: station) == .whole)   // ちょうど同じ
        #expect(marks.mark(try event(id: 2, start: "2026-11-21T21:10:00+09:00", minutes: 10), on: station) == .whole)   // 中に入る
        #expect(marks.mark(try event(id: 3, start: "2026-11-21T20:45:00+09:00", minutes: 30), on: station) == .part)    // 前から重なる
        #expect(marks.mark(try event(id: 4, start: "2026-11-21T20:30:00+09:00", minutes: 90), on: station) == .part)    // 予約を含む長い番組
        #expect(marks.mark(try event(id: 0x55, start: "2026-11-21T22:00:00+09:00", minutes: 60), on: station) == .whole)
    }

    @Test("予約が無ければ印は付かない")
    func empty() throws {
        #expect(ScheduleMarks.none.isEmpty)
        #expect(ScheduleMarks.none.mark(try event(id: 0x1234, start: "2026-11-21T21:00:00+09:00", minutes: 60), on: station) == nil)
    }
}

@MainActor
@Suite("繰り返しの予約")
struct ScheduleRepeatTests {
    @Test("値の表：毎日 d・月〜土 w16・月〜金 w15・毎週 w と曜日。作るときの一回録画は空、変更で戻すときは 1。読むときは空と 1 が一回録画、知らない値は nil")
    func vocabulary() {
        let xsrs = NasneProfiles.standard.xsrs
        #expect(xsrs.conditionID(.once, creating: true) == "")
        #expect(xsrs.conditionID(.once, creating: false) == "1")
        #expect(xsrs.conditionID(.daily, creating: true) == "d")
        #expect(xsrs.conditionID(.mondayToSaturday, creating: true) == "w16")
        #expect(xsrs.conditionID(.mondayToFriday, creating: false) == "w15")
        #expect(xsrs.conditionID(.weekly(weekday: 2), creating: true) == "w2")
        #expect(xsrs.scheduleRepeat(conditionID: "") == .once)
        #expect(xsrs.scheduleRepeat(conditionID: "1") == .once)
        #expect(xsrs.scheduleRepeat(conditionID: "d") == .daily)
        #expect(xsrs.scheduleRepeat(conditionID: "w16") == .mondayToSaturday)
        #expect(xsrs.scheduleRepeat(conditionID: "w15") == .mondayToFriday)
        #expect(xsrs.scheduleRepeat(conditionID: "w0") == .weekly(weekday: 0))
        #expect(xsrs.scheduleRepeat(conditionID: "w7") == nil)
        #expect(xsrs.scheduleRepeat(conditionID: "w35") == nil)
        #expect(xsrs.scheduleRepeat(conditionID: "x") == nil)
    }

    @Test("作成の文書には繰り返しの値、変更の文書には変えるときだけ繰り返しの値（画質と一緒にも）")
    func documents() throws {
        let start = try #require(NasneDateTime.parse("2026-11-24T21:00:00+09:00"))   // 火曜
        var schedule = NewRecordSchedule(start: start, durationSeconds: 1800,
                                         channel: ScheduleChannel(broadcastingType: 2, channelType: 2, serviceID: 0x4010),
                                         networkID: 0x7E01, eventID: 0x10)
        #expect(NasneProfiles.standard.xsrs.document(for: schedule).contains("<scheduledConditionID></scheduledConditionID>"))
        schedule.repeatMode = .weekly(weekday: ScheduleRepeat.weekday(of: start))
        #expect(NasneProfiles.standard.xsrs.document(for: schedule).contains("<scheduledConditionID>w2</scheduledConditionID>"))
        let back = NasneProfiles.standard.xsrs.document(for: ScheduleUpdate(id: "5", priorityFlag: 0, repeatMode: .once))
        #expect(back.contains("<scheduledConditionID>1</scheduledConditionID>"))
        #expect(!back.contains("desiredQualityMode"))
        let both = NasneProfiles.standard.xsrs.document(
            for: ScheduleUpdate(id: "5", priorityFlag: 0, repeatMode: .mondayToFriday, desiredQualityMode: QualityMode.threeTimes,
                                recordDestinationID: "USBHDD"))
        #expect(both.contains("<scheduledConditionID>w15</scheduledConditionID>"))
        #expect(both.contains("<desiredQualityMode>230</desiredQualityMode>"))
        #expect(both.contains("<recordDestinationID>USBHDD</recordDestinationID>"))
        let quality = NasneProfiles.standard.xsrs.document(for: ScheduleUpdate(id: "5", priorityFlag: 0, desiredQualityMode: QualityMode.dr))
        #expect(!quality.contains("scheduledConditionID"))
    }

    @Test("曜日は日本時間で数える（日曜 0）")
    func weekday() throws {
        // 日本時間の月曜 0:30 は UTC では日曜
        let monday = try #require(NasneDateTime.parse("2026-11-23T00:30:00+09:00"))
        #expect(ScheduleRepeat.weekday(of: monday) == 1)
        #expect(ScheduleRepeat.choices(startingAt: monday).last == .weekly(weekday: 1))
    }

    @Test("繰り返しを選べるのは番組表からの予約だけ。手動の予約は選んでも一回録画で送る")
    func creationOffersRepeatForProgramOnly() throws {
        let manual = ScheduleCreationModel(channels: [Channel(broadcastingType: 2, networkID: 0x7E01, transportStreamID: 0x7E01,
                                                              serviceID: 0x4010, serviceType: Channel.televisionServiceType,
                                                              channelNumber: 1, serviceName: "テスト局1")],
                                           service: RepeatOnlySchedules(), now: { Date(timeIntervalSince1970: 1_795_000_000) })
        #expect(!manual.offersRepeat)
        #expect(manual.repeatChoices == [.once])
        manual.repeatMode = .daily
        #expect(manual.draft?.repeatMode == .once)

        let start = Date(timeIntervalSince1970: 1_795_000_000 + 3600)
        let event = BroadcastEvent(tableID: 0x50, serviceID: 0x4010, eventID: 9, start: start, duration: 1800,
                                   title: "テスト番組", text: "", lossless: true)
        let station = Channel(broadcastingType: 2, networkID: 0x7E01, transportStreamID: 0x7E01, serviceID: 0x4010,
                              serviceType: Channel.televisionServiceType, channelNumber: 1, serviceName: "テスト局1")
        let program = try #require(ScheduleProgram(station: station, event: event))
        let model = ScheduleCreationModel(program: program, service: RepeatOnlySchedules(),
                                          now: { Date(timeIntervalSince1970: 1_795_000_000) })
        #expect(model.offersRepeat)
        #expect(model.repeatChoices.count == 5)
        #expect(model.draft?.repeatMode == .once)
        model.repeatMode = .mondayToFriday
        #expect(model.draft?.repeatMode == .mondayToFriday)
    }

    @Test("変更：繰り返しを変えたら画質と 1 回で送り、読み直した値で確かめる。知らない値・手動の予約は繰り返しを変えさせない")
    func editRepeat() async throws {
        let list = try repeatSchedules(eventID: 0x10, condition: "d")
        let service = RepeatOnlySchedules(list)
        let model = ScheduleEditModel(original: list[0], service: service)
        #expect(model.offersRepeatChange)
        #expect(model.repeatMode == .daily)
        #expect(!model.hasChange)
        model.repeatMode = .once
        model.qualityMode = QualityMode.threeTimes
        await model.submit()
        #expect(service.updates.count == 1)
        #expect(service.updates.first?.repeatMode == .once)
        #expect(service.updates.first?.desiredQualityMode == QualityMode.threeTimes)
        #expect(model.phase == .finished(reflected: true))

        let unknown = try repeatSchedules(eventID: 0x10, condition: "w35")
        #expect(!ScheduleEditModel(original: unknown[0], service: RepeatOnlySchedules(unknown)).offersRepeatChange)
        #expect(ScheduleRepeatText.badge(unknown[0]) == "繰り返し w35")
        let manual = try repeatSchedules(eventID: 0, condition: "1")
        #expect(!ScheduleEditModel(original: manual[0], service: RepeatOnlySchedules(manual)).offersRepeatChange)
        #expect(ScheduleRepeatText.badge(manual[0]) == nil)
        #expect(ScheduleRepeatText.badge(list[0]) == "毎日")
    }
}

/// 繰り返しの試験の素材（予約 1 件）
private func repeatSchedules(eventID: Int, condition: String) throws -> [RecordSchedule] {
    try schedules([scheduleItem(id: 5, start: "2026-11-24T21:00:00+09:00", eventID: eventID, condition: condition)])
}

/// 変更を受けたら一覧に映す偽の予約のサービス（繰り返しの試験用）
private final class RepeatOnlySchedules: ScheduleService, Sendable {
    private let state: Mutex<(list: [RecordSchedule], updates: [ScheduleUpdate])>
    init(_ list: [RecordSchedule] = []) { state = Mutex((list, [])) }
    var updates: [ScheduleUpdate] { state.withLock { $0.updates } }
    func schedules() async throws -> [RecordSchedule] { state.withLock { $0.list } }
    func conflicts(for schedule: NewRecordSchedule) async throws -> [RecordSchedule] { [] }
    func create(_ schedule: NewRecordSchedule) async throws -> String { "1" }
    func update(_ update: ScheduleUpdate) async throws {
        state.withLock { state in
            state.updates.append(update)
            guard let index = state.list.firstIndex(where: { $0.id == update.id }) else { return }
            if let mode = update.desiredQualityMode { state.list[index].desiredQualityMode = mode }
            if let repeatMode = update.repeatMode { state.list[index].repeatMode = repeatMode }
        }
    }
    func delete(id: String) async throws {}
}
