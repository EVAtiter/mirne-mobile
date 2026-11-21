// torne mobile HB（MIT、© mar1mo-41414）の lib/core/transport/soap_transport.dart を Swift へ移植したもの。

import Foundation

/// SOAP のアクションが返した出力の引数（名前 → 文字。実体参照は解いたあと）
public struct SOAPResponse: Sendable {
    public let values: [String: String]

    /// `Result`（xsrs・DIDL の文書の文字列）
    public var result: String? { values["Result"] }
    /// `NumberReturned`（この応答に入っている件数）
    public var numberReturned: Int? { values["NumberReturned"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
    /// `TotalMatches`（全体の件数）
    public var totalMatches: Int? { values["TotalMatches"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
}

/// UPnP SOAP の転送層。
///
/// 封筒は文字列のひな形で組み立て、引数の値は必ずエスケープする（xsrs の `Elements` のように
/// 値そのものが XML の文書でも、エスケープした文字として送るのが nasne の期待する形。plan.md §12.3）。
/// 応答は 2 段で読む：ここで封筒を開いて出力の引数を返し、`Result` は呼び出し側が xsrs・DIDL として読み直す。
public struct SOAPTransport: Sendable {
    // SOAP 1.1 の封筒の決まり（機器で変わらない。機器ごとの名前は `SOAPTable` が持つ）
    static let envelopeNamespace = "http://schemas.xmlsoap.org/soap/envelope/"
    static let encodingStyle = "http://schemas.xmlsoap.org/soap/encoding/"
    static let schemaNamespace = "http://www.w3.org/2001/XMLSchema"
    static let schemaInstanceNamespace = "http://www.w3.org/2001/XMLSchema-instance"
    static let contentType = "text/xml; charset=\"utf-8\""
    static let contentTypeHeader = "Content-Type"
    static let actionHeader = "SOAPAction"

    private let client: any HTTPExchanging
    /// 診断ログ（アクション名・応答コード・バイト数・所要時間だけ。引数・アドレスは出さない）
    private let diagnostics: NasneDiagnostics

    public init(client: any HTTPExchanging, diagnostics: NasneDiagnostics = .osLog) {
        self.client = client
        self.diagnostics = diagnostics
    }

    /// `controlURL` のサービスの `action` を呼ぶ。`arguments` は順番どおりに並べる
    public func call(controlURL: URL, serviceType: String, action: String,
                     arguments: [(String, String)] = []) async throws -> SOAPResponse {
        let source = "soap:\(action)"
        let inner = arguments.map { "<\($0.0)>\(XMLTree.escapeText($0.1))</\($0.0)>" }.joined()
        let envelope = """
            <?xml version="1.0" encoding="UTF-8"?>\
            <soapenv:Envelope xmlns:soapenv="\(Self.envelopeNamespace)" \
            xmlns:xsd="\(Self.schemaNamespace)" \
            xmlns:xsi="\(Self.schemaInstanceNamespace)">\
            <soapenv:Body>\
            <u:\(action) soapenv:encodingStyle="\(Self.encodingStyle)" \
            xmlns:u="\(serviceType)">\(inner)</u:\(action)>\
            </soapenv:Body></soapenv:Envelope>
            """
        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.setValue(Self.contentType, forHTTPHeaderField: Self.contentTypeHeader)
        request.setValue("\"\(serviceType)#\(action)\"", forHTTPHeaderField: Self.actionHeader)
        request.httpBody = Data(envelope.utf8)

        let data: Data
        let response: HTTPURLResponse
        let started = ContinuousClock.now
        do {
            (data, response) = try await client.send(request)
        } catch {
            diagnostics(.soap, "\(action) → 届かない（\(NasneDiagnostics.summary(error))）")
            throw NasneError.unreachable(source, cause: error)
        }
        diagnostics(.soap, "\(action) → \(response.statusCode)・\(data.count) バイト・\(started.elapsedMilliseconds) ms")

        let root: XMLTreeElement
        do {
            root = try XMLTree.parse(data, source: source)
        } catch {
            if response.statusCode != 200 { throw NasneError.http(response.statusCode, source) }
            throw error
        }
        if let fault = root.firstDescendant(named: "Fault") {
            let code = fault.firstDescendant(named: "errorCode")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let description = fault.firstDescendant(named: "errorDescription")?.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            diagnostics(.soap, "\(action) → Fault（errorCode \(code.isEmpty ? "なし" : code)）")
            throw NasneError.soapFault(errorCode: code.isEmpty ? String(response.statusCode) : code,
                                       errorDescription: description, source: source)
        }
        guard response.statusCode == 200 else { throw NasneError.http(response.statusCode, source) }
        guard let body = root.firstDescendant(named: "\(action)Response") else {
            throw NasneError.parse(source, "\(action)Response の要素が無い")
        }
        var values: [String: String] = [:]
        for child in body.children {
            values[child.name] = child.text
        }
        return SOAPResponse(values: values)
    }
}
