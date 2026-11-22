// torne mobile HB（MIT、© mar1mo-41414）の lib/core/transport/webapi_transport.dart を Swift へ移植したもの。

import Foundation

/// WebAPI（ポート 64210）の転送層。
///
/// GET は認証なしで、届かないときだけ控えめに再試行する。POST は再試行しない（二重の書き込みを防ぐ）。
/// トークンが要るエンドポイントには、渡された `TokenProvider` で X-DTVToken を付ける。
/// 誤りはここで `NasneError` に変える。
public struct WebAPITransport: Sendable {
    /// GET の試行回数（届かないときだけ繰り返す）
    static let getAttempts = 3
    /// GET の再試行の間隔
    static let getRetryDelay: Duration = .milliseconds(250)
    /// フォームの本文の Content-Type（HTTP の決まり。機器で変わらない）
    static let formContentType = "application/x-www-form-urlencoded"
    static let contentTypeHeader = "Content-Type"

    public let host: String
    /// 頼み方の表（ポートとエンドポイント。呼び出し側はここからエンドポイントを引く）
    public let profile: NasneProfile
    private let client: any HTTPExchanging
    private let tokens: TokenProvider?
    /// 診断ログ（パス・応答コード・バイト数・所要時間だけ。パラメータ・本文・トークン・アドレスは出さない）
    private let diagnostics: NasneDiagnostics

    public init(host: String, client: any HTTPExchanging, tokens: TokenProvider? = nil,
                profile: NasneProfile = NasneProfiles.standard, diagnostics: NasneDiagnostics = .osLog) {
        self.host = host
        self.client = client
        self.tokens = tokens
        self.profile = profile
        self.diagnostics = diagnostics
    }

    /// エンドポイントの表
    public var endpoints: WebAPIEndpointTable { profile.webAPI }

    /// トークンを付けた写し
    public func authenticated(with tokens: TokenProvider) -> WebAPITransport {
        WebAPITransport(host: host, client: client, tokens: tokens, profile: profile, diagnostics: diagnostics)
    }

