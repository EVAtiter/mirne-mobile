// 利用者自身の DTCP-IP の資格情報ペアの保管。
//
// 出典: torne mobile HB（MIT、© mar1mo-41414）の lib/core/dtcp/credential_store.dart の考え方。
//
// 設計（§6.7）:
// - 保管するのは Keychain だけ（従来のログインキーチェーン・この Mac だけ・iCloud で同期しない）。
//   平文のファイル・ログ・バックアップには残さない
// - 取り込みでは先にペアを確かめ（DTCPCredentials の関門）、1 つでも通らなければ何も書かない
// - ペアは 1 組だけ。入れ直すときは前の組を消してから入れる
// - 値は画面にもログにも出さない。出してよいのは要約（機器 ID と証明書の指紋）だけ

import Foundation
import Security
import Synchronization

protocol DTCPCredentialStore: Sendable {
    /// 保管しているペア。無ければ nil。保管している値が検証を通らなければ誤り（壊れている）
    func load() throws -> DTCPCredentials?
    /// ペアを確かめて保管する。前の組は先に消す（失敗した取り込みで半端な組を残さない）
    func save(certificate: [UInt8], privateKey: [UInt8]) throws
    /// ペアを消す
    func delete() throws
    var hasCredentials: Bool { get throws }
}

/// 試験用のメモリの中の保管（検証は本物と同じ）
final class DTCPMemoryCredentialStore: DTCPCredentialStore {
    private let authorityKeys: [[UInt8]]
    private let stored = Mutex<DTCPCredentials?>(nil)

    init(authorityKeys: [[UInt8]] = []) {
        self.authorityKeys = authorityKeys
    }

    func load() throws -> DTCPCredentials? { stored.withLock { $0 } }

    func save(certificate: [UInt8], privateKey: [UInt8]) throws {
        let validated = try DTCPCredentials(certificate: certificate, privateKey: privateKey, authorityKeys: authorityKeys)
        stored.withLock { $0 = validated }
    }

    func delete() throws { stored.withLock { $0 = nil } }

    var hasCredentials: Bool { stored.withLock { $0 != nil } }
}

/// Keychain の保管。
///
/// 汎用パスワードの項目を 2 つ（証明書・秘密鍵）、バイト列のまま置く。属性は
/// 従来のログインキーチェーン（`kSecUseDataProtectionKeychain = false`）・`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
/// （この Mac だけ）・`kSecAttrSynchronizable = false`（iCloud キーチェーンに載せない）。
///
/// データ保護キーチェーンを使わない理由：`keychain-access-groups` の entitlement が要り、無いと -34018
/// （errSecMissingEntitlement）。計測コマンド（コマンドラインのツール）は Developer ID で署名しても
/// 書けなかった（2026-11-17 実測。torne mobile HB の Mac 版も同じ理由で従来のキーチェーンにした）。
/// `kSecAttrSynchronizable = false` を明示するのは、entitlement の無いアプリでは同期側の削除・追加も
/// -34018 になるため（torne mobile HB の plan.md §47.4）
final class DTCPKeychainCredentialStore: DTCPCredentialStore {
    /// Keychain の項目のサービス名
    static let service = "com.slack-kingdom.mirne-mobile.dtcp-credentials"
    private static let certificateAccount = "certificate"
    private static let privateKeyAccount = "private-key"

    private let authorityKeys: [[UInt8]]

    init(authorityKeys: [[UInt8]] = []) {
        self.authorityKeys = authorityKeys
    }

    private static func baseQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: false,
            kSecAttrSynchronizable: false,
        ]
    }

    private static func failure(_ status: OSStatus, _ action: String) -> DTCPError {
        .validation("dtcp:store", "Keychain \(action) failed (OSStatus \(status))")
    }

    private static func read(account: String) throws -> [UInt8]? {
        var query = baseQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status, "read") }
        return Array(data)
    }

    private static func write(account: String, bytes: [UInt8]) throws {
        var query = baseQuery(account: account)
        query[kSecValueData] = Data(bytes)
        query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw failure(status, "write") }
    }

    private static func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status, "delete") }
    }

    func load() throws -> DTCPCredentials? {
        let certificate = try Self.read(account: Self.certificateAccount)
        let privateKey = try Self.read(account: Self.privateKeyAccount)
        if certificate == nil && privateKey == nil { return nil }
        guard let certificate, let privateKey else {
            throw DTCPError.validation("dtcp:store", "stored credential data is incomplete")
        }
        return try DTCPCredentials(certificate: certificate, privateKey: privateKey, authorityKeys: authorityKeys)
    }

    func save(certificate: [UInt8], privateKey: [UInt8]) throws {
        // 先に確かめる。通らなければ何も書かない
        _ = try DTCPCredentials(certificate: certificate, privateKey: privateKey, authorityKeys: authorityKeys)
        try delete()
        do {
            try Self.write(account: Self.certificateAccount, bytes: certificate)
            try Self.write(account: Self.privateKeyAccount, bytes: privateKey)
        } catch {
            // 片方だけ残さない
            try? delete()
            throw error
        }
    }

    func delete() throws {
        try Self.remove(account: Self.certificateAccount)
        try Self.remove(account: Self.privateKeyAccount)
    }

    var hasCredentials: Bool {
        get throws { try Self.read(account: Self.certificateAccount) != nil }
    }
}

