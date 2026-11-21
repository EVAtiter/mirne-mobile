// NasneKit の試験。torne mobile HB（MIT、© mar1mo-41414）の test/token_test.dart・epg_test.dart・xsrs_test.dart・
// didl_test.dart・webapi_transport_test.dart の考え方と既知値を Swift へ移したもの。
// 素材は伏せたもの（Fixtures）と、ここで組み立てた合成のものだけ。実放送の番組・機器の固有値は含まない。

import Foundation
import Synchronization
import Testing

@Suite("X-DTVToken")
struct TokenProviderTests {
    @Test("PIN は MAC アドレスの下位 3 オクテット（表記はそのまま）")
    func derivesPIN() throws {
        #expect(try TokenProvider.derivePIN(macAddress: "00:11:22:33:44:55") == "334455")
        #expect(try TokenProvider.derivePIN(macAddress: "00:25:dc:58:da:f0") == "58daf0")
        #expect(throws: NasneError.self) { try TokenProvider.derivePIN(macAddress: "00:11:22") }
    }

    @Test("既知値（PINVerify の形・フォームの本文・256 文字で切る）")
    func knownValues() {
        #expect(TokenProvider.computeToken(pin: "334455", path: "/config/PINVerify", body: Data()) == "9JOKWxjRn9ykWcZg64FM+gJC7Ik=")
        #expect(TokenProvider.computeToken(pin: "334455", path: "/config/boxNameSet", body: Data("name=nasne-test".utf8))
            == "y8gpxn3qdE7CFJBmkAJaD7QHPlM=")
        let long = Data(String(repeating: "x", count: 300).utf8)
        #expect(TokenProvider.computeToken(pin: "334455", path: "/config/boxNameSet", body: long) == "hR9VvweodV3XWNUVFtLXy857MUc=")
    }

    @Test("既知値（バイナリの本文。EPGGet）")
    func binaryKnownValues() {
        let body = Data((0..<256).map { UInt8($0) } + (0..<44).map { UInt8($0) })
        #expect(TokenProvider.computeToken(pin: "58daf0", path: "/chEpg/EPGGet", body: body) == "bMewukHcBeDzR98CFaWM5QaernU=")
        #expect(TokenProvider.computeToken(pin: "58daf0", path: "/chEpg/EPGGet", body: Data()) == "Xqt+rPF+cp7Umm93PIotmL7gZ4w=")
    }
}

