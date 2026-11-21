import Foundation
import Security

// 登録した nasne の保存（「登録の保存はアトミックに」）。
//
// - アドレス・名前・記述から解いた control URL はファイル（JSON）に、アトミックに書く
// - PIN の素になる MAC アドレスはファイルに書かず、Keychain に置く（ログ・画面にも出さない）

/// 秘密の値の置き場（Keychain。試験ではメモリ）
public protocol SecretStore: Sendable {
    func read(account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func delete(account: String) throws
}

/// Keychain の汎用パスワードに置く。DTCP-IP の資格情報と同じく、従来のログインキーチェーン・この Mac だけ・
/// iCloud キーチェーンに載せない（`kSecAttrSynchronizable: false` は必ず明示する）
public struct KeychainSecretStore: SecretStore {
    /// Keychain の項目の service
    public static let defaultService = "com.slack-kingdom.mirne-mobile.nasne"
    private let service: String

    public init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    private func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
         kSecUseDataProtectionKeychain: false, kSecAttrSynchronizable: false]
    }

    public func read(account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Self.error(status, "read") }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ value: String, account: String) throws {
        try delete(account: account)
        var query = query(account)
        query[kSecValueData] = Data(value.utf8)
        query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.error(status, "write") }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status, "delete") }
    }

    private static func error(_ status: OSStatus, _ operation: String) -> NasneError {
        NasneError(category: .validation, code: String(status), source: "keychain:\(operation)",
                   messageKey: "error.keychain", detail: "OSStatus \(status)")
    }
}

/// メモリに置く（試験・プレビュー用）
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func read(account: String) throws -> String? { lock.withLock { values[account] } }
    public func write(_ value: String, account: String) throws { lock.withLock { values[account] = value } }
    public func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

/// ファイルに書く登録の中身（MAC アドレスを含めない）
struct SavedRegistration: Codable, Equatable {
    /// 書式の版（形を変えたら上げて、古い形を読み替える）
    static let currentVersion = 1

    struct Service: Codable, Equatable {
        var controlURL: URL
        var scpdURL: URL?
        var eventSubURL: URL?
    }

    var version: Int
    var host: String
    var udn: String
    var friendlyName: String
    var modelName: String
    var manufacturer: String
    var descriptionURL: URL
    /// serviceType → 記述から解いた URL
    var services: [String: Service]
    var registeredAt: Date?

    init(registration: RegisteredNasne, device: NasneDevice) {
        version = Self.currentVersion
        host = registration.host
        udn = registration.udn
        friendlyName = registration.friendlyName
        modelName = device.modelName
        manufacturer = device.manufacturer
        descriptionURL = device.descriptionURL
        services = device.services.mapValues { Service(controlURL: $0.controlURL, scpdURL: $0.scpdURL, eventSubURL: $0.eventSubURL) }
        registeredAt = registration.registeredAt
    }

    var device: NasneDevice {
        NasneDevice(host: host, descriptionURL: descriptionURL, friendlyName: friendlyName, modelName: modelName,
                    manufacturer: manufacturer, udn: udn,
                    services: Dictionary(uniqueKeysWithValues: services.map { type, service in
                        (type, UPnPServiceInfo(serviceType: type, controlURL: service.controlURL,
                                               scpdURL: service.scpdURL, eventSubURL: service.eventSubURL))
                    }))
    }
}

/// 登録した nasne（1 台）の保存先
public protocol RegistrationStore: Sendable {
    /// 保存した登録。無い・MAC アドレスが Keychain に無いときは nil
    func load() throws -> (registration: RegisteredNasne, device: NasneDevice)?
    func save(_ registration: RegisteredNasne, device: NasneDevice) throws
    func delete() throws
}

/// ファイル（JSON）と Keychain に分けて保存する
public struct FileRegistrationStore: RegistrationStore {
    /// MAC アドレスを置く Keychain の account（登録は 1 台だけ）
    static let macAccount = "registered-nasne-mac"
    /// 既定の保存先のファイル名
    static let fileName = "registration.json"

    private let fileURL: URL
    private let secrets: any SecretStore

    public init(fileURL: URL, secrets: any SecretStore) {
        self.fileURL = fileURL
        self.secrets = secrets
    }

    /// 既定の保存先（`~/Library/Application Support/mirne-mobile/registration.json`。番組表の保存先と同じフォルダー）
    public static func standard() -> FileRegistrationStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FileRegistrationStore(fileURL: base.appendingPathComponent("mirne-mobile").appendingPathComponent(fileName),
                                     secrets: KeychainSecretStore())
    }

    public func load() throws -> (registration: RegisteredNasne, device: NasneDevice)? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved: SavedRegistration
        do {
            saved = try decoder.decode(SavedRegistration.self, from: data)
        } catch {
            throw NasneError.parse("registration:load", "the saved registration could not be read")
        }
        guard saved.version <= SavedRegistration.currentVersion else {
            throw NasneError.unsupported("registration:load", "saved by a newer version")
        }
        // MAC アドレスが無ければ（Keychain を消した・別の Mac から写した）、登録は無いものとして扱う
        guard let mac = try secrets.read(account: Self.macAccount) else { return nil }
        let registration = RegisteredNasne(host: saved.host, udn: saved.udn, friendlyName: saved.friendlyName,
                                           macAddress: mac, registeredAt: saved.registeredAt)
        return (registration, saved.device)
    }

    public func save(_ registration: RegisteredNasne, device: NasneDevice) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(SavedRegistration(registration: registration, device: device))
        // 先に Keychain、次にファイル（ファイルだけ残って MAC が無い形は、load が「登録なし」と読む）
        try secrets.write(registration.macAddress, account: Self.macAccount)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try secrets.delete(account: Self.macAccount)
    }
}
