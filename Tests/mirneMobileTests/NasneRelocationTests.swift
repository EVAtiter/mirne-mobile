// nasne のアドレスの変化・ネットワークの切り替えへの追従。
// いつ確かめるか・ネットワークが変わったと見るか、届かない誤りの見分け、UDN で絞る SSDP の発見

import Foundation
import Synchronization
import Testing

@Suite("探し直しの決まり")
struct NasneRelocationPolicyTests {
    @Test("確かめている最中は、どのきっかけでも確かめない")
    func skipsWhileChecking() {
        for trigger in [NasneRelocationTrigger.launch, .networkChange, .requestFailed, .manual] {
            #expect(!NasneRelocationPolicy.shouldCheck(trigger, isChecking: true, sinceLastCheck: nil))
        }
    }

    @Test("起動・ネットワークの切り替え・探し直すのボタンは、前に確かめた時刻によらず確かめる")
    func checksExplicitTriggers() {
        for trigger in [NasneRelocationTrigger.launch, .networkChange, .manual] {
            #expect(NasneRelocationPolicy.shouldCheck(trigger, isChecking: false, sinceLastCheck: .seconds(1)))
        }
    }

    @Test("頼みが届かなかったときは、前に確かめてから 30 秒あける")
    func throttlesRequestFailures() {
        #expect(NasneRelocationPolicy.shouldCheck(.requestFailed, isChecking: false, sinceLastCheck: nil))
        #expect(!NasneRelocationPolicy.shouldCheck(.requestFailed, isChecking: false, sinceLastCheck: .seconds(29)))
        #expect(NasneRelocationPolicy.shouldCheck(.requestFailed, isChecking: false, sinceLastCheck: .seconds(30)))
    }

    @Test("ネットワーク：使える経路ができた・接続が変わったときだけ確かめる（最初の知らせと、経路が無いときは確かめない）")
    func detectsPathChanges() {
        let wifi = NetworkPathSnapshot(isSatisfied: true, interfaces: ["en0"])
        let wired = NetworkPathSnapshot(isSatisfied: true, interfaces: ["en7", "en0"])
        let none = NetworkPathSnapshot(isSatisfied: false, interfaces: [])
        #expect(!NasneRelocationPolicy.shouldCheckAfterPathUpdate(previous: nil, current: wifi))
        #expect(!NasneRelocationPolicy.shouldCheckAfterPathUpdate(previous: wifi, current: wifi))
        #expect(!NasneRelocationPolicy.shouldCheckAfterPathUpdate(previous: wifi, current: none))
        #expect(NasneRelocationPolicy.shouldCheckAfterPathUpdate(previous: none, current: wifi))
        #expect(NasneRelocationPolicy.shouldCheckAfterPathUpdate(previous: wifi, current: wired))
    }
}

@Suite("届かない誤り")
struct NasneReachabilityTests {
    @Test("相手に届かない URLError と NasneError の unreachable だけを数える")
    func classifiesErrors() {
        #expect(NasneReachability.isUnreachable(URLError(.timedOut)))
        #expect(NasneReachability.isUnreachable(URLError(.cannotConnectToHost)))
        #expect(NasneReachability.isUnreachable(URLError(.notConnectedToInternet)))
        #expect(NasneReachability.isUnreachable(NasneError.unreachable("test")))
        #expect(!NasneReachability.isUnreachable(URLError(.cancelled)))
        #expect(!NasneReachability.isUnreachable(URLError(.badServerResponse)))
        #expect(!NasneReachability.isUnreachable(CancellationError()))
    }

    /// 決まった誤りを投げる HTTP
    private struct FailingHTTP: HTTPExchanging {
        let error: any Error
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw error }
    }

    @Test("届かない誤りで失敗した頼みだけを知らせ、誤りはそのまま投げる")
    func reportsUnreachableRequests() async {
        let request = URLRequest(url: URL(string: "http://\(NasneFixture.host)/")!)
        let count = Mutex(0)
        let unreachable = ReachabilityReportingHTTPClient(base: FailingHTTP(error: URLError(.timedOut)))
        unreachable.onUnreachable { count.withLock { $0 += 1 } }
        await #expect(throws: URLError.self) { try await unreachable.send(request) }
        #expect(count.withLock { $0 } == 1)
        let cancelled = ReachabilityReportingHTTPClient(base: FailingHTTP(error: URLError(.cancelled)))
        cancelled.onUnreachable { count.withLock { $0 += 1 } }
        await #expect(throws: URLError.self) { try await cancelled.send(request) }
        #expect(count.withLock { $0 } == 1)
    }
}

@Suite("UDN で絞る発見")
struct RelocationDiscoveryTests {
    /// 素材の記述の UDN
    private let fixtureUDN = "uuid:00000000-0000-1000-8000-001122334455"

    @Test("知らせを待つ間、UDN の違う nasne は読み飛ばし、同じ nasne が見つかったところで返す")
    func skipsOtherNasne() async throws {
        let http = MockHTTP()
        let wanted = NasneFixture.text("upnp_description.xml")
        let other = wanted.replacingOccurrences(of: fixtureUDN, with: "uuid:00000000-0000-1000-8000-00aabbccddee")
        http.reply("/XD/wanted", body: Data(wanted.utf8))
        http.reply("/XD/other", body: Data(other.utf8))
        let base = "http://\(NasneFixture.host):\(NasneProfiles.standard.ports.dms)"
        let service = SSDPDiscoveryService(
            client: http, diagnostics: .none, search: { [] },
            listen: { _, known in known.contains("\(base)/XD/other") ? ["\(base)/XD/wanted"] : ["\(base)/XD/other"] },
            announcementDuration: 5)
        let devices = try await service.discover(udn: fixtureUDN)
        #expect(devices.count == 1)
        #expect(devices.first?.descriptionURL.path == "/XD/wanted")
        // UDN を指定しなければ、最初の nasne で返す（登録の前の発見は今までどおり）
        #expect(try await service.discover().first?.descriptionURL.path == "/XD/other")
    }

    @Test("M-SEARCH の応答でも UDN の違う nasne は返さない")
    func filtersSearchResponses() async throws {
        let http = MockHTTP()
        http.reply("/", body: NasneFixture.data("upnp_description.xml"))
        let location = "http://\(NasneFixture.host):\(NasneProfiles.standard.ports.dms)/"
        let response = SSDPTransport.parse(Data("HTTP/1.1 200 OK\r\nLOCATION: \(location)\r\n\r\n".utf8))!
        let service = SSDPDiscoveryService(client: http, diagnostics: .none, search: { [response] },
                                           listen: { _, _ in [] }, announcementDuration: 1)
        #expect(try await service.discover(udn: fixtureUDN).count == 1)
        #expect(try await service.discover(udn: "uuid:other").isEmpty)
    }
}
