import Foundation
import Network

// 偽の nasne（複数台の nasne の確かめ用。nasne には何も送らない）。
//
//   mirne-mobile-probe fake-nasne [--udn uuid:…] [--name <本体名>] [--model nasne|buffalo-nasne] [--mac <MAC>]
//
// この Mac の 58888（デバイス記述・ContentDirectory）・64210（WebAPI）・64230（SOAP）番で待ち受け、
// 単体試験の素材（Tests/mirneMobileTests/Fixtures）を返す。アプリの登録の画面で「アドレスで登録」に
// この Mac の LAN のアドレスを入れると、2 台目の nasne として登録できる（同じ LAN の iPhone・iPad からも）。
// SSDP には応えない（見つかった nasne の一覧には出ない）。番組表（EPG）・ライブ・再生・書き込みは対象外で、
// 素材の無い頼みは 404（WebAPI）か SOAP の Fault を返す。素材の中の nasne のアドレスは、頼みの Host のアドレスに置き換える。
// 出力は頼みの方法とパス（WebAPI）・アクションの名前（SOAP）・容器の ID（Browse）だけで、相手のアドレスは出さない。

enum FakeNasneCommand {
    /// 素材の置き場（このファイルからの相対）
    static let fixtureDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/mirneMobileTests/Fixtures", isDirectory: true)
    /// 素材の中の nasne のアドレス（文書用の範囲。頼みの Host に置き換える）
    static let fixtureHost = [192, 0, 2, 1].map(String.init).joined(separator: ".")
    /// 素材のデバイス記述の UDN・本体名・型番（引数で置き換える）
    static let fixtureUDN = "uuid:00000000-0000-1000-8000-001122334455"
    static let fixtureName = "<friendlyName>nasne</friendlyName>"
    static let fixtureModel = "<modelName>nasne</modelName>"
    /// 素材の MAC アドレス（`status_networkIfInfoGet.json`。文書用の値）
    static let fixtureMAC = "00:11:22:33:44:55"
    /// 既定の偽の値（実機の値と重ならない）
    static let defaultUDN = "uuid:fake-nasne-2"
    static let defaultName = "nasne"
    static let defaultMAC = "00:00:5e:00:53:02"

    /// 頼み方の表（アクションの名前・パス・引数の名前はここから引く）
    static let profile = NasneProfiles.standard
    /// SOAP のアクション → 素材
    static let soapFixtures: [String: String] = [
        profile.soap.getTitleList.name: "soap/title_list.xml",
        profile.soap.getRecordScheduleList.name: "soap/schedule_list_one.xml",
        profile.soap.getConflictList.name: "soap/conflict_ok.xml",
    ]

    struct Identity {
        var udn: String
        var name: String
        var model: String
        var mac: String
    }

    static func run() async throws {
        let model = option("--model") ?? NasneDevice.nasneModelName
        guard NasneDevice.nasneModelNames.contains(model) else { fail("--model は nasne か buffalo-nasne") }
        let identity = Identity(udn: option("--udn") ?? defaultUDN, name: option("--name") ?? defaultName,
                                model: model, mac: option("--mac") ?? defaultMAC)
        guard FileManager.default.fileExists(atPath: fixtureDirectory.path) else { fail("素材が見つからない: Tests/mirneMobileTests/Fixtures") }
        let ports = profile.ports
        let server = FakeNasneServer(identity: identity)
        try server.listen(port: ports.dms, handler: server.dms)
        try server.listen(port: ports.webAPI, handler: server.webAPI)
        try server.listen(port: ports.xsrs, handler: server.soap)
        say("偽の nasne を待ち受けている（\(ports.dms)・\(ports.webAPI)・\(ports.xsrs) 番）。アプリの「アドレスで登録」に、この Mac の LAN のアドレスを入れる。止めるときは Ctrl-C")
        say("本体名 \(identity.name)・型番 \(identity.model)")
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
}

/// 受けた頼み（最小限の HTTP/1.1）
struct FakeHTTPRequest {
    var method: String
    var path: String
    var query: [URLQueryItem]
    var headers: [String: String]
    var body: Data

