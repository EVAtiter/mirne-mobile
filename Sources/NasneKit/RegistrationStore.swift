import Foundation
import Security

// 登録した nasne の保存（「登録の保存はアトミックに」）。
//
// - 登録は何台でも持てる。いま見ている 1 台（選んでいる台）も一緒に保存する
// - アドレス・名前・記述から解いた control URL はファイル（JSON）に、アトミックに書く
// - PIN の素になる MAC アドレスはファイルに書かず、Keychain に台ごとに置く（ログ・画面にも出さない）

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

/// 登録した nasne 1 台（登録と、記述から解いた機器）
public struct StoredNasne: Sendable, Equatable {
    public var registration: RegisteredNasne
    public var device: NasneDevice
    /// このアプリの中だけの呼び名（設定の「名前を変える…」。付けていなければ nil で、本体名で呼ぶ）
    public var customName: String?

    public init(registration: RegisteredNasne, device: NasneDevice, customName: String? = nil) {
        self.registration = registration
        self.device = device
        self.customName = customName
    }

    /// 台を見分ける鍵（記述の UDN。UDN の無い機器はアドレス）
    public var key: String { registration.storageKey }
}

extension RegisteredNasne {
    /// 登録を見分ける鍵（記述の UDN。UDN の無い機器はアドレス。探し直しも UDN で行う）
    public var storageKey: String { udn.isEmpty ? host : udn }
}

/// 保存した登録の一覧と、選んでいる台
public struct RegistrationList: Sendable, Equatable {
    /// 登録した順
    public var entries: [StoredNasne]
    /// 選んでいる台の鍵（無い・一覧に無ければ最初の台）
    public var selectedKey: String?

    public init(entries: [StoredNasne] = [], selectedKey: String? = nil) {
        self.entries = entries
        self.selectedKey = selectedKey
    }

    public static let empty = RegistrationList()

    /// 選んでいる台（登録が無ければ nil）
    public var selected: StoredNasne? {
        entries.first { $0.key == selectedKey } ?? entries.first
    }
}

/// ファイルに書く登録 1 台の中身（MAC アドレスを含めない）
struct SavedRegistration: Codable, Equatable {
    struct Service: Codable, Equatable {
        var controlURL: URL
        var scpdURL: URL?
        var eventSubURL: URL?
    }

    var host: String
    var udn: String
    var friendlyName: String
    var modelName: String
    var manufacturer: String
    var descriptionURL: URL
    /// serviceType → 記述から解いた URL
    var services: [String: Service]
    var registeredAt: Date?
    /// このアプリの中だけの呼び名（無ければ本体名で呼ぶ）。足しても書式の版は上げない：
    /// 前の版は知らない欄を読み飛ばすので、同じファイルを読める（前の版が書き直すと、この欄は消える）
    var customName: String?

    init(registration: RegisteredNasne, device: NasneDevice) {
        host = registration.host
        udn = registration.udn
        friendlyName = registration.friendlyName
        modelName = device.modelName
        manufacturer = device.manufacturer
        descriptionURL = device.descriptionURL
        services = device.services.mapValues { Service(controlURL: $0.controlURL, scpdURL: $0.scpdURL, eventSubURL: $0.eventSubURL) }
        registeredAt = registration.registeredAt
    }

    var key: String { udn.isEmpty ? host : udn }

    var device: NasneDevice {
        NasneDevice(host: host, descriptionURL: descriptionURL, friendlyName: friendlyName, modelName: modelName,
                    manufacturer: manufacturer, udn: udn,
                    services: Dictionary(uniqueKeysWithValues: services.map { type, service in
                        (type, UPnPServiceInfo(serviceType: type, controlURL: service.controlURL,
                                               scpdURL: service.scpdURL, eventSubURL: service.eventSubURL))
                    }))
    }

    /// 呼び名として保存する形（前後の空白を除き、空なら nil）
    static func normalizedCustomName(_ name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func registration(macAddress: String) -> RegisteredNasne {
        RegisteredNasne(host: host, udn: udn, friendlyName: friendlyName, macAddress: macAddress, registeredAt: registeredAt)
    }
}

/// 保存のファイルの中身（書式の版 2：登録の一覧と選んでいる台）
struct SavedRegistrationList: Codable, Equatable {
    /// 書式の版（形を変えたら上げて、古い形を読み替える）。
    /// 1 = 登録 1 台をそのまま書いた形（1.6 まで）、2 = 一覧と選んでいる台（2026-11-25。複数台の nasne）
    static let currentVersion = 2
    static let singleRegistrationVersion = 1

    var version: Int
    var selected: String?
    var devices: [SavedRegistration]
}

/// 書式の版だけを読む
private struct SavedRegistrationVersion: Decodable {
    var version: Int
}

/// 登録した nasne の保存先
public protocol RegistrationStore: Sendable {
    /// 保存した登録の一覧（無ければ空）。MAC アドレスが Keychain に無い台は含めない
    func load() throws -> RegistrationList
    /// 登録を足す。同じ台（UDN が同じ）があれば書き換える（アドレスが変わったときも）。選んでいる台は変えない
    func save(_ registration: RegisteredNasne, device: NasneDevice) throws
    /// 選んでいる台を変える（一覧に無い鍵は何もしない）
    func select(key: String) throws
    /// 1 台の登録を外す（Keychain の MAC アドレスも消す）。選んでいた台なら、選びを外す（読むと最初の台になる）
    func delete(key: String) throws
    /// このアプリの中だけの呼び名を付ける。空・空白だけなら外す（本体名で呼ぶ）。一覧に無い鍵は何もしない
    func rename(key: String, customName: String?) throws
    /// 本体名を書き換える（nasne HOME で変えた名前を、つながったときに読み直して保存する）。
    /// 同じ名前・空の名前・一覧に無い鍵は何もしない。書き換えたら true
    @discardableResult
    func updateBoxName(key: String, name: String) throws -> Bool
}

/// ファイル（JSON）と Keychain に分けて保存する
public struct FileRegistrationStore: RegistrationStore {
    /// MAC アドレスを置く Keychain の account の頭（後ろに台の鍵を付ける）
    static let macAccountPrefix = "registered-nasne-mac:"
    /// 書式の版 1 の、MAC アドレスの account（登録は 1 台だけだった。読み替えのときにだけ読む）
    static let singleMacAccount = "registered-nasne-mac"
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

