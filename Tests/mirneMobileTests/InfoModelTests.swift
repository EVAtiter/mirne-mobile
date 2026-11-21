import Foundation
import Testing

// 情報の画面（2026-11-19 に「ホーム」から改名）。

/// 素材の WebAPI と xsrs を返す MockHTTP（本体の情報の試験と同じ組）
private func fixtureHTTP() -> MockHTTP {
    let http = MockHTTP()
    for (path, file) in [("/status/boxNameGet", "status_boxNameGet"), ("/status/softwareVersionGet", "status_softwareVersionGet"),
                         ("/status/currDateGet", "status_currDateGet"), ("/status/areaInfoGet", "status_areaInfoGet"),
                         ("/status/isFinishSetup", "status_isFinishSetup"), ("/status/updateCheck", "status_updateCheck"),
                         ("/status/HDDListGet", "status_HDDListGet"), ("/status/HDDInfoGet", "status_HDDInfoGet_id0"),
                         ("/status/liveStreamStatusListGet", "status_liveStreamStatusListGet"),
                         ("/status/recNgListGet", "status_recNgListGet"),
                         ("/recorded/recordedContentCountGet", "recorded_recordedContentCountGet"),
                         ("/recorded/recordedContentMaxCountGet", "recorded_recordedContentMaxCountGet")] {
        http.reply(path, body: NasneFixture.data("webapi/\(file).json"))
    }
    http.reply("/XSRS", method: "POST", body: NasneFixture.data("soap/title_list.xml"))
    return http
}

private func services(_ http: MockHTTP) throws -> NasneServices {
    try NasneServices.live(registration: RegisteredNasne(host: NasneFixture.host, udn: "uuid:test", friendlyName: "test",
                                                         macAddress: "00:00:5e:00:53:01"),
                           device: NasneDevice.direct(host: NasneFixture.host), client: http)
}

@MainActor
@Suite("情報の画面")
struct InfoModelTests {
    @Test("4 つの区画を読み込む（版は公式の表記・地域は表に無ければ数のまま・録画中は recordingFlag から）")
    func loadsAllSections() async throws {
        let model = InfoModel(services: try services(fixtureHTTP()))
        await model.reload()
        let device = try #require(model.device.value)
        #expect(device.softwareVersion == "2.60")
        #expect(device.currentDate != nil)
        #expect(device.area == "0")          // 素材の地域は伏せて 0 にしてある（表に無いので数のまま）
        #expect(device.titleCount == 2 && device.titleMax == 3000)
        let hdds = try #require(model.hdds.value)
        #expect(!hdds.isEmpty)
        #expect(hdds.first(where: \.isMounted)?.usedFraction != nil)
        let status = try #require(model.status.value)
        #expect(status.messages.isEmpty)     // 素材の CAMsg・EMMMsg は generation だけ
        #expect(model.recNg.value?.count == 3)
        #expect(model.lastUpdated != nil && !model.isLoading)
    }

    @Test("1 つの区画が失敗しても、ほかの区画は出す")
    func oneSectionFails() async throws {
        let http = fixtureHTTP()
        http.reply("/status/recNgListGet", status: 500, body: Data())
        let model = InfoModel(services: try services(http))
        await model.reload()
        guard case .failed(let error) = model.recNg else {
            Issue.record("録画失敗の区画が失敗になっていない")
            return
        }
        #expect(error.code == "500")
        #expect(model.device.value != nil && model.hdds.value != nil && model.status.value != nil)
    }
}

@Suite("地域の名前とお知らせ")
struct AreaAndMessagesTests {
    @Test("(areaIdentifierCode, pref) の組で引き、pref だけで決まるものは pref で引く。分からなければ数のまま")
    func areaLabels() {
        #expect(AreaNames.label(areaIdentifierCode: 23, pref: 14) == "東京")
        #expect(AreaNames.label(areaIdentifierCode: 12, pref: 2) == "北海道（旭川・空知）")
        #expect(AreaNames.label(areaIdentifierCode: 99, pref: 14) == "東京")          // 組は無いが pref で決まる
        #expect(AreaNames.label(areaIdentifierCode: 99, pref: 1) == "1")              // 北海道の 1 は pref だけでは決まらない
        #expect(AreaNames.label(areaIdentifierCode: nil, pref: nil) == nil)
        #expect(AreaNames.byPair.count == 56)
    }

    @Test("CAMsg・EMMMsg の文字列を、generation を除いて入れ子までたどって集める")
    func messages() throws {
        let json = try JSONObject(data: Data(#"""
            {"errorcode":0,"CAMsg":{"generation":3,"message":"お知らせ 1"},
             "EMMMsg":{"generation":1,"items":[{"text":"お知らせ 2"},{"text":""}]},
             "EIT_PF":{"generation":2}}
            """#.utf8), source: "test")
        let status = LiveStatus(json: json)
        #expect(status.caMessages == ["お知らせ 1"])
        #expect(status.emmMessages == ["お知らせ 2"])
        #expect(LiveStatus(json: try JSONObject(data: Data(#"{"CAMsg":{"generation":1}}"#.utf8), source: "t")).caMessages.isEmpty)
    }
}
