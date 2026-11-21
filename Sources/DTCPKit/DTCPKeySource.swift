// 再生中の PCP の復号に交換鍵を渡す口。
//
// 出典: torne mobile HB（MIT、© mar1mo-41414）の lib/core/services/dtcp_playback.dart の PlaybackKeySource。
//
// 再生のための AKE の接続は使い切り（nasne は認証の直後に閉じる）。そのため、いまのセッションが渡して
// いないラベル（鍵の交代）のパケットが来たら、終わったセッションを待たずに新しい接続で認証し直す
// （参照実装の考え方）。同時に来た要求は、1 つの認証し直しを共有する。

import Foundation

actor DTCPKeySource {
    /// 生きているセッションで鍵を待つ上限
    static let liveSessionWait: Duration = .seconds(15)
    /// 認証し直した後、最初の鍵を待つ上限
    static let reauthenticatedFirstKeyWait: Duration = .seconds(20)

    private var session: any AKEKeySession
    private let reauthenticate: @Sendable () async throws -> any AKEKeySession
    private let diagnostics: DTCPDiagnostics
    private var reauthentication: Task<any AKEKeySession, any Error>?

    init(session: any AKEKeySession, diagnostics: DTCPDiagnostics = .osLog,
         reauthenticate: @escaping @Sendable () async throws -> any AKEKeySession) {
        self.session = session
        self.reauthenticate = reauthenticate
        self.diagnostics = diagnostics
    }

    /// いま鍵を渡しているセッション（認証し直したら新しい方）。再生を止めるときはこれを閉じる
    var currentSession: any AKEKeySession { session }

    /// `label` の鍵。受け取り済みならすぐ、セッションが生きていれば上限付きで待ち、
    /// セッションが渡さずに終わっていれば認証し直す
    func key(for label: UInt8) async throws -> [UInt8] {
        if let known = await session.key(for: label) { return known }
        diagnostics(.playback, "waiting for exchange key, label \(label)")
        do {
            return try await session.waitExchangeKey(label, timeout: Self.liveSessionWait)
        } catch is AKEConnectionClosed {
            diagnostics(.playback, "the AKE session ended without label \(label); re-authenticating")
            let fresh = try await reauthenticateOnce()
            let firstLabel = try await fresh.waitFirstExchangeKey(timeout: Self.reauthenticatedFirstKeyWait)
            guard let key = await fresh.key(for: label) else {
                throw DTCPError.parse("dtcp:ake", "the exchange key label still does not match after "
                    + "re-authentication (wanted \(label), got \(firstLabel))")
            }
            diagnostics(.playback, "re-authenticated; exchange key label \(firstLabel) in hand")
            return key
        }
    }

    private func reauthenticateOnce() async throws -> any AKEKeySession {
        if let reauthentication { return try await reauthentication.value }
        let task = Task { try await reauthenticate() }
        reauthentication = task
        defer { reauthentication = nil }
        let fresh = try await task.value
        let old = session
        session = fresh
        await old.close()
        return fresh
    }
}