    func url(_ endpoint: WebAPIEndpoint, parameters: [String: String]) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        switch endpoint.port {
        case .webAPI: components.port = profile.ports.webAPI
        case .recordingWrite: components.port = profile.ports.recordingWrite
        }
        components.path = endpoint.path
        if !parameters.isEmpty {
            components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    private func checkParameters(_ endpoint: WebAPIEndpoint, _ parameters: [String: String]) throws {
        for name in endpoint.requiredParameters where parameters[name] == nil {
            throw NasneError.validation("webapi:\(endpoint.path)", "パラメータ \"\(name)\" が無い")
        }
    }

    /// GET で JSON のオブジェクトを得る
    public func getJSON(_ endpoint: WebAPIEndpoint, parameters: [String: String] = [:]) async throws -> JSONObject {
        try checkParameters(endpoint, parameters)
        let (data, response) = try await getWithRetry(endpoint, parameters: parameters)
        return try decodeJSON(endpoint, data: data, response: response)
    }

    /// GET でバイト列を得る（バイナリを返すエンドポイント）
    public func getBytes(_ endpoint: WebAPIEndpoint, parameters: [String: String] = [:]) async throws -> Data {
        try checkParameters(endpoint, parameters)
        let (data, response) = try await getWithRetry(endpoint, parameters: parameters)
        guard response.statusCode == 200 else { throw statusError(endpoint, data: data, response: response) }
        return data
    }

    /// POST（フォームの本文）で JSON のオブジェクトを得る
    public func postJSON(_ endpoint: WebAPIEndpoint, form: [String: String] = [:]) async throws -> JSONObject {
        try checkParameters(endpoint, form)
        var components = URLComponents()
        components.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let body = Data((components.percentEncodedQuery ?? "").utf8)
        var request = URLRequest(url: url(endpoint, parameters: [:]))
        request.httpMethod = "POST"
        request.setValue(Self.formContentType, forHTTPHeaderField: Self.contentTypeHeader)
        try attachToken(endpoint, body: body, to: &request)
        request.httpBody = body
        let (data, response) = try await sendOnce(request, endpoint)
        return try decodeJSON(endpoint, data: data, response: response)
    }

    /// POST（バイナリの本文）でバイト列を得る（`chEpg/EPGGet`）。Content-Type は表の値（`binaryContentType`）
    public func postBinary(_ endpoint: WebAPIEndpoint, body: Data) async throws -> Data {
        var request = URLRequest(url: url(endpoint, parameters: [:]))
        request.httpMethod = "POST"
        request.setValue(endpoints.binaryContentType, forHTTPHeaderField: Self.contentTypeHeader)
        try attachToken(endpoint, body: body, to: &request)
        request.httpBody = body
        let (data, response) = try await sendOnce(request, endpoint)
        guard response.statusCode == 200 else { throw statusError(endpoint, data: data, response: response) }
        return data
    }

    private func attachToken(_ endpoint: WebAPIEndpoint, body: Data, to request: inout URLRequest) throws {
        guard endpoint.requiresToken else { return }
        guard let tokens else {
            throw NasneError.validation("webapi:\(endpoint.path)", "トークンが要るのに TokenProvider が無い")
        }
        request.setValue(tokens.token(path: endpoint.path, body: body), forHTTPHeaderField: endpoints.tokenHeader)
    }

    private func getWithRetry(_ endpoint: WebAPIEndpoint, parameters: [String: String]) async throws -> (Data, HTTPURLResponse) {
        let request = URLRequest(url: url(endpoint, parameters: parameters))
        var attempt = 1
        while true {
            let started = ContinuousClock.now
            do {
                let (data, response) = try await client.send(request)
                logReply("GET", endpoint, response: response, data: data, started: started, attempt: attempt)
                return (data, response)
            } catch {
                diagnostics(.webapi, "GET \(endpoint.path) → 届かない（\(NasneDiagnostics.summary(error))・試行 \(attempt)/\(Self.getAttempts)）")
                if attempt >= Self.getAttempts || Task.isCancelled {
                    throw NasneError.unreachable("webapi:\(endpoint.path)", cause: error)
                }
                attempt += 1
                try await Task.sleep(for: Self.getRetryDelay)
            }
        }
    }

    private func sendOnce(_ request: URLRequest, _ endpoint: WebAPIEndpoint) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let started = ContinuousClock.now
        do {
            let (data, response) = try await client.send(request)
            logReply(method, endpoint, response: response, data: data, started: started, attempt: nil)
            return (data, response)
        } catch {
            diagnostics(.webapi, "\(method) \(endpoint.path) → 届かない（\(NasneDiagnostics.summary(error))）")
            throw NasneError.unreachable("webapi:\(endpoint.path)", cause: error)
        }
    }

    /// 応答の要約（方法・パス・HTTP の状態・バイト数・所要時間）
    private func logReply(_ method: String, _ endpoint: WebAPIEndpoint, response: HTTPURLResponse, data: Data,
                          started: ContinuousClock.Instant, attempt: Int?) {
        let retry = attempt.map { $0 > 1 ? "・試行 \($0)" : "" } ?? ""
        diagnostics(.webapi, "\(method) \(endpoint.path) → \(response.statusCode)・\(data.count) バイト・"
                    + "\(started.elapsedMilliseconds) ms\(retry)")
    }

    private func decodeJSON(_ endpoint: WebAPIEndpoint, data: Data, response: HTTPURLResponse) throws -> JSONObject {
        let source = "webapi:\(endpoint.path)"
        guard response.statusCode == 200 else { throw statusError(endpoint, data: data, response: response) }
        let object = try JSONObject(data: data, source: source)
        if let code = object.int("errorcode"), code != 0 {
            diagnostics(.webapi, "\(endpoint.path) → errorcode \(code)")
            throw NasneError.webapi(code, source)
        }
        return object
    }

    private func statusError(_ endpoint: WebAPIEndpoint, data: Data, response: HTTPURLResponse) -> NasneError {
        let source = "webapi:\(endpoint.path)"
        // JSON の errorcode があれば、そちらの方が詳しい
        if let object = try? JSONObject(data: data, source: source), let code = object.int("errorcode") {
            return NasneError.webapi(code, source)
        }
        if response.statusCode == 400 {
            // 実測（plan.md §11.5）：トークンの無い・正しくない POST は 400 で拒まれる
            return NasneError(category: .webapi, code: "400", source: source, messageKey: "error.webapi",
                              detail: "HTTP 400（パラメータの誤り、またはトークンが無い・正しくない）")
        }
        return NasneError.http(response.statusCode, source)
    }
}
