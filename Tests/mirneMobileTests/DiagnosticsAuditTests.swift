import Foundation
import Synchronization
import Testing

// 「秘密を出さない」監査。
//
// ログに出してよいのは段の遷移・応答コード・バイト数・所要時間・AKE のフレームヘッダまで。
// 資格情報・セッション鍵・ノンス・署名・MAC アドレス・PIN・トークン・アドレス（IP・URL）は出さない。
// - 実行時：登録・届かないとき・SOAP・再生の失敗を流し、書かれたログに秘密の値が無いことを確かめる
// - 静的：Sources のログの呼び出しに、秘密に当たる変数を補間していないことを確かめる
// DTCPKit の AKE の監査（鍵・ノンス・署名）は `DTCPDiagnosticsAuditTests`（AKETests.swift）

/// NasneKit の診断ログを受け取る
private final class NasneLogCapture: Sendable {
    private let storage = Mutex<[String]>([])
    var lines: [String] { storage.withLock { $0 } }
    var diagnostics: NasneDiagnostics {
        NasneDiagnostics { category, message in
            self.storage.withLock { $0.append("[\(category.rawValue)] \(message)") }
        }
    }
}

/// 必ず「届かない」で失敗する HTTP。誤りに URL（アドレスとパラメータ）を入れる（URLSession と同じ形）
private struct UnreachableHTTP: HTTPExchanging {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var info: [String: Any] = [:]
        if let url = request.url {
            info[NSURLErrorFailingURLErrorKey] = url
            info[NSURLErrorFailingURLStringErrorKey] = url.absoluteString
        }
        throw URLError(.timedOut, userInfo: info)
    }
}

/// 秘密の値（試験の素材の MAC アドレス `00:11:22:33:44:55` から導くもの）
private enum Secrets {
    static let macAddress = "00:11:22:33:44:55"
    static let pin = "334455"
    /// 素材の MAC アドレスで `/config/PINVerify` に付くトークン（値を直書きせず計算する。漏れ検査が鍵の形として止めるため）
    static var token: String { TokenProvider.computeToken(pin: pin, path: NasneProfiles.standard.webAPI.pinVerify.path, body: Data()) }

    static var all: [String] {
        [macAddress, macAddress.replacingOccurrences(of: ":", with: ""), macAddress.uppercased(), pin, token,
         NasneFixture.host]
    }

    static func findings(in lines: [String], extra: [String] = []) -> [String] {
        lines.filter { line in (all + extra).contains { line.contains($0) } }
    }
}

@Suite("秘密を出さない監査（実行時）")
struct DiagnosticsRuntimeAuditTests {
    @Test("登録：段の遷移と応答コードは記録し、MAC アドレス・PIN・トークン・アドレスは記録しない")
    func registration() async throws {
        let log = NasneLogCapture()
        let http = MockHTTP()
        http.reply("/status/networkIfInfoGet", body: NasneFixture.data("webapi/status_networkIfInfoGet.json"))
        http.reply("/config/PINVerify", method: "POST", body: Data(#"{"errorcode": 0}"#.utf8))
        let registration = try await WebAPIRegistrationService(client: http, diagnostics: log.diagnostics)
            .register(NasneDevice.direct(host: NasneFixture.host))
        #expect(registration.macAddress == Secrets.macAddress)
        #expect(log.lines.contains { $0.contains("GET /status/networkIfInfoGet → 200") })
        #expect(log.lines.contains { $0.contains("POST /config/PINVerify → 200") })
        #expect(log.lines.contains { $0.contains("PINVerify が通った") })
        #expect(Secrets.findings(in: log.lines).isEmpty, "秘密の値がログに出た: \(log.lines)")
    }

    @Test("届かないとき：誤りの URL（アドレスとパラメータ）を記録しない")
    func unreachable() async throws {
        let log = NasneLogCapture()
        let transport = WebAPITransport(host: NasneFixture.host, client: UnreachableHTTP(), diagnostics: log.diagnostics)
        await #expect(throws: NasneError.self) {
            _ = try await transport.getJSON(NasneProfiles.standard.webAPI.boxNameGet, parameters: ["secretParameter": "secret-value"])
        }
        let tokened = transport.authenticated(with: TokenProvider(pin: Secrets.pin))
        await #expect(throws: NasneError.self) { _ = try await tokened.postJSON(NasneProfiles.standard.webAPI.pinVerify) }
        #expect(log.lines.count == WebAPITransport.getAttempts + 1)
        #expect(log.lines.allSatisfy { $0.contains("届かない（URLError") })
        #expect(Secrets.findings(in: log.lines, extra: ["secret-value", "secretParameter"]).isEmpty,
                "アドレス・パラメータがログに出た: \(log.lines)")
    }

