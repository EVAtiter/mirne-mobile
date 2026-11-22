import Foundation

/// 録画の再開位置を nasne へ書き戻す（`recordedContentResumePositionSet`。ポート 64220）。
///
/// このアプリの受信（DTCP-IP）では nasne が再生した位置を覚えないので、止めた位置を送って、ほかの端末や
/// 公式の torne mobile と続きを共有する。nasne は秒に切り捨てて一覧の `resumePoint` に置き、`lastPlaybackTime` を打ち直す。
/// 自動で再試行しない
public struct WebAPIResumePositionService: Sendable {
    private let transport: WebAPITransport

    public init(transport: WebAPITransport) {
        self.transport = transport
    }

    /// 再開位置を書く（録画の頭からの秒。負なら 0 を送る〔nasne は負の位置を errorcode 803 で断る〕。0 は再開位置を消す）
    public func setResumePosition(id: String, seconds: Double) async throws {
        let endpoint = transport.endpoints.recordedContentResumePositionSet
        let names = transport.endpoints.parameters
        let milliseconds = Int((max(0, seconds) * Self.millisecondsPerSecond).rounded(.down))
        _ = try await transport.postJSON(endpoint, form: [names.titleID: id, names.resumePosition: String(milliseconds)])
    }

    static let millisecondsPerSecond: Double = 1000
}
