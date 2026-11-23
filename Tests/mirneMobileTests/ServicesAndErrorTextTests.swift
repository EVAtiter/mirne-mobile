import Foundation
import Testing

// 領域のプロトコルと組み立て・誤りの変換表。

@Suite("誤りの変換表")
struct ErrorTextTests {
    @Test("NasneError の作り方ごとの鍵が、どれも表にある（既定の文言にならない）")
    func everyFactoryKeyHasText() {
        let errors: [NasneError] = [
            .unreachable("t"), .http(500, "t"), .http(404, "t"), .webapi(1, "t"),
            .soapFault(errorCode: "402", errorDescription: nil, source: "t"),
            .soapFault(errorCode: "803", errorDescription: nil, source: "t"),
            .soapFault(errorCode: "830", errorDescription: nil, source: "t"),
            .soapFault(errorCode: "836", errorDescription: nil, source: "t"),
            .soapFault(errorCode: "501", errorDescription: nil, source: "t"),
            .titleProtected(from: .soapFault(errorCode: "877", errorDescription: nil, source: "t")),
            .parse("t", "d"), .validation("t", "d"), .unsupported("t"),
        ]
        for error in errors {
            #expect(ErrorText.nasneMessages[error.messageKey] != nil, "\(error.messageKey) が表に無い")
            #expect(ErrorText.present(error).title != ErrorText.fallback.title)
        }
    }

    @Test("ソースに書かれた error.* の鍵が、どれも表にある（鍵を足して表を直し忘れるのを止める）")
    func everyKeyInSourcesHasText() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        var keys = Set<String>()
        let pattern = try NSRegularExpression(pattern: #""(error\.[A-Za-z.]+)""#)
        for file in files where file.lastPathComponent != "ErrorText.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                keys.insert(String(text[Range(match.range(at: 1), in: text)!]))
            }
        }
        #expect(!keys.isEmpty)
        for key in keys { #expect(ErrorText.nasneMessages[key] != nil, "\(key) が表に無い") }
    }

    @Test("元のコードを添え、もう一度試せるのは届かないときだけ。detail は画面に出さない")
    func codeRetryAndDetail() {
        let fault = ErrorText.present(NasneError.soapFault(errorCode: "803", errorDescription: "内部の説明", source: "soap:X"))
        #expect(fault.code == "803")
        #expect(!fault.canRetry)
        #expect(ErrorText.present(NasneError.http(404, "t")).title == ErrorText.nasneMessages["error.notImplemented"]!.title)
        #expect(ErrorText.present(NasneError.unreachable("t")).canRetry)
        // 403 は「この Mac を許可していない」（一覧・配信の GET と、配信の HEAD の DTCPError の両方）
        let allowed = ErrorText.nasneMessages["error.clientNotAllowed"]!.title
        #expect(ErrorText.present(NasneError.http(403, "t")).title == allowed)
        #expect(ErrorText.present(DTCPError(.unreachable, "dtcp:http", "HEAD returned HTTP 403", code: "403")).title == allowed)
        #expect(ErrorText.present(NasneError.http(500, "t")).title == ErrorText.nasneMessages["error.http"]!.title)
        let withDetail = ErrorText.present(NasneError.parse("t", "診断だけに出す詳細"))
        #expect(!withDetail.title.contains("診断だけに出す詳細") && !withDetail.message.contains("診断だけに出す詳細"))
    }

    @Test("DTCP-IP の誤り・AKE の切断・URLError・知らない誤りも文言になる")
    func otherErrors() {
        for category in [DTCPError.Category.validation, .parse, .unreachable] {
            let presented = ErrorText.present(DTCPError(category, "dtcp:t", "鍵の値を入れない詳細"))
            #expect(presented.title == ErrorText.dtcpMessages[category]!.title)
            #expect(!presented.message.contains("鍵の値を入れない詳細"))
            #expect(presented.canRetry == (category == .unreachable))
        }
        #expect(ErrorText.present(AKEConnectionClosed()).canRetry)
        let url = ErrorText.present(URLError(.timedOut))
        #expect(url.canRetry && url.code == String(URLError.Code.timedOut.rawValue))
        struct Unknown: Error {}
        #expect(ErrorText.present(Unknown()).title == ErrorText.fallback.title)
    }
}

@Suite("領域のプロトコルと組み立て")
struct ServicesCompositionTests {
    /// 試験用の本体の情報（プロトコルだけを満たす）
    struct FakeDeviceInfo: DeviceInfoService {
        func deviceInfo() async throws -> DeviceInfo { throw NasneError.unsupported("fake") }
        func hddList() async throws -> [HDDEntry] { [] }
        func hddInfo(id: Int) async throws -> HDDInfo { throw NasneError.unsupported("fake") }
        func channels(broadcastingType: Int) async throws -> [Channel] { [] }
        func liveStatus() async throws -> LiveStatus { throw NasneError.unsupported("fake") }
        func recNgList() async throws -> [RecNgItem] { [] }
        func titleCounts() async throws -> (count: Int, max: Int) { (7, 3000) }
    }

    @Test("実機の組み立てで、録画の一覧と予約はプロトコル越しに SOAP の中身へ届く")
    func liveComposition() async throws {
        let http = MockHTTP()
        http.reply("/XSRS", method: "POST", body: NasneFixture.data("soap/title_list.xml"))
        let registration = RegisteredNasne(host: NasneFixture.host, udn: "uuid:test", friendlyName: "test",
                                           macAddress: "00:00:5e:00:53:01")
        let services = try NasneServices.live(registration: registration, device: NasneDevice.direct(host: NasneFixture.host),
                                              client: http)
        let titles = try await services.titles.titles(withMetadata: false)
        #expect(titles.count == 2)
        #expect(services.titles is RecordingCatalogService)
        #expect(services.deviceInfo is WebAPIDeviceInfoService)
        #expect(services.liveCatalog is DLNALiveCatalogService)
    }

    @Test("試験では中身をモックに差し替えられる（画面はプロトコルだけを知る）")
    func substitution() async throws {
        let http = MockHTTP()
        let registration = RegisteredNasne(host: NasneFixture.host, udn: "uuid:test", friendlyName: "test",
                                           macAddress: "00:00:5e:00:53:01")
        let real = try NasneServices.live(registration: registration, device: NasneDevice.direct(host: NasneFixture.host),
                                          client: http)
        let services = NasneServices(registration: registration, deviceInfo: FakeDeviceInfo(), schedules: real.schedules,
                                     titles: real.titles, programGuide: real.programGuide, liveCatalog: real.liveCatalog,
                                     media: real.media, nasneHomeURL: real.nasneHomeURL)
        let counts = try await services.deviceInfo.titleCounts()
        #expect(counts.count == 7 && counts.max == 3000)
        #expect(http.sentRequests.isEmpty)
    }

    @Test("発見は SSDP を先に、走査を後に並べる")
    func setupOrder() {
        let setup = DeviceSetupServices.live(client: MockHTTP(), scanClient: MockHTTP())
        #expect(setup.discovery.count == 2)
        #expect(setup.discovery.first is SSDPDiscoveryService)
        #expect(setup.discovery.last is SubnetScanDiscoveryService)
    }
}
