// DTCP-IP で保護された録画・ライブの配信 URL への HEAD と GET の作法。
//
// 出典: torne mobile HB（MIT、© mar1mo-41414）の lib/core/dtcp/dtcp_proxy.dart の DtcpMediaFetcher
// （akeEndpoint・_parseContentType・_applyHeaders）。
// HEAD の Content-Type のパラメータ（DTCP1HOST / DTCP1PORT）が AKE の相手。名前は大文字小文字を区別しない
// （torne mobile HB のビルド 6 は、小文字に直された名前を大文字で引いて全部失敗した。plan.md §28）。

import Foundation

/// 配信 URL への HEAD の結果（AKE の相手と、シークの申告）
struct DTCPContentEndpoint: Sendable, Equatable {
    /// AKE の相手のホスト
    let akeHost: String
    /// AKE の相手のポート（要求のたびに変わる。plan.md §11.8）
    let akePort: UInt16
    /// `contentFeatures.dlna.org` の値（`DLNA.ORG_OP` などシークの申告。無ければ nil）
    let contentFeatures: String?
}

enum DTCPContentHTTP {
    /// DTCP-IP の配信の media type
    static let mediaType = "application/x-dtcp1"
    /// HEAD・GET に付ける見出し（torne mobile HB と同じ）
    static let requestHeaders: [(String, String)] = [
        ("transferMode.dlna.org", "Streaming"),
        ("getcontentFeatures.dlna.org", "1"),
        ("Accept-Encoding", "identity"),
    ]
    /// 応答の見出しのうち、シークの申告
    static let contentFeaturesHeader = "contentFeatures.dlna.org"

    /// 見出しを付けた要求
    static func request(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in requestHeaders { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// Content-Type を media type（小文字）とパラメータ（名前は小文字・値の引用符は外す）に分ける
    static func parseContentType(_ value: String) -> (mediaType: String, parameters: [String: String]) {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
        let mediaType = (parts.first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        var parameters: [String: String] = [:]
        for part in parts.dropFirst() {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let name = part[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            parameters[name] = value
        }
        return (mediaType, parameters)
    }

    /// HEAD を送り、AKE の相手を返す。200 でない・DTCP-IP の media type でない・相手が無いときは誤り
    static func endpoint(of url: URL, client: any HTTPExchanging) async throws -> DTCPContentEndpoint {
        let response: HTTPURLResponse
        do {
            (_, response) = try await client.send(request(url, method: "HEAD"))
        } catch {
            throw DTCPError.unreachable("dtcp:http", "HEAD failed: \(error)")
        }
        guard response.statusCode == 200 else {
            throw DTCPError(.unreachable, "dtcp:http", "HEAD returned HTTP \(response.statusCode)",
                            code: String(response.statusCode))
        }
        let (mediaType, parameters) = parseContentType(response.value(forHTTPHeaderField: "Content-Type") ?? "")
        guard mediaType == Self.mediaType else {
            throw DTCPError.parse("dtcp:http", "unexpected content media type: \(mediaType)")
        }
        guard let host = parameters["dtcp1host"], !host.isEmpty,
              let port = parameters["dtcp1port"].flatMap({ UInt16($0) }), port > 0 else {
            throw DTCPError.parse("dtcp:http", "the content response carries no DTCP endpoint")
        }
        return DTCPContentEndpoint(akeHost: host, akePort: port,
                                   contentFeatures: response.value(forHTTPHeaderField: contentFeaturesHeader))
    }
}
