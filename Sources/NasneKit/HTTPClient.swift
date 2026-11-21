import Foundation
import Synchronization

/// HTTP の 1 往復。試験ではモックに差し替える。
public protocol HTTPExchanging: Sendable {
    /// 要求を送り、本文と応答を返す。届かなければ投げる（HTTP の状態が 200 でなくても投げない）
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// nasne と話す URLSession の設定。WebAPI・SOAP の往復（`URLSessionHTTPClient`）と、録画・ライブの本文の受信
/// （`HTTPChunkStream`）が、どちらもここで作る（受信だけがシステムのプロキシを通っていた。2026-11-21 に揃えた）。
///
/// nasne とのやり取りに Cookie・キャッシュ・資格情報の保管は要らないので、ephemeral の設定で作り、どれも使わない
public enum NasneSessionConfiguration {
    /// `timeout` は「データが届かない時間」の上限（`timeoutIntervalForRequest`）
    public static func make(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        // nasne は LAN の中にいるので、システムのプロキシを通さない
        configuration.connectionProxyDictionary = [:]
        return configuration
    }
}

/// URLSession による実装（設定は `NasneSessionConfiguration`）
public final class URLSessionHTTPClient: HTTPExchanging {
    private let session: URLSession

    public init(timeout: TimeInterval = URLSessionHTTPClient.defaultTimeout) {
        session = URLSession(configuration: NasneSessionConfiguration.make(timeout: timeout))
    }

    /// 1 回の要求の時間切れ（WebAPI の読み取りの既定。torne mobile HB と同じ 15 秒）
    public static let defaultTimeout: TimeInterval = 15

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// 届かない誤りの見分け（使っている途中で nasne に届かなくなったら探し直す）
public enum NasneReachability {
    /// URLSession の誤りのうち「相手に届かない」とみなすもの（取り消し・HTTP の誤りは含めない）
    static let unreachableCodes: Set<URLError.Code> = [
        .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed,
    ]

    /// 届かない誤りか（`NasneError` の unreachable と、上の URLError）
    public static func isUnreachable(_ error: any Error) -> Bool {
        if let error = error as? NasneError { return error.category == .unreachable }
        guard let error = error as? URLError else { return false }
        return unreachableCodes.contains(error.code)
    }
}

/// 中の部品に渡し、届かない誤りで失敗した頼みを知らせる HTTP の部品。
/// 知らせの受け手は組み立ての後で付ける（受け手の環境が、この部品を使う部品を持つため）
public final class ReachabilityReportingHTTPClient: HTTPExchanging {
    private let base: any HTTPExchanging
    private let handler = Mutex<(@Sendable () -> Void)?>(nil)

    public init(base: any HTTPExchanging) {
        self.base = base
    }

    /// 届かない誤りで失敗したときに呼ぶ（何度でも呼ぶ。間引くのは受け手）
    public func onUnreachable(_ handler: @escaping @Sendable () -> Void) {
        self.handler.withLock { $0 = handler }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await base.send(request)
        } catch {
            if NasneReachability.isUnreachable(error) {
                let handler = self.handler.withLock { $0 }
                handler?()
            }
            throw error
        }
    }
}
