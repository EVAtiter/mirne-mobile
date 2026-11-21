import Foundation
import Observation

/// 資格情報（DTCP-IP のペア）の取り込み・確かめ・削除。
///
/// - 取り込みは DTCPKit の関門（証明書の形・DTLA の署名・秘密鍵の範囲・公開鍵の一致）を通ったものだけを保存する
/// - 画面に出すのは「取り込み済みか」・機器 ID・証明書の指紋（SHA-1）だけ。値は出さない
/// - Keychain の読み書きは、許可のダイアログで待つことがあるので、画面のスレッドの外で行う
@MainActor
@Observable
public final class CredentialsModel {
    /// 取り込み済みなら要約、無ければ nil
    public private(set) var summary = Loadable<DTCPCredentialSummary?>.idle
    /// 取り込み・削除の誤り
    public private(set) var error: ErrorPresentation?
    public private(set) var isWorking = false

    private let store: any DTCPCredentialStore
    /// credentials.env を読むときの環境変数（pydtcpip に揃えて、同じ名前があればファイルより優先する）
    private let environment: [String: String]

    init(store: any DTCPCredentialStore, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.store = store
        self.environment = environment
    }

    /// 実機に向けた組み立て（Keychain）
    public static func live() -> CredentialsModel {
        CredentialsModel(store: DTCPKeychainCredentialStore())
    }

    /// 取り込み済みかを読む（Keychain を読むので、初めては許可を聞かれることがある）
    public func load() async {
        summary = .loading
        let store = store
        do {
            let credentials = try await Task.detached { try store.load() }.value
            summary = .loaded(credentials?.summary)
        } catch {
            summary = .failed(ErrorText.present(error))
        }
    }

    /// 2 つのファイル（証明書と秘密鍵。順は問わない）から取り込む。中身はバイナリ・16 進・base64 のどれでもよい
    public func importFiles(_ files: [Data]) async {
        await perform { store, _ in
            guard files.count == 2 else {
                throw DTCPError.validation("dtcp:input", "choose exactly two files (certificate and private key)")
            }
            var lastError: (any Error)?
            // どちらが証明書かは長さで見分ける（88 バイトと 20 バイト。16 進・base64 なら読んだ後の長さ）
            for (certificateIndex, keyIndex) in [(0, 1), (1, 0)] {
                do {
                    let certificate = try DTCPCredentialInput.decode(files[certificateIndex], expectedLength: DTCPCertificate.length,
                                                                     name: "certificate")
                    let privateKey = try DTCPCredentialInput.decode(files[keyIndex], expectedLength: DTCPCredentials.privateKeyLength,
                                                                    name: "private key")
                    try store.save(certificate: certificate, privateKey: privateKey)
                    return
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? DTCPError.validation("dtcp:input", "could not read the files")
        }
    }

    /// pydtcpip の credentials.env から取り込む
    public func importDotEnv(_ data: Data) async {
        let environment = environment
        await perform { store, _ in
            let pair = try DTCPCredentialInput.decodeDotEnv(data, environment: environment,
                                                            certificateLength: DTCPCertificate.length,
                                                            privateKeyLength: DTCPCredentials.privateKeyLength)
            try store.save(certificate: pair.certificate, privateKey: pair.privateKey)
        }
    }

    /// 消す
    public func delete() async {
        await perform { store, _ in try store.delete() }
    }

    /// 画面のスレッドの外で保存先を触り、終わったら要約を読み直す
    private func perform(_ work: @escaping @Sendable (any DTCPCredentialStore, Void) throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        let store = store
        do {
            try await Task.detached { try work(store, ()) }.value
        } catch {
            self.error = ErrorText.present(error)
        }
        await load()
    }
}