    /// 台の MAC アドレスの account
    static func macAccount(for key: String) -> String { macAccountPrefix + key }

    public func load() throws -> RegistrationList {
        guard let saved = try readFile() else { return .empty }
        var entries: [StoredNasne] = []
        for device in saved.devices {
            // MAC アドレスが無ければ（Keychain を消した・別の端末から写した）、その台は登録が無いものとして扱う
            guard let mac = try secrets.read(account: Self.macAccount(for: device.key)) else { continue }
            entries.append(StoredNasne(registration: device.registration(macAddress: mac), device: device.device,
                                       customName: SavedRegistration.normalizedCustomName(device.customName)))
        }
        return RegistrationList(entries: entries, selectedKey: saved.selected)
    }

    public func save(_ registration: RegisteredNasne, device: NasneDevice) throws {
        var saved = try readFile() ?? SavedRegistrationList(version: SavedRegistrationList.currentVersion, selected: nil, devices: [])
        var entry = SavedRegistration(registration: registration, device: device)
        // 先に Keychain、次にファイル（ファイルにだけ載って MAC が無い台は、load が「登録なし」と読む）
        try secrets.write(registration.macAddress, account: Self.macAccount(for: entry.key))
        if let index = saved.devices.firstIndex(where: { $0.key == entry.key }) {
            // 書き換え（アドレスが変わった・登録し直した）でも、付けた呼び名は残す
            entry.customName = saved.devices[index].customName
            saved.devices[index] = entry
        } else {
            saved.devices.append(entry)
        }
        try writeFile(saved)
    }

    public func select(key: String) throws {
        guard var saved = try readFile(), saved.devices.contains(where: { $0.key == key }), saved.selected != key else { return }
        saved.selected = key
        try writeFile(saved)
    }

    public func rename(key: String, customName: String?) throws {
        guard var saved = try readFile(), let index = saved.devices.firstIndex(where: { $0.key == key }) else { return }
        let name = SavedRegistration.normalizedCustomName(customName)
        guard saved.devices[index].customName != name else { return }
        saved.devices[index].customName = name
        try writeFile(saved)
    }

    @discardableResult
    public func updateBoxName(key: String, name: String) throws -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var saved = try readFile(), let index = saved.devices.firstIndex(where: { $0.key == key }),
              saved.devices[index].friendlyName != trimmed else { return false }
        saved.devices[index].friendlyName = trimmed
        try writeFile(saved)
        return true
    }

    public func delete(key: String) throws {
        if var saved = try readFile() {
            saved.devices.removeAll { $0.key == key }
            if saved.selected == key { saved.selected = nil }
            if saved.devices.isEmpty {
                try FileManager.default.removeItem(at: fileURL)
            } else {
                try writeFile(saved)
            }
        }
        try secrets.delete(account: Self.macAccount(for: key))
    }

    /// ファイルを読む（無ければ nil）。書式の版 1 なら版 2 へ読み替えて書き直す
    private func readFile() throws -> SavedRegistrationList? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let version: Int
        do {
            version = try decoder.decode(SavedRegistrationVersion.self, from: data).version
        } catch {
            throw NasneError.parse("registration:load", "the saved registration could not be read")
        }
        guard version <= SavedRegistrationList.currentVersion else {
            throw NasneError.unsupported("registration:load", "saved by a newer version")
        }
        do {
            if version == SavedRegistrationList.singleRegistrationVersion {
                // 版 1 のファイルは登録 1 台をそのまま書いた形（版の欄のほかは版 2 の 1 台と同じ）
                return try migrate(decoder.decode(SavedRegistration.self, from: data))
            }
            return try decoder.decode(SavedRegistrationList.self, from: data)
        } catch let error as NasneError {
            throw error
        } catch {
            throw NasneError.parse("registration:load", "the saved registration could not be read")
        }
    }

    /// 書式の版 1（登録 1 台）を版 2 へ移す。MAC アドレスを台ごとの account へ写し、ファイルを書き直してから古い account を消す
    /// （途中で止まっても、版 1 のファイルと古い account が残るので、次に読んだときにやり直せる）
    private func migrate(_ single: SavedRegistration) throws -> SavedRegistrationList {
        let list = SavedRegistrationList(version: SavedRegistrationList.currentVersion, selected: single.key, devices: [single])
        guard let mac = try secrets.read(account: Self.singleMacAccount) else {
            // MAC アドレスが無い（版 1 でも登録なしと読んでいた形）。ファイルは書き直さず、その台は読まない
            return list
        }
        try secrets.write(mac, account: Self.macAccount(for: single.key))
        try writeFile(list)
        try secrets.delete(account: Self.singleMacAccount)
        return list
    }

    private func writeFile(_ saved: SavedRegistrationList) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(saved)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