@Suite("WebAPI の転送層")
struct WebAPITransportTests {
    @Test("GET の JSON を読み、errorcode が 0 でなければ webapi の誤りにする")
    func decodesJSONAndErrorCodes() async throws {
        let http = MockHTTP()
        http.reply("/status/boxNameGet", body: NasneFixture.data("webapi/status_boxNameGet.json"))
        http.reply("/status/updateCheck", body: Data(#"{"errorcode": 5}"#.utf8))
        let transport = WebAPITransport(host: NasneFixture.host, client: http)
        #expect(try await transport.getJSON(NasneProfiles.standard.webAPI.boxNameGet).string("name") != nil)
        let error = await #expect(throws: NasneError.self) { try await transport.getJSON(NasneProfiles.standard.webAPI.updateCheck) }
        #expect(error?.category == .webapi)
        #expect(error?.code == "5")
    }

    @Test("届かなければ 3 回まで試し、それでもだめなら unreachable")
    func retriesReadsOnly() async throws {
        let http = MockHTTP()
        http.reply("/status/boxNameGet", body: NasneFixture.data("webapi/status_boxNameGet.json"))
        http.failNext("/status/boxNameGet", count: 2)
        let transport = WebAPITransport(host: NasneFixture.host, client: http)
        _ = try await transport.getJSON(NasneProfiles.standard.webAPI.boxNameGet)
        #expect(http.sentRequests.count == 3)

        http.failNext("/status/boxNameGet", count: 3)
        let error = await #expect(throws: NasneError.self) { try await transport.getJSON(NasneProfiles.standard.webAPI.boxNameGet) }
        #expect(error?.category == .unreachable)
    }

    @Test("POST は再試行しない")
    func doesNotRetryWrites() async throws {
        let http = MockHTTP()
        http.failNext("/config/PINVerify", method: "POST", count: 1)
        let transport = WebAPITransport(host: NasneFixture.host, client: http, tokens: TokenProvider(pin: "334455"))
        await #expect(throws: NasneError.self) { try await transport.postJSON(NasneProfiles.standard.webAPI.pinVerify) }
        #expect(http.sentRequests.count == 1)
    }

    @Test("PINVerify は本文なしの POST にトークンを付ける")
    func attachesToken() async throws {
        let http = MockHTTP()
        http.reply("/config/PINVerify", method: "POST", body: Data(#"{"errorcode": 0}"#.utf8))
        let transport = WebAPITransport(host: NasneFixture.host, client: http, tokens: TokenProvider(pin: "334455"))
        _ = try await transport.postJSON(NasneProfiles.standard.webAPI.pinVerify)
        let request = try #require(http.sentRequests.first)
        #expect(request.value(forHTTPHeaderField: "X-DTVToken") == "9JOKWxjRn9ykWcZg64FM+gJC7Ik=")
        #expect(request.url?.port == NasneProfiles.standard.ports.webAPI)
        #expect((request.httpBody ?? Data()).isEmpty)
    }

    @Test("トークンが要るのに無ければ、送らずに弾く")
    func refusesWithoutToken() async {
        let http = MockHTTP()
        let transport = WebAPITransport(host: NasneFixture.host, client: http)
        let error = await #expect(throws: NasneError.self) { try await transport.postJSON(NasneProfiles.standard.webAPI.pinVerify) }
        #expect(error?.category == .validation)
        #expect(http.sentRequests.isEmpty)
    }

    @Test("必須のパラメータが無ければ、送らずに弾く")
    func checksRequiredParameters() async {
        let http = MockHTTP()
        let transport = WebAPITransport(host: NasneFixture.host, client: http)
        await #expect(throws: NasneError.self) { try await transport.getJSON(NasneProfiles.standard.webAPI.channelListGet) }
        #expect(http.sentRequests.isEmpty)
    }

    @Test("POST の 400 は webapi の拒否（トークンの誤りを疑う）")
    func classifies400() async {
        let http = MockHTTP()
        http.reply("/config/PINVerify", method: "POST", status: 400, body: Data())
        let transport = WebAPITransport(host: NasneFixture.host, client: http, tokens: TokenProvider(pin: "334455"))
        let error = await #expect(throws: NasneError.self) { try await transport.postJSON(NasneProfiles.standard.webAPI.pinVerify) }
        #expect(error?.category == .webapi)
        #expect(error?.code == "400")
    }
}

@Suite("発見と登録")
struct DiscoveryTests {
    @Test("デバイス記述から nasne と 4 つのサービスを読む")
    func parsesDescription() throws {
        let location = URL(string: "http://\(NasneFixture.host):58888/")!
        let device = try NasneDevice.parseDescription(NasneFixture.data("upnp_description.xml"), location: location)
        #expect(device.isNasne)
        #expect(device.services.count == 4)
        let control = device.controlURL(for: NasneProfiles.standard.soap.scheduledRecording)
        #expect(control.port == NasneProfiles.standard.ports.xsrs)
        #expect(device.controlURL(for: NasneProfiles.standard.soap.contentDirectory).path == "/MediaServer_ContentDirectory/control")
    }

    @Test("Buffalo 製の個体（modelName が buffalo-nasne）も nasne と見なす。ほかの名前は見なさない")
    func buffaloModelName() throws {
        let location = URL(string: "http://\(NasneFixture.host):58888/")!
        let text = NasneFixture.text("upnp_description.xml")
        let buffalo = Data(text.replacingOccurrences(of: "<modelName>nasne<", with: "<modelName>buffalo-nasne<").utf8)
        #expect(try NasneDevice.parseDescription(buffalo, location: location).isNasne)
        let other = Data(text.replacingOccurrences(of: "<modelName>nasne<", with: "<modelName>nasne-like<").utf8)
        #expect(try !NasneDevice.parseDescription(other, location: location).isNasne)
    }

    @Test("手で入れたアドレス：/ が取れれば SSDP に問い合わせない")
    func describesHostAtRoot() async throws {
        let http = MockHTTP()
        http.reply("/", body: NasneFixture.data("upnp_description.xml"))
        let describer = DeviceDescriber(client: http, locate: { _ in
            Issue.record("/ が取れたのに SSDP に問い合わせた")
            return nil
        })
        let device = try await describer.describe(host: NasneFixture.host)
        #expect(device.isNasne)
        #expect(device.descriptionURL.path == "/")
    }

    @Test("手で入れたアドレス：/ が 404 なら SSDP の LOCATION の記述を取り、相対の control URL もそこから解く")
    func describesHostViaSSDP() async throws {
        let http = MockHTTP()
        let text = NasneFixture.text("upnp_description.xml")
            .replacingOccurrences(of: "<modelName>nasne<", with: "<modelName>buffalo-nasne<")
            .replacingOccurrences(of: "/MediaServer_ContentDirectory/control", with: "/UD/test?0")
        http.reply("/XD/test", body: Data(text.utf8))
        let describer = DeviceDescriber(client: http, locate: { host in
            URL(string: "http://\(host):\(NasneProfiles.standard.ports.dms)/XD/test")
        })
        let device = try await describer.describe(host: NasneFixture.host)
        #expect(device.isNasne)
        #expect(device.descriptionURL.path == "/XD/test")
        let control = device.controlURL(for: NasneProfiles.standard.soap.contentDirectory)
        #expect(control.path == "/UD/test")
        #expect(control.query == "0")
    }

    @Test("手で入れたアドレス：/ が 404 で SSDP も応えなければ、/ の誤りを返す")
    func describesHostFails() async {
        let describer = DeviceDescriber(client: MockHTTP(), locate: { _ in nil })
        let error = await #expect(throws: NasneError.self) { try await describer.describe(host: NasneFixture.host) }
        #expect(error?.code == "404")
    }

    @Test("手で入れたのがデバイス記述の URL なら、その記述をそのまま取る（SSDP に問い合わせない）")
    func describesDescriptionURL() async throws {
        let http = MockHTTP()
        let text = NasneFixture.text("upnp_description.xml")
            .replacingOccurrences(of: "<modelName>nasne<", with: "<modelName>buffalo-nasne<")
        http.reply("/XD/test", body: Data(text.utf8))
        let describer = DeviceDescriber(client: http, locate: { _ in
            Issue.record("URL を入れたのに SSDP に問い合わせた")
            return nil
        })
        let device = try await describer.describe(host: "http://\(NasneFixture.host):\(NasneProfiles.standard.ports.dms)/XD/test")
        #expect(device.isNasne)
        #expect(device.descriptionURL.path == "/XD/test")
        #expect(DeviceDescriber.descriptionURL(NasneFixture.host) == nil)
        #expect(DeviceDescriber.descriptionURL("http://") == nil)
    }

    @Test("SSDP の生存の知らせ（NOTIFY ssdp:alive）から MediaServer の LOCATION を読む")
    func parsesAnnouncement() {
        func notify(_ nts: String, _ nt: String = SSDPTransport.mediaServerSearchTarget) -> Data {
            Data("NOTIFY * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nNT: \(nt)\r\nNTS: \(nts)\r\nLOCATION: http://192.0.2.1:58888/XD/test\r\n\r\n".utf8)
        }
        #expect(SSDPTransport.parseAnnouncement(notify("ssdp:alive")) == "http://192.0.2.1:58888/XD/test")
        #expect(SSDPTransport.parseAnnouncement(notify("ssdp:byebye")) == nil)
        #expect(SSDPTransport.parseAnnouncement(notify("ssdp:alive", "upnp:rootdevice")) == nil)
        #expect(SSDPTransport.parseAnnouncement(Data("HTTP/1.1 200 OK\r\nLOCATION: http://192.0.2.1:58888/\r\n\r\n".utf8)) == nil)
    }

    @Test("M-SEARCH で見つからなければ知らせを待ち、nasne でない機器は飛ばして、nasne が見つかったところで返す")
    func discoversViaAnnouncements() async throws {
        let http = MockHTTP()
        let nasne = NasneFixture.text("upnp_description.xml")
            .replacingOccurrences(of: "<modelName>nasne<", with: "<modelName>buffalo-nasne<")
        let other = NasneFixture.text("upnp_description.xml")
            .replacingOccurrences(of: "<modelName>nasne<", with: "<modelName>other-server<")
        http.reply("/XD/nasne", body: Data(nasne.utf8))
        http.reply("/XD/other", body: Data(other.utf8))
        let base = "http://\(NasneFixture.host):\(NasneProfiles.standard.ports.dms)"
        let heard = Mutex<[Set<String>]>([])
        let service = SSDPDiscoveryService(
            client: http, diagnostics: .none, search: { [] },
            listen: { _, known in
                heard.withLock { $0.append(known) }
                return known.contains("\(base)/XD/other") ? ["\(base)/XD/nasne"] : ["\(base)/XD/other"]
            },
            announcementDuration: 5)
        let devices = try await service.discover()
        #expect(devices.count == 1)
        #expect(devices.first?.descriptionURL.path == "/XD/nasne")
        // 2 回目は、もう見た LOCATION を渡して聞き直している
        #expect(heard.withLock { $0.count } == 2)
    }

    @Test("M-SEARCH で見つかれば知らせは待たない")
    func skipsAnnouncementsWhenFound() async throws {
        let http = MockHTTP()
        http.reply("/", body: NasneFixture.data("upnp_description.xml"))
        let location = "http://\(NasneFixture.host):\(NasneProfiles.standard.ports.dms)/"
        let response = SSDPTransport.parse(Data("HTTP/1.1 200 OK\r\nLOCATION: \(location)\r\n\r\n".utf8))!
        let service = SSDPDiscoveryService(
            client: http, diagnostics: .none, search: { [response] },
            listen: { _, _ in
                Issue.record("見つかったのに知らせを待った")
                return []
            },
            announcementDuration: 5)
        #expect(try await service.discover().count == 1)
    }

    @Test("SSDP の応答の見出しを読む（200 でない行は捨てる）")
    func parsesSSDP() {
        let ok = SSDPTransport.parse(Data("HTTP/1.1 200 OK\r\nLOCATION: http://192.0.2.1:58888/\r\nST: x\r\n\r\n".utf8))
        #expect(ok?.location == "http://192.0.2.1:58888/")
        #expect(SSDPTransport.parse(Data("NOTIFY * HTTP/1.1\r\n\r\n".utf8)) == nil)
    }

    @Test("登録：MAC アドレスを取り、PINVerify を通し、PIN ではなく MAC アドレスを持つ")
    func registers() async throws {
        let http = MockHTTP()
        http.reply("/status/networkIfInfoGet", body: NasneFixture.data("webapi/status_networkIfInfoGet.json"))
        http.reply("/config/PINVerify", method: "POST", body: Data(#"{"errorcode": 0}"#.utf8))
        let registration = try await WebAPIRegistrationService(client: http).register(NasneDevice.direct(host: NasneFixture.host))
        #expect(registration.macAddress == "00:11:22:33:44:55")
        #expect(http.sentRequests.last?.value(forHTTPHeaderField: "X-DTVToken") == "9JOKWxjRn9ykWcZg64FM+gJC7Ik=")
    }

    @Test("私設アドレスの判定")
    func privateAddresses() {
        // 私設アドレスの文字列を直書きすると漏れ検査に当たるので、オクテットの配列で書く
        #expect(LocalNetwork.isPrivateIPv4(octets: [10, 1, 2, 3]))
        #expect(LocalNetwork.isPrivateIPv4(octets: [172, 16, 0, 1]))
        #expect(!LocalNetwork.isPrivateIPv4(octets: [172, 32, 0, 1]))
        #expect(LocalNetwork.isPrivateIPv4(octets: [192, 168, 1, 1]))
        #expect(!LocalNetwork.isPrivateIPv4("192.0.2.1"))
        #expect(!LocalNetwork.isPrivateIPv4("あ"))
    }
}

@Suite("本体の情報")
struct DeviceInfoTests {
    func service() -> WebAPIDeviceInfoService {
        let http = MockHTTP()
        for (path, file) in [("/status/boxNameGet", "status_boxNameGet"), ("/status/softwareVersionGet", "status_softwareVersionGet"),
                             ("/status/currDateGet", "status_currDateGet"), ("/status/areaInfoGet", "status_areaInfoGet"),
                             ("/status/isFinishSetup", "status_isFinishSetup"), ("/status/updateCheck", "status_updateCheck"),
                             ("/status/HDDListGet", "status_HDDListGet"), ("/status/HDDInfoGet", "status_HDDInfoGet_id0"),
                             ("/status/channelListGet", "status_channelListGet_broadcastingType2"),
                             ("/status/liveStreamStatusListGet", "status_liveStreamStatusListGet"),
                             ("/status/recNgListGet", "status_recNgListGet"),
                             ("/recorded/recordedContentCountGet", "recorded_recordedContentCountGet"),
                             ("/recorded/recordedContentMaxCountGet", "recorded_recordedContentMaxCountGet")] {
            http.reply(path, body: NasneFixture.data("webapi/\(file).json"))
        }
        return WebAPIDeviceInfoService(transport: WebAPITransport(host: NasneFixture.host, client: http))
    }

    @Test("本体の情報（版は公式の表記に直す）")
    func deviceInfo() async throws {
        let info = try await service().deviceInfo()
        #expect(info.softwareVersion == "0260")
        #expect(info.displaySoftwareVersion == "2.60")
        #expect(info.finishedSetup)
    }

    @Test("HDD の一覧と大きさ（バイト）")
    func hdd() async throws {
        let service = service()
        let list = try await service.hddList()
        #expect(!list.isEmpty)
        // internalFlag は名前と逆（内蔵が 0）。素材は内蔵 1 台で internalFlag 0
        #expect(list.first?.isInternal == true)
        let detail = try await service.hddInfo(id: 0)
        #expect(detail.isInternal)
        #expect(detail.totalBytes == 498_521_100_288)
        #expect(detail.usedBytes + detail.freeBytes <= detail.totalBytes)
    }

    @Test("チャンネル 24 件。本チャンネルは同じ TS の TV サービスのうち最小の serviceID（9 局）")
    func channelsAndSubchannels() async throws {
        let channels = try await service().channels()
        #expect(channels.count == 24)
        let sub = Channel.subchannelServiceIDs(channels)
        let main = Set(channels.filter { $0.serviceType == Channel.televisionServiceType }.map(\.serviceID)).subtracting(sub)
        // 素材の ID は付け替えてある（元の 56336 を 0x4000 に、差はそのまま）
        #expect(main == [16880, 16888, 16384, 16392, 16400, 16408, 16416, 16472, 16488])
        #expect(sub.count == 11)
    }

    @Test("集約ステータス・録画の失敗・件数")
    func liveStatusAndCounts() async throws {
        let service = service()
        let live = try await service.liveStatus()
        #expect(live.sections["EIT_PF"] != nil)
        #expect(try await service.recNgList().count == 3)
        let counts = try await service.titleCounts()
        #expect(counts.count == 2)
        #expect(counts.max == 3000)
    }
}

@Suite("予約と録画一覧")
struct RecordingCatalogTests {
    func catalog() -> RecordingCatalogService {
        let http = MockHTTP()
        http.reply("/XSRS", method: "POST", body: NasneFixture.data("soap/title_list.xml"))
        // Browse の素材は DIDL-Lite の文書そのものなので、SOAP の封筒に包む
        let envelope = """
            <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
            <u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">\
            <Result>\(XMLTree.escapeText(NasneFixture.text("dlna/browse_0_video_all.xml")))</Result>\
            <NumberReturned>2</NumberReturned></u:BrowseResponse></s:Body></s:Envelope>
            """
        http.reply("/MediaServer_ContentDirectory/control", method: "POST", body: Data(envelope.utf8))
        return RecordingCatalogService(soap: SOAPTransport(client: http), device: NasneDevice.direct(host: NasneFixture.host))
    }

    @Test("xsrs の録画 2 件に DIDL をタイトル ID で結合する")
    func joinsTitles() async throws {
        let titles = try await catalog().titles()
        #expect(titles.count == 2)
        for title in titles {
            #expect(title.copyCountRemaining != nil)
            #expect(title.resources.count == 3)
            #expect(title.originalResource?.quality == "dr")
            #expect(title.mobileResource?.quality == "mobile")
            #expect(title.offersQualityChoice)
            #expect(title.originalResource?.dtcpHost == NasneFixture.host)
            #expect(title.originalResource?.dtcpPort != nil)
        }
        #expect(titles.first?.resumePointSeconds == 16)
    }

    @Test("番組の開始（DIDL）を持ち、日時は番組の開始・「再生」は録り始めからのずれの位置から（素材は 14 秒と 11 秒）")
    func programStart() async throws {
        let titles = try await catalog().titles()
        let offsets = titles.map(\.programStartOffsetSeconds)
        #expect(offsets.contains(14) && offsets.contains(11))
        for title in titles {
            #expect(title.programStart != nil && title.programEnd != nil)
            #expect(title.displayStart == title.programStart)
            #expect(title.playbackStartSeconds == title.programStartOffsetSeconds)
            // 録り始め（xsrs）は番組の開始より前
            #expect(try #require(title.start) < #require(title.programStart))
        }
        // 番組の開始が分からない・録り始めより前・長さを超えるなら、日時は録り始め・再生は頭から
        var unknown = try #require(titles.first)
        unknown.programStart = nil
        #expect(unknown.displayStart == unknown.start && unknown.playbackStartSeconds == 0)
        var before = try #require(titles.first)
        before.programStart = before.start?.addingTimeInterval(-60)
        #expect(before.programStartOffsetSeconds == nil && before.playbackStartSeconds == 0)
        var beyond = try #require(titles.first)
        beyond.programStart = beyond.start?.addingTimeInterval(Double((beyond.durationSeconds ?? 0) + 1))
        #expect(beyond.playbackStartSeconds == 0)
    }

    @Test("URL に cp の付いた res（ムーブ専用）は再生に選ばない")
    func skipsMoveOnlyResources() async throws {
        // 素材の dr とモバイルの res をムーブ専用にする（dr&sep の res は残る）
        let didl = NasneFixture.text("dlna/browse_0_video_all.xml")
            .replacingOccurrences(of: "quality=dr</res>", with: "quality=dr&amp;cp</res>")
            .replacingOccurrences(of: "quality=mobile</res>", with: "quality=mobile&amp;cp</res>")
        let http = MockHTTP()
        http.reply("/XSRS", method: "POST", body: NasneFixture.data("soap/title_list.xml"))
        let envelope = """
            <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
            <u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">\
            <Result>\(XMLTree.escapeText(didl))</Result>\
            <NumberReturned>2</NumberReturned></u:BrowseResponse></s:Body></s:Envelope>
            """
        http.reply("/MediaServer_ContentDirectory/control", method: "POST", body: Data(envelope.utf8))
        let titles = try await RecordingCatalogService(soap: SOAPTransport(client: http),
                                                       device: NasneDevice.direct(host: NasneFixture.host)).titles()
        #expect(titles.count == 2)
        for title in titles {
            #expect(title.resources.filter(\.isMoveOnly).count == 2)
            #expect(title.playableResources.count == 1)
            #expect(title.originalResource?.isMoveOnly == false)
            #expect(title.originalResource?.url.hasSuffix("quality=dr&sep") == true)
            #expect(title.mobileResource == nil)
            #expect(!title.offersQualityChoice)
        }
    }

    @Test("再生できる res がモバイルだけなら、元画質の在りかもモバイルになり、画質は選ばせない")
    func mobileOnlyOffersNoChoice() async throws {
        // 素材の dr の res を 2 本ともムーブ専用にする（モバイルだけが再生できる）
        let didl = NasneFixture.text("dlna/browse_0_video_all.xml")
            .replacingOccurrences(of: "quality=dr</res>", with: "quality=dr&amp;cp</res>")
            .replacingOccurrences(of: "quality=dr&amp;sep</res>", with: "quality=dr&amp;sep&amp;cp</res>")
        let http = MockHTTP()
        http.reply("/XSRS", method: "POST", body: NasneFixture.data("soap/title_list.xml"))
        let envelope = """
            <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
            <u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">\
            <Result>\(XMLTree.escapeText(didl))</Result>\
            <NumberReturned>2</NumberReturned></u:BrowseResponse></s:Body></s:Envelope>
            """
        http.reply("/MediaServer_ContentDirectory/control", method: "POST", body: Data(envelope.utf8))
        let titles = try await RecordingCatalogService(soap: SOAPTransport(client: http),
                                                       device: NasneDevice.direct(host: NasneFixture.host)).titles()
        #expect(titles.count == 2)
        for title in titles {
            #expect(title.playableResources.map(\.quality) == ["mobile"])
            #expect(title.originalResource?.quality == "mobile")
            #expect(title.mobileResource?.quality == "mobile")
            #expect(!title.offersQualityChoice)
        }
    }

    /// 要求の本文の StartingIndex
    static func startingIndex(_ request: URLRequest) -> Int {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        guard let range = body.range(of: #"(?<=<StartingIndex>)[0-9]+"#, options: .regularExpression) else { return -1 }
        return Int(body[range]) ?? -1
    }

    /// 素材の 2 件のタイトル ID を、頁ごとに違う ID へ置き換える
    static func renumber(_ text: String, page: Int) -> String {
        text.replacingOccurrences(of: "10000000000000000001", with: "2000000000000000\(page)01")
            .replacingOccurrences(of: "10000000000000000002", with: "2000000000000000\(page)02")
    }

    @Test("X_GetTitleList と Browse は TotalMatches に届くまで頁を送り、全頁を結合する")
    func pagesTitles() async throws {
        let pages = 3
        let perPage = 2
        let http = MockHTTP()
        let titleList = NasneFixture.text("soap/title_list.xml")
            .replacingOccurrences(of: "<TotalMatches>2<", with: "<TotalMatches>\(pages * perPage)<")
        http.respond("/XSRS", method: "POST") { request in
            let start = Self.startingIndex(request)
            return .init(status: 200, body: Data(Self.renumber(titleList, page: start / perPage).utf8))
        }
        let didl = NasneFixture.text("dlna/browse_0_video_all.xml")
        http.respond("/MediaServer_ContentDirectory/control", method: "POST") { request in
            let start = Self.startingIndex(request)
            let envelope = """
                <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
                <u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">\
                <Result>\(XMLTree.escapeText(Self.renumber(didl, page: start / perPage)))</Result>\
                <NumberReturned>\(perPage)</NumberReturned><TotalMatches>\(pages * perPage)</TotalMatches>\
                </u:BrowseResponse></s:Body></s:Envelope>
                """
            return .init(status: 200, body: Data(envelope.utf8))
        }
        let catalog = RecordingCatalogService(soap: SOAPTransport(client: http), device: NasneDevice.direct(host: NasneFixture.host))
        let titles = try await catalog.titles()
        #expect(titles.count == pages * perPage)
        #expect(Set(titles.map(\.id)).count == pages * perPage)
        #expect(titles.allSatisfy { $0.resources.count == 3 })
        let starts = http.sentRequests.map(Self.startingIndex)
        #expect(starts == [0, 2, 4, 0, 2, 4])
        // 録画一覧は表の件数を指定して頼み（既定の頁の 200 件より多く返させる）、Browse は 0 のまま
        let counts = http.sentRequests.map { request -> String in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            return body.range(of: #"(?<=<RequestedCount>)[0-9]+"#, options: .regularExpression).map { String(body[$0]) } ?? ""
        }
        let names = NasneProfiles.standard.soap.arguments
        #expect(counts == Array(repeating: String(names.titleListRequestCount), count: pages)
                + Array(repeating: String(names.requestAll), count: pages))
    }

    @Test("TotalMatches の無い応答は 1 頁で終える")
    func singlePageWithoutTotal() async throws {
        let http = MockHTTP()
        let titleList = NasneFixture.text("soap/title_list.xml")
            .replacingOccurrences(of: "<TotalMatches>2</TotalMatches>", with: "")
        http.reply("/XSRS", method: "POST", body: Data(titleList.utf8))
        let catalog = RecordingCatalogService(soap: SOAPTransport(client: http), device: NasneDevice.direct(host: NasneFixture.host))
        #expect(try await catalog.titles(withMetadata: false).count == 2)
        #expect(http.sentRequests.count == 1)
    }

    @Test("予約の一覧（1 件）と空の一覧")
    func schedules() async throws {
        let http = MockHTTP()
        http.reply("/XSRS", method: "POST", body: NasneFixture.data("soap/schedule_list_one.xml"))
        let catalog = RecordingCatalogService(soap: SOAPTransport(client: http), device: NasneDevice.direct(host: NasneFixture.host))
        let list = try await catalog.schedules()
        #expect(list.count == 1)
        #expect(list.first?.durationSeconds ?? 0 > 0)
        #expect(!(list.first?.id.hasPrefix("0x") ?? true))

        http.reply("/XSRS", method: "POST", body: NasneFixture.data("soap/record_schedule_list_empty.xml"))
        #expect(try await catalog.schedules().isEmpty)
    }

    @Test("SOAP の Fault は soapFault の誤りにする（コードを残す）")
    func fault() async {
        let http = MockHTTP()
        http.reply("/XSRS", method: "POST", status: 500, body: NasneFixture.data("soap/conflict_fault.xml"))
        let catalog = RecordingCatalogService(soap: SOAPTransport(client: http), device: NasneDevice.direct(host: NasneFixture.host))
        let error = await #expect(throws: NasneError.self) { try await catalog.schedules() }
        #expect(error?.category == .soapFault)
        #expect(error?.code == "402")
    }

    @Test("SOAP の封筒：引数の値をエスケープし、SOAPAction を付ける")
    func envelope() async throws {
        let http = MockHTTP()
        http.reply("/XSRS", method: "POST", body: NasneFixture.data("soap/record_schedule_list_empty.xml"))
        _ = try? await SOAPTransport(client: http).call(controlURL: URL(string: "http://\(NasneFixture.host):64230/XSRS")!,
                                                        serviceType: NasneProfiles.standard.soap.scheduledRecording.serviceType,
                                                        action: "X_GetRecordScheduleList",
                                                        arguments: [("Elements", "<item id=\"\">&</item>")])
        let request = try #require(http.sentRequests.first)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("<Elements>&lt;item id=\"\"&gt;&amp;&lt;/item&gt;</Elements>"))
        #expect(request.value(forHTTPHeaderField: "SOAPAction") == "\"\(NasneProfiles.standard.soap.scheduledRecording.serviceType)#X_GetRecordScheduleList\"")
    }
}

@Suite("番組表")
struct EPGFetchTests {
    @Test("平文の EIT セクションを順に読み、接頭辞を飛ばす。番組名の無い番組は載せない")
    func readsSections() {
        let (sections, skipped) = EPGFormat.sections(inPlaintext: SyntheticEPG.plaintext())
        #expect(sections.count == 2)
        #expect(skipped == 4)
        let events = sections.flatMap(\.events)
        #expect(events.count == 1)
        let event = try! #require(events.first)
        #expect(event.title == "テレビ")
        #expect(event.eventID == 0x101)
        #expect(event.duration == 30 * 60)
        #expect(event.genre?.major == 7)
        // 09:55 の日本時間 = 00:55 UTC
        #expect(event.start == Date(timeIntervalSince1970: 1_794_790_500))
    }

    @Test("CRC の壊れたセクションは採らない")
    func ignoresBrokenCRC() {
        let (sections, _) = EPGFormat.sections(inPlaintext: SyntheticEPG.plaintext(breakSecondCRC: true))
        #expect(sections.count == 1)
    }

    @Test("XOR と zlib を外す（行って戻る）")
    func unwrapsResponse() throws {
        let plain = SyntheticEPG.plaintext()
        #expect(try EPGFormat.plaintext(ofResponse: SyntheticEPG.wrap(plain)) == plain)
    }

    @Test("Adler-32 が合わなければ投げる")
    func rejectsBadAdler() {
        var bytes = SyntheticEPG.zlib(SyntheticEPG.plaintext())
        bytes[bytes.count - 1] ^= 0xFF
        #expect(throws: NasneError.self) { try ZlibStream.inflate(bytes, from: 0) }
    }

    @Test("版数表のサービスを表の順に並べる（見出しの件数が 0 なら末尾まで）")
    func versionTable() {
        let services = [EPGServiceRef(networkID: 1, transportStreamID: 2, serviceID: 3),
                        EPGServiceRef(networkID: 4, transportStreamID: 5, serviceID: 6)]
        #expect(EPGFormat.services(inVersionTable: SyntheticEPG.versionTable(services)) == services)
        #expect(EPGFormat.services(inVersionTable: Data()).isEmpty)
        #expect(EPGFormat.services(inVersionTable: Data(count: 12)).isEmpty)
    }

    @Test("版数表のレコードの長さは flags で変わる：0xC000 は 144・0x8000 は 76・0 は 8 バイト。0 の後ろの局も読む（実機の形）")
    func versionTableVariableRecords() {
        // 実機（2026-11-21・Buffalo 製）と同じ並び：0xC000 が続き、番組表の無いサービス（0）を挟んで 0xC000 と 0x8000 の局
        let table = SyntheticEPG.versionTable(records: [(1, 2, 3, 0xC000), (1, 2, 4, 0xC000), (1, 9, 9, 0x0000),
                                                        (5, 6, 7, 0xC000), (5, 6, 8, 0x8000), (5, 6, 9, 0x8000)])
        #expect(table.count == 12 + 144 * 3 + 8 + 76 * 2)
        let services = EPGFormat.services(inVersionTable: table)
        #expect(services.map(\.serviceID) == [3, 4, 7, 8, 9])
        #expect(services.map(\.hasExtended) == [true, true, true, false, false])
        #expect(services.map(\.hasBasic) == [true, true, true, true, true])
        // 知らない flags に当たったら、それより後ろは読まない
        let unknown = SyntheticEPG.versionTable(records: [(1, 2, 3, 0xC000), (1, 2, 4, 0x0B0B), (1, 2, 5, 0xC000)])
        #expect(EPGFormat.services(inVersionTable: unknown).map(\.serviceID) == [3])
    }

    @Test("EPGGet の本文：基本だけの局は拡張のビットマップを立てない")
    func requestBodyBasicOnlyService() {
        let services = [EPGServiceRef(networkID: 1, transportStreamID: 2, serviceID: 3),
                        EPGServiceRef(networkID: 1, transportStreamID: 2, serviceID: 4, hasExtended: false)]
        let body = [UInt8](EPGFormat.requestBody(services: services))
        #expect(Array(body[16..<32]) == [UInt8](repeating: 0xFF, count: 16))
        #expect(Array(body[40..<48]) == [UInt8](repeating: 0xFF, count: 8))
        #expect(Array(body[48..<56]) == [UInt8](repeating: 0, count: 8))
    }

    @Test("EPGGet の本文：見出しの件数・レコード・ビットマップ")
    func requestBody() {
        let services = [EPGServiceRef(networkID: 0x1111, transportStreamID: 0x2222, serviceID: 0x3333),
                        EPGServiceRef(networkID: 0x4444, transportStreamID: 0x5555, serviceID: 0x6666)]
        let body = [UInt8](EPGFormat.requestBody(services: services))
        #expect(body.count == 8 + 24 * 2)
        #expect(Array(body[0..<8]) == [0, 0, 0, 0, 0, 2, 0, 0])
        #expect(Array(body[8..<16]) == [0x11, 0x11, 0x22, 0x22, 0x33, 0x33, 0, 0])
        #expect(Array(body[16..<32]) == [UInt8](repeating: 0xFF, count: 16))
        let basicOnly = [UInt8](EPGFormat.requestBody(services: services, extended: false))
        #expect(Array(basicOnly[24..<32]) == [UInt8](repeating: 0, count: 8))
        #expect([UInt8](EPGFormat.requestBody(services: services, linkedDescriptions: true))[8 + 6] == 1)
        let many = [UInt8](EPGFormat.requestBody(services: Array(repeating: services[0], count: 300)))
        #expect(Array(many[4..<6]) == [0x01, 0x2C])
    }

    @Test("ロゴ：PNG のあるレコードだけを serviceID で引く")
    func logos() {
        let logos = EPGFormat.logos(ofResponse: SyntheticEPG.logoFile())
        #expect(Array(logos.keys) == [0x3333])
        #expect(logos[0x3333]?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true)
    }

    @Test("版数表 → EPGGet（application/binary・トークン付き）→ セクション")
    func fetch() async throws {
        let http = MockHTTP()
        let services = [EPGServiceRef(networkID: Int(SyntheticEPG.networkID), transportStreamID: Int(SyntheticEPG.transportStreamID),
                                      serviceID: Int(SyntheticEPG.serviceID))]
        http.reply("/status/EPGVersionInfoGet", body: SyntheticEPG.versionTable(services))
        http.reply("/chEpg/EPGGet", method: "POST", body: SyntheticEPG.wrap(SyntheticEPG.plaintext()))
        let guide = WebAPIProgramGuideService(transport: WebAPITransport(host: NasneFixture.host, client: http),
                                        tokens: TokenProvider(pin: "58daf0"))
        let result = try await guide.fetch()
        #expect(result.serviceCount == 1)
        #expect(result.sections.count == 2)
        let request = try #require(http.sentRequests.last)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/binary")
        let body = request.httpBody ?? Data()
        #expect(body == EPGFormat.requestBody(services: services))
        #expect(request.value(forHTTPHeaderField: "X-DTVToken")
            == TokenProvider.computeToken(pin: "58daf0", path: "/chEpg/EPGGet", body: body))
    }

    @Test("取ったセクションを mirne の EPGStore に入れて読み戻せる")
    func savesIntoEPGStore() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mirne-mobile-epg-\(UUID().uuidString)")
            .appendingPathComponent("epg.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try EPGStore(fileURL: url)
        let (sections, _) = EPGFormat.sections(inPlaintext: SyntheticEPG.plaintext())
        let start = Date(timeIntervalSince1970: 1_794_790_500)
        // EPGStore は受け取った時刻から 1 日より前に終わった番組を消すので、受け取った時刻を番組の日にする
        store.save(sections, receivedAt: start)
        await store.flushed()
        let events = store.events(networkID: Int(SyntheticEPG.networkID), transportStreamID: Int(SyntheticEPG.transportStreamID),
                                  serviceID: Int(SyntheticEPG.serviceID), overlapping: start..<start.addingTimeInterval(3600))
        #expect(events.map(\.title) == ["テレビ"])
    }
}

@Suite("放送の文字と日時")
struct BroadcastTextTests {
    @Test("PUA と囲み文字の番組マークを角括弧にする。表に無い PUA はそのまま")
    func normalizes() {
        #expect(BroadcastText.normalize("手話ニュース\u{E0FD}\u{E0FE}") == "手話ニュース[手][字]")
        #expect(BroadcastText.normalize("ニュース🈑") == "ニュース[字]")
        #expect(BroadcastText.normalize("番組🈟🈞") == "番組[新][再]")
        #expect(BroadcastText.normalize("x\u{E000}") == "x\u{E000}")
        #expect(BroadcastText.normalize("ふつうの番組") == "ふつうの番組")
        // ㊙ と ⁉ は PUA で届くが、角括弧にせず番組表の経路と同じ通常の文字にする（plan.md §56.3）
        #expect(BroadcastText.normalize("ジュワーッ\u{E19B}ギョウザ・どこ\u{E2F0}") == "ジュワーッ㊙ギョウザ・どこ⁉")
    }

    @Test("番組表から読んだ番組は、字形の無い囲み文字だけを角括弧にする（字形の無い 🅍 が「?」で出ていた）")
    func normalizesGuideSchedule() {
        let event = BroadcastEvent(tableID: 0x50, serviceID: 1, eventID: 2, start: nil, duration: nil,
                                   title: "架空の音楽番組🅍🈑", text: "説明🈓", lossless: true)
        let source = EPGStore.ServiceSchedule(coverage: nil, events: [event])
        // 🈑 だけ字形があるとみなす
        let schedule = source.normalizingBroadcastMarks(keepsEnclosed: { $0 == "🈑" })
        #expect(schedule.events.map(\.title) == ["架空の音楽番組[SS]🈑"])
        #expect(schedule.events.map(\.text) == ["説明[デ]"])
        // PUA はいつも角括弧にする
        #expect(BroadcastText.normalize("x\u{E0FE}🈑", keepsEnclosed: { _ in true }) == "x[字]🈑")
    }

    @Test("字形の有無を Mac のフォントで調べる（🅍 は無く、🈑 はある）")
    func glyphAvailability() {
        #expect(!GlyphAvailability.hasGlyph("\u{1F14D}"))
        #expect(GlyphAvailability.hasGlyph("\u{1F211}"))
    }

    @Test("受け取りは +0900 も +09:00 も読み、送りは +09:00 の日本時間で書く")
    func dateTimes() throws {
        let compact = try #require(NasneDateTime.parse("2026-11-16T11:34:46+0900"))
        let colon = try #require(NasneDateTime.parse("2026-11-16T11:34:46+09:00"))
        #expect(compact == colon)
        #expect(NasneDateTime.format(compact) == "2026-11-16T11:34:46+09:00")
        #expect(NasneDateTime.format(Date(timeIntervalSince1970: 0)) == "1970-01-01T09:00:00+09:00")
        #expect(NasneDateTime.parse("あ") == nil)
    }
}