    /// 頼みの Host のアドレス（ポートを除く）
    var host: String? {
        guard let value = headers["host"] else { return nil }
        if value.hasPrefix("["), let end = value.firstIndex(of: "]") { return String(value[value.index(after: value.startIndex)..<end]) }
        return value.split(separator: ":").first.map(String.init)
    }
}

/// 返す応答
struct FakeHTTPResponse {
    var status: Int
    var contentType: String
    var body: Data

    static func notFound() -> FakeHTTPResponse { FakeHTTPResponse(status: 404, contentType: "text/plain", body: Data("not found".utf8)) }
}

final class FakeNasneServer: @unchecked Sendable {
    let identity: FakeNasneCommand.Identity
    private var listeners: [NWListener] = []
    private let queue = DispatchQueue(label: "com.slack-kingdom.mirne-mobile.fake-nasne")

    init(identity: FakeNasneCommand.Identity) {
        self.identity = identity
    }

    func listen(port: Int, handler: @escaping @Sendable (FakeHTTPRequest) -> FakeHTTPResponse) throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(integerLiteral: UInt16(port)))
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            Self.receive(on: connection, buffer: Data(), handler: handler)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { fail("\(port) 番で待ち受けられない: \(error)") }
        }
        listener.start(queue: queue)
        listeners.append(listener)
    }

    // MARK: - 中身

    /// デバイス記述（`/`）と ContentDirectory の Browse
    func dms(_ request: FakeHTTPRequest) -> FakeHTTPResponse {
        if request.method == "GET", request.path == NasneDevice.descriptionRootPath {
            say("GET \(request.path)（デバイス記述）")
            var text = fixtureText("upnp_description.xml", host: request.host)
            text = text.replacingOccurrences(of: FakeNasneCommand.fixtureUDN, with: identity.udn)
            text = text.replacingOccurrences(of: FakeNasneCommand.fixtureName, with: "<friendlyName>\(XMLTree.escapeText(identity.name))</friendlyName>")
            text = text.replacingOccurrences(of: FakeNasneCommand.fixtureModel, with: "<modelName>\(identity.model)</modelName>")
            return FakeHTTPResponse(status: 200, contentType: "text/xml; charset=\"utf-8\"", body: Data(text.utf8))
        }
        if request.method == "POST", let objectID = Self.element(FakeNasneCommand.profile.soap.arguments.objectID, in: request.body) {
            // 素材の無い容器（共有フォルダーなど）は空の一覧にする
            let name = "dlna/browse_" + objectID.replacingOccurrences(of: "/", with: "_") + ".xml"
            let exists = FileManager.default.fileExists(atPath: FakeNasneCommand.fixtureDirectory.appendingPathComponent(name).path)
            say("Browse \(objectID)\(exists ? "" : "（素材なし・空）")")
            let didl = exists ? fixtureText(name, host: request.host) : Self.emptyDIDL
            return FakeHTTPResponse(status: 200, contentType: "text/xml; charset=\"utf-8\"", body: Self.browseEnvelope(didl))
        }
        say("\(request.method) \(request.path)（素材なし）")
        return .notFound()
    }

    /// WebAPI（`/status/boxNameGet` → `webapi/status_boxNameGet.json`。引数は `_<名前><値>` を足して探す）
    func webAPI(_ request: FakeHTTPRequest) -> FakeHTTPResponse {
        if request.method == "POST", request.path == FakeNasneCommand.profile.webAPI.pinVerify.path {
            say("POST \(request.path)（通す）")
            return FakeHTTPResponse(status: 200, contentType: "application/json", body: Data(#"{"errorcode": 0}"#.utf8))
        }
        let base = "webapi/" + request.path.dropFirst().replacingOccurrences(of: "/", with: "_")
        let withQuery = base + request.query.map { "_\($0.name)\($0.value ?? "")" }.joined()
        for name in [withQuery + ".json", base + ".json"]
        where FileManager.default.fileExists(atPath: FakeNasneCommand.fixtureDirectory.appendingPathComponent(name).path) {
            say("\(request.method) \(request.path)")
            var text = fixtureText(name, host: request.host)
            if name.hasSuffix("status_networkIfInfoGet.json") {
                text = text.replacingOccurrences(of: FakeNasneCommand.fixtureMAC, with: identity.mac)
            }
            return FakeHTTPResponse(status: 200, contentType: "application/json", body: Data(text.utf8))
        }
        say("\(request.method) \(request.path)（素材なし）")
        return .notFound()
    }

    /// SOAP（XSRS・X_PvrControl）
    func soap(_ request: FakeHTTPRequest) -> FakeHTTPResponse {
        let action = request.headers["soapaction"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            .split(separator: "#").last.map(String.init) ?? ""
        guard let name = FakeNasneCommand.soapFixtures[action] else {
            say("SOAP \(action)（素材なし）")
            return Self.soapFault()
        }
        say("SOAP \(action)")
        return FakeHTTPResponse(status: 200, contentType: "text/xml; charset=\"utf-8\"", body: Data(fixtureText(name, host: request.host).utf8))
    }

    private func fixtureText(_ name: String, host: String?) -> String {
        let data = (try? Data(contentsOf: FakeNasneCommand.fixtureDirectory.appendingPathComponent(name))) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        guard let host else { return text }
        return text.replacingOccurrences(of: FakeNasneCommand.fixtureHost, with: host)
    }

    private static let emptyDIDL = #"<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"></DIDL-Lite>"#

    /// Browse の応答（素材は DIDL だけなので、件数を数えて SOAP の封筒に入れる。1 頁で全部返す）
    private static func browseEnvelope(_ didl: String) -> Data {
        let count = didl.components(separatedBy: "<item ").count - 1 + didl.components(separatedBy: "<container ").count - 1
        let browse = FakeNasneCommand.profile.soap.browse
        return Data("""
            <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
            <u:\(browse.name)Response xmlns:u="\(browse.service.serviceType)">\
            <Result>\(XMLTree.escapeText(didl))</Result>\
            <NumberReturned>\(count)</NumberReturned><TotalMatches>\(count)</TotalMatches><UpdateID>1</UpdateID>\
            </u:\(browse.name)Response></s:Body></s:Envelope>
            """.utf8)
    }

    private static func soapFault() -> FakeHTTPResponse {
        let body = """
            <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><s:Fault><faultcode>s:Client</faultcode>\
            <faultstring>UPnPError</faultstring><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">\
            <errorCode>401</errorCode><errorDescription>Invalid Action</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>
            """
        return FakeHTTPResponse(status: 500, contentType: "text/xml; charset=\"utf-8\"", body: Data(body.utf8))
    }

    /// 本文の要素の文字（`<ObjectID>…</ObjectID>`）
    private static func element(_ name: String, in body: Data) -> String? {
        let text = String(decoding: body, as: UTF8.self)
        guard let start = text.range(of: "<\(name)>"), let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[start.upperBound..<end.lowerBound])
    }

    // MARK: - HTTP

    /// 見出しの終わり（と Content-Length の本文）まで受けてから応える。応えたら閉じる
    private static func receive(on connection: NWConnection, buffer: Data,
                                handler: @escaping @Sendable (FakeHTTPRequest) -> FakeHTTPResponse) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = parse(buffer) {
                respond(handler(request), on: connection)
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                receive(on: connection, buffer: buffer, handler: handler)
            }
        }
    }

    private static func parse(_ buffer: Data) -> FakeHTTPRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let body = buffer[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        let components = URLComponents(string: String(requestLine[1]))
        return FakeHTTPRequest(method: String(requestLine[0]), path: components?.path ?? String(requestLine[1]),
                               query: components?.queryItems ?? [], headers: headers, body: Data(body.prefix(length)))
    }

    private static func respond(_ response: FakeHTTPResponse, on connection: NWConnection) {
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.status)
        var data = Data("HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n".utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