    @Test("SOAP：アクション名と応答コードは記録し、引数とアドレスは記録しない")
    func soap() async throws {
        let log = NasneLogCapture()
        let http = MockHTTP()
        let control = NasneDevice.url(host: NasneFixture.host, port: 58888, path: "/control")
        http.reply("/control", method: "POST", status: 500, body: Data("""
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><detail>\
            <UPnPError><errorCode>701</errorCode><errorDescription>No such object</errorDescription></UPnPError>\
            </detail></s:Fault></s:Body></s:Envelope>
            """.utf8))
        let soap = SOAPTransport(client: http, diagnostics: log.diagnostics)
        await #expect(throws: NasneError.self) {
            _ = try await soap.call(controlURL: control, serviceType: "urn:test", action: "Browse",
                                    arguments: [("ObjectID", "secret-object")])
        }
        let failing = SOAPTransport(client: UnreachableHTTP(), diagnostics: log.diagnostics)
        await #expect(throws: NasneError.self) {
            _ = try await failing.call(controlURL: control, serviceType: "urn:test", action: "Browse")
        }
        #expect(log.lines.contains { $0.contains("Browse → 500") })
        #expect(log.lines.contains { $0.contains("Fault（errorCode 701）") })
        #expect(Secrets.findings(in: log.lines, extra: ["secret-object", "No such object"]).isEmpty,
                "引数・アドレスがログに出た: \(log.lines)")
    }

    @Test("再生：段の遷移と失敗の分類は記録し、配信の URL とアドレスは記録しない")
    @MainActor
    func playback() async throws {
        let log = LogCapture()
        let http = MockHTTP()
        let store = DTCPMemoryCredentialStore(authorityKeys: testAuthority)
        try store.save(certificate: hexBytes(DTCPTestVectors.katSinkCert), privateKey: hexBytes(DTCPTestVectors.katSinkPriv))
        let items = try DIDLItem.parseDocument(NasneFixture.text("dlna/browse_0_video_all.xml"), source: "test")
        let resource = items[0].resources[0]
        let controller = PlaybackController(credentialStore: store, client: http, diagnostics: log.diagnostics)
        controller.play(resource, durationSeconds: 300, from: 0)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if case .failed = controller.state { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        controller.stop()
        let url = try #require(URL(string: resource.url))
        #expect(log.lines.contains { $0.contains("[playback] 再生を頼んだ") })
        #expect(log.lines.contains { $0.contains("[playback] 失敗（head の段") })
        let leaks = log.lines.filter { line in
            [resource.url, url.path, url.host ?? NasneFixture.host, NasneFixture.host].contains { line.contains($0) }
        }
        #expect(leaks.isEmpty, "URL・アドレスがログに出た: \(log.lines)")
    }
}

@Suite("秘密を出さない監査（静的）")
struct DiagnosticsStaticAuditTests {
    /// ログの呼び出しに補間してはいけない名前（`.count` を付けた長さは除く）。
    /// 秘密（資格情報・鍵・ノンス・署名・MAC・PIN・トークン）と、アドレス・URL・要求の中身・誤りの詳細（URL を含みうる）
    static let forbidden: Set<String> = [
        "pin", "token", "tokens", "macAddress", "macAddr", "mac", "password", "secret",
        "key", "keys", "exchangeKey", "contentKey", "authenticationKey", "privateKey", "nonce", "signature",
        "certificate", "credentials", "credential",
        "host", "address", "url", "URL", "location", "absoluteString", "query", "parameters", "form", "body",
        "request", "detail", "payload", "data", "bytes", "plain", "chunk",
    ]
    /// 誤りそのもの（`\(error)`）は URL を含みうるので、要約（`summary(`）を通したときだけよい
    static let errorNames: Set<String> = ["error", "cause"]

