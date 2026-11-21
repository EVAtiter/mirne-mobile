import Foundation
import Testing

// nasne と話す URLSession の設定（WebAPI・SOAP の往復と、録画・ライブの本文の受信で同じものを使う）。
// 受信だけが既定の設定でシステムのプロキシを通っていたので、1 か所で作るようにした（2026-11-21）

struct NasneSessionConfigurationTests {
    /// 設定が nasne 向けの形か（プロキシ・キャッシュ・Cookie・資格情報の保管を使わない）
    private func expectNasneShape(_ configuration: URLSessionConfiguration, timeout: TimeInterval) {
        #expect(configuration.timeoutIntervalForRequest == timeout)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCredentialStorage == nil)
        #expect((configuration.connectionProxyDictionary?.isEmpty) == true)
    }

    @Test func madeConfigurationBypassesProxyAndCaches() {
        expectNasneShape(NasneSessionConfiguration.make(timeout: 15), timeout: 15)
    }

    @Test func chunkStreamUsesTheSameConfiguration() throws {
        let url = try #require(URL(string: "http://nasne.invalid/content"))
        let stream = HTTPChunkStream(request: URLRequest(url: url), idleTimeout: 3600)
        // 一時停止のあいだ打ち切らせない長い時間は、そのまま保つ
        expectNasneShape(stream.sessionConfiguration, timeout: 3600)
    }
}
