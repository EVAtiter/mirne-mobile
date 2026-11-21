import Foundation
import Testing

// ライブの局の一覧と、DLNA の contentFeatures の読み方（シークの下調べ）。
// ライブの素材は torne mobile HB の test/fixtures/dlna/browse_0_video_LiveTuner*.xml を写し、
// 局名・nid / tsid / sid・channelNr を 架空の値に置き換えたもの。

@Suite("ライブの局の一覧")
struct LiveCatalogTests {
    /// 空の DIDL-Lite の文書
    static let emptyDIDL = #"<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"></DIDL-Lite>"#

    /// 要求の本文の ObjectID
    static func objectID(_ request: URLRequest) -> String {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        guard let range = body.range(of: #"(?<=<ObjectID>)[^<]+"#, options: .regularExpression) else { return "" }
        return String(body[range])
    }

    static func envelope(_ didl: String, returned: Int) -> Data {
        Data("""
            <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
            <u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">\
            <Result>\(XMLTree.escapeText(didl))</Result>\
            <NumberReturned>\(returned)</NumberReturned><TotalMatches>\(returned)</TotalMatches>\
            </u:BrowseResponse></s:Body></s:Envelope>
            """.utf8)
    }

    @Test("根の container 3 つ（地上・BS・CS）を読み、帯域ごとに局を Browse する")
    func readsBands() async throws {
        let http = MockHTTP()
        http.respond("/MediaServer_ContentDirectory/control", method: "POST") { request in
            switch Self.objectID(request) {
            case NasneProfiles.standard.dlna.liveTunerContainer:
                return .init(status: 200, body: Self.envelope(NasneFixture.text("dlna/browse_0_video_LiveTuner.xml"), returned: 3))
            case "0/video/LiveTuner/DTTB":
                return .init(status: 200, body: Self.envelope(NasneFixture.text("dlna/browse_0_video_LiveTuner_DTTB.xml"), returned: 2))
            default:
                return .init(status: 200, body: Self.envelope(Self.emptyDIDL, returned: 0))
            }
        }
        let catalog = RecordingCatalogService(soap: SOAPTransport(client: http), device: NasneDevice.direct(host: NasneFixture.host))
        let bands = try await DLNALiveCatalogService(catalog: catalog).bands()
        #expect(bands.map(\.containerID) == ["0/video/LiveTuner/DTTB", "0/video/LiveTuner/BS", "0/video/LiveTuner/CS"])
        #expect(bands.map(\.title) == ["地上デジタル", "ＢＳデジタル", "１１０度ＣＳ"])
        #expect(bands[1].channels.isEmpty && bands[2].channels.isEmpty)
        let channels = bands[0].channels
        #expect(channels.count == 2)
        let first = try #require(channels.first)
        #expect(first.bandID == "0/video/LiveTuner/DTTB")
        #expect(first.networkID == 0x7E01 && first.transportStreamID == 0x7E01 && first.serviceID == 0x4000)
        #expect(channels[1].serviceID == 0x4001)
        #expect(first.channelName == "テスト局1")
        #expect(first.channelNumber == 10010)
        #expect(first.programStart != nil && first.programEnd != nil)
        #expect(first.programEnd!.timeIntervalSince(first.programStart!) == 45 * 60)
        #expect(first.resources.map(\.quality) == ["dr", "x3", "mobile"])
        #expect(first.originalResource?.quality == "dr")
        #expect(first.resources.allSatisfy { URL(string: $0.url)?.path == "/web/video/ch" && $0.dtcpPort != nil })
        // Browse は 4 回（根と 3 つの帯域）。ライブの res には何も送らない
        #expect(http.sentRequests.map(Self.objectID)
                == [NasneProfiles.standard.dlna.liveTunerContainer, "0/video/LiveTuner/DTTB", "0/video/LiveTuner/BS", "0/video/LiveTuner/CS"])
    }

    @Test("DIDL の container と item を文書の順に読む。録画の browse は item だけを返す")
    func entriesKeepOrder() throws {
        let entries = try DIDLEntry.parseDocument(NasneFixture.text("dlna/browse_0_video_LiveTuner.xml"), source: "test")
        #expect(entries.count == 3)
        guard case .container(let container) = entries[0] else {
            Issue.record("container でない")
            return
        }
        #expect(container.parentID == NasneProfiles.standard.dlna.liveTunerContainer)
        #expect(container.childCount == nil)
        #expect(try DIDLItem.parseDocument(NasneFixture.text("dlna/browse_0_video_LiveTuner.xml"), source: "test").isEmpty)
        #expect(try DIDLItem.parseDocument(NasneFixture.text("dlna/browse_0_video_all.xml"), source: "test").count == 2)
    }
}

@Suite("DLNA の contentFeatures")
struct DLNAContentFeaturesTests {
    @Test("OP の 2 桁を時間指定とバイト範囲に分ける")
    func operations() {
        let timeOnly = DLNAContentFeatures("DLNA.ORG_PN=DTCP_MPEG_TS_JP_T;DLNA.ORG_OP=10;DLNA.ORG_CI=0")
        #expect(timeOnly.profile == "DTCP_MPEG_TS_JP_T")
        #expect(timeOnly.supportsTimeSeek == true)
        #expect(timeOnly.supportsByteRange == false)
        #expect(timeOnly.fields[DLNAContentFeatures.conversionField] == "0")
        let both = DLNAContentFeatures("DLNA.ORG_OP=11")
        #expect(both.supportsTimeSeek == true && both.supportsByteRange == true)
        let none = DLNAContentFeatures("DLNA.ORG_PN=X")
        #expect(none.supportsTimeSeek == nil && none.supportsByteRange == nil)
    }

    @Test("FLAGS の先頭 8 桁を主なフラグとして読む（素材の 0111 は tm-s・dlna-v1.5・link-protected）")
    func flags() {
        let live = DLNAContentFeatures("DLNA.ORG_PN=DTCP_MPEG_TS_JP_T;DLNA.ORG_FLAGS=01110000000000000000000000000000")
        #expect(live.flags == [.streamingTransfer, .dlnaV15, .linkProtected])
        let seekable = DLNAContentFeatures("DLNA.ORG_FLAGS=8D100000000000000000000000000000")
        #expect(seekable.flags == [.senderPaced, .s0Increasing, .sNIncreasing, .streamingTransfer, .dlnaV15])
        #expect(DLNAContentFeatures("DLNA.ORG_FLAGS=xyz").flags == nil)
        #expect(DLNAContentFeatures("").flags == nil)
    }

    @Test("素材の res の protocolInfo の 4 番目のフィールドを読める")
    func fromProtocolInfo() throws {
        let items = try DIDLItem.parseDocument(NasneFixture.text("dlna/browse_0_video_LiveTuner_DTTB.xml"), source: "test")
        let resource = try #require(items.first?.resources.first)
        let fourth = resource.protocolInfo.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let features = DLNAContentFeatures(fourth)
        #expect(features.profile == "DTCP_MPEG_TS_JP_T")
        #expect(features.fields["ARIB.OR.JP_PN"] == "MPEG_TTS_CP")
        #expect(features.flags?.contains(.linkProtected) == true)
    }
}