    /// 確かめたうえで認めた補間（ファイル → 式）。足すときは理由を書く
    static let reviewed: [String: Set<String>] = [
        // AKE の接続の誤り（Network の NWError と DTCPError）。URL は入らず、DTCPError の文面に秘密を入れないことは
        // DTCPDiagnosticsAuditTests が DTCPKit の全部の補間で確かめている
        "DTCPKit/AKEClient.swift": ["error"],
        // 番組表を保存できなかったときのファイルの誤り（mirne から写したもの）。nasne の秘密は入らない
        "SI/EPGStore.swift": ["error.localizedDescription, privacy: .public"],
        // H.264 の SPS の値（要求のパラメータではない。名前が同じだけ）
        "Player/H264Video.swift": ["parameters.frameMBsOnly, privacy: .public"],
    ]

    /// ログの呼び出しの始まり：os.Logger のメソッド・DTCPKit と NasneKit の診断ログ・PlaybackController の log
    static func callStart() throws -> Regex<AnyRegexOutput> {
        try Regex(#"(?:[A-Za-z]*[Ll]ogger(?:\([^)]*\))?\.(?:trace|debug|info|notice|warning|error|critical|fault|log)|\bdiagnostics(?:\.write)?|\blog)\("#)
    }

    @Test("Sources のログの呼び出しに、秘密・アドレス・要求の中身を補間していない")
    func noForbiddenInterpolationInLogCalls() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        // 計測コマンド（Probe）は利用者が手元で流して読むもので、アプリのログではないので除く（計測コマンドは番組名やアドレスを出さないように作る）
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") && !$0.hasPrefix("Probe/") }
        let start = try Self.callStart()
        var calls = 0
        var findings: [String] = []
        for file in files {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for match in text.matches(of: start) {
                let call = Self.balancedCall(in: text, from: match.range.upperBound)
                calls += 1
                for expression in Self.interpolations(in: call)
                where !Self.isAllowed(expression) && Self.reviewed[file]?.contains(expression) != true {
                    findings.append("\(file): \\(\(expression))")
                }
            }
        }
        // 監査が空振りしていない（ログの呼び出しを十分な数だけ読めた）
        #expect(calls > 40, "ログの呼び出しが \(calls) 個しか見つからない")
        #expect(findings.isEmpty, "ログに補間してはいけないもの: \(findings)")
    }

    @Test("静的な監査そのものの見分け")
    func detectsForbiddenInterpolation() {
        #expect(!Self.isAllowed("registration.macAddress"))
        #expect(!Self.isAllowed("request.url"))
        #expect(!Self.isAllowed("error"))
        #expect(Self.isAllowed("NasneDiagnostics.summary(error)"))
        #expect(Self.isAllowed("data.count"))
        #expect(Self.isAllowed("response.statusCode"))
        let call = Self.balancedCall(in: #"("段：\(stage.rawValue)・\(token)") + 1"#, from: #"(""#.endIndex)
        #expect(Self.interpolations(in: call) == ["stage.rawValue", "token"])
    }

    /// 補間の式がよいか
    static func isAllowed(_ expression: String) -> Bool {
        let names = expression.matches(of: /[A-Za-z_][A-Za-z0-9_]*/).map { String($0.output) }
        for (index, name) in names.enumerated() {
            let next = index + 1 < names.count ? names[index + 1] : ""
            if forbidden.contains(name), next != "count" { return false }
            if errorNames.contains(name), !expression.contains("summary(") { return false }
        }
        return true
    }

    /// `(` の直後から、対応する `)` までの文字列（呼び出しの引数）
    static func balancedCall(in text: String, from start: String.Index) -> String {
        var depth = 1
        var index = start
        while index < text.endIndex, depth > 0 {
            switch text[index] {
            case "(": depth += 1
            case ")": depth -= 1
            default: break
            }
            index = text.index(after: index)
        }
        return String(text[start..<index])
    }

    /// 文字列の補間 `\( … )` の中の式
    static func interpolations(in text: String) -> [String] {
        var result: [String] = []
        var search = text.startIndex
        while let open = text.range(of: #"\("#, range: search..<text.endIndex) {
            let inner = balancedCall(in: text, from: open.upperBound)
            result.append(String(inner.dropLast()))
            search = text.index(open.upperBound, offsetBy: inner.count, limitedBy: text.endIndex) ?? text.endIndex
        }
        return result
    }
}