/// 試験用のメモリの中の SRM の保管
final class DTCPMemorySRMStore: DTCPSRMStore {
    private let authorityKeys: [[UInt8]]
    private let raw = Mutex<[UInt8]?>(nil)

    init(authorityKeys: [[UInt8]] = [], seed: [UInt8]? = nil) {
        self.authorityKeys = authorityKeys
        raw.withLock { $0 = seed }
    }

    var savedRaw: [UInt8]? { raw.withLock { $0 } }

    func load() -> DTCPSRM? {
        // 検証を通らなくなった SRM は捨てる（torne mobile HB と同じ）
        guard let bytes = savedRaw else { return nil }
        return try? DTCPSRM.parse(bytes, authorityKeys: authorityKeys)
    }

    func save(raw bytes: [UInt8], srm: DTCPSRM) {
        raw.withLock { $0 = bytes }
    }
}

/// 資格情報ペアのファイルの読み方（torne mobile HB の取り込みと同じ形を受ける）。
///
/// ちょうどの長さのバイナリならそのまま、そうでなければ文字として 16 進（空白・改行は無視）か base64 で読む。
/// **誤りの文言にファイルの中身を入れない**（長さと形の種類だけ）
enum DTCPCredentialInput {
    /// 読んだバイト列。長さは呼び出し側（`DTCPCredentials` の関門）で確かめる
    static func decode(_ data: Data, expectedLength: Int, name: String) throws -> [UInt8] {
        let bytes = [UInt8](data)
        if bytes.count == expectedLength { return bytes }
        guard let text = String(data: data, encoding: .utf8) else {
            throw DTCPError.validation("dtcp:input", "\(name): not \(expectedLength) bytes and not text (\(bytes.count) bytes)")
        }
        let compact = text.filter { !$0.isWhitespace }
        if compact.count == expectedLength * 2, let decoded = DTCPBytes.fromHex(compact.lowercased()) {
            return decoded
        }
        if let decoded = Data(base64Encoded: compact), decoded.count == expectedLength {
            return [UInt8](decoded)
        }
        throw DTCPError.validation("dtcp:input",
                                   "\(name): could not read \(expectedLength) bytes as binary, hex or base64 (\(bytes.count) bytes of input)")
    }

    /// pydtcpip の credentials.env での名前（pydantic-settings の env_prefix `PYDTCPIP_`）
    static let dotEnvCertificateName = "PYDTCPIP_CERTIFICATE"
    static let dotEnvPrivateKeyName = "PYDTCPIP_PRIVATE_KEY"

    /// pydtcpip の credentials.env（dotenv の形）から、証明書と秘密鍵の文字列を引く。
    ///
    /// pydtcpip に揃えて、同じ名前の環境変数があればファイルより優先し、名前の大文字小文字は区別しない。
    /// 値の読み方（16 進・base64）は `decode` と同じ。**誤りの文言に値を入れない**（どの名前が無いかだけ）
    static func decodeDotEnv(_ data: Data, environment: [String: String] = ProcessInfo.processInfo.environment,
                             certificateLength: Int, privateKeyLength: Int) throws -> (certificate: [UInt8], privateKey: [UInt8]) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw DTCPError.validation("dtcp:input", "credentials.env: not UTF-8 text")
        }
        let file = parseDotEnv(text)
        func value(_ name: String) throws -> Data {
            let key = name.uppercased()
            if let fromEnvironment = environment.first(where: { $0.key.uppercased() == key })?.value, !fromEnvironment.isEmpty {
                return Data(fromEnvironment.utf8)
            }
            guard let fromFile = file[key], !fromFile.isEmpty else {
                throw DTCPError.validation("dtcp:input", "credentials.env: \(name) is missing")
            }
            return Data(fromFile.utf8)
        }
        let certificate = try decode(try value(dotEnvCertificateName), expectedLength: certificateLength, name: "certificate")
        let privateKey = try decode(try value(dotEnvPrivateKeyName), expectedLength: privateKeyLength, name: "private key")
        return (certificate, privateKey)
    }

    /// dotenv の `名前=値` を読む（名前は大文字にそろえる）。
    /// 先頭の BOM を外し、`#` で始まる行と空行を読み飛ばし、行頭の `export ` と値を囲む引用符を外す。
    /// 引用符の無い値は ` #` から後を注釈として捨てる。改行は LF・CRLF のどちらでもよい
    static func parseDotEnv(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        // 先頭の BOM を外す（Windows のメモ帳で保存したファイルに付く。付いたままだと最初の名前が合わない。
        // torne mobile HB も外している：plan.md §67・98b771d）
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        for rawLine in body.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let equal = line.firstIndex(of: "=") else { continue }
            let name = line[..<equal].trimmingCharacters(in: .whitespaces).uppercased()
            var value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'",
               let closing = value.dropFirst().firstIndex(of: quote) {
                value = String(value[value.index(after: value.startIndex)..<closing])
            } else if let comment = value.range(of: " #") {
                value = value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            if !name.isEmpty { result[name] = value }
        }
        return result
    }
}
