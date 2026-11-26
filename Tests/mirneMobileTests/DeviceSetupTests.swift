import Foundation
import Testing

// 発見・登録の流れと、登録の保存。

/// 試験用の MAC アドレス（文書用の範囲 00-00-5E-00-53-xx）
private let sampleMAC = "00:00:5e:00:53:01"

private func sampleDevice(udn: String = "uuid:sample-1", name: String = "nasne-test") -> NasneDevice {
    let direct = NasneDevice.direct(host: NasneFixture.host)
    return NasneDevice(host: direct.host, descriptionURL: direct.descriptionURL, friendlyName: name,
                       modelName: NasneDevice.buffaloNasneModelName, manufacturer: "test", udn: udn, services: direct.services)
}

private func temporaryStoreURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("mirne-mobile-test-\(UUID().uuidString)")
        .appendingPathComponent("registration.json")
}

private func sampleRegistration(_ device: NasneDevice, mac: String = sampleMAC) -> RegisteredNasne {
    RegisteredNasne(host: device.host, udn: device.udn, friendlyName: device.friendlyName, macAddress: mac,
                    registeredAt: Date(timeIntervalSince1970: 1_800_000_000))
}

@Suite("登録の保存")
struct RegistrationStoreTests {
    @Test("保存して読み戻せる。control URL も戻り、MAC アドレスはファイルに書かず Keychain の台ごとの account にだけある")
    func roundTrip() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let secrets = MemorySecretStore()
        let store = FileRegistrationStore(fileURL: url, secrets: secrets)
        #expect(try store.load() == .empty)
        let device = sampleDevice()
        let registration = sampleRegistration(device)
        try store.save(registration, device: device)
        let file = try String(contentsOf: url, encoding: .utf8)
        #expect(!file.contains(sampleMAC))
        #expect(!file.lowercased().contains("macaddress"))
        #expect(try secrets.read(account: FileRegistrationStore.macAccount(for: device.udn)) == sampleMAC)
        let loaded = try #require(try store.load().selected)
        #expect(loaded.registration == registration)
        #expect(loaded.device == device)
        #expect(loaded.device.controlURL(for: NasneProfiles.standard.soap.scheduledRecording) == device.controlURL(for: NasneProfiles.standard.soap.scheduledRecording))
    }

    @Test("2 台を持てる。選んだ台が読み戻り、同じ UDN の保存は書き換え（アドレスが変わったとき）で選びは変えない")
    func multipleDevices() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let secrets = MemorySecretStore()
        let store = FileRegistrationStore(fileURL: url, secrets: secrets)
        let first = sampleDevice(udn: "uuid:sample-1", name: "nasne")
        let second = sampleDevice(udn: "uuid:sample-2", name: "nasne")
        try store.save(sampleRegistration(first), device: first)
        try store.save(sampleRegistration(second, mac: "00:00:5e:00:53:02"), device: second)
        var list = try store.load()
        #expect(list.entries.map(\.key) == ["uuid:sample-1", "uuid:sample-2"])
        #expect(list.selected?.key == "uuid:sample-1")   // 選んでいなければ最初の台
        try store.select(key: "uuid:sample-2")
        list = try store.load()
        #expect(list.selected?.key == "uuid:sample-2")
        #expect(list.selected?.registration.macAddress == "00:00:5e:00:53:02")
        // 1 台目のアドレスが変わった：書き換えで、台の数と選びは変わらない
        var moved = sampleRegistration(first)
        moved.host = "moved"
        try store.save(moved, device: first)
        list = try store.load()
        #expect(list.entries.count == 2)
        #expect(list.entries.first?.registration.host == "moved")
        #expect(list.selected?.key == "uuid:sample-2")
        try store.select(key: "uuid:unknown")   // 一覧に無い鍵は何もしない
        #expect(try store.load().selected?.key == "uuid:sample-2")
    }

    @Test("1 台を外すと、その台の MAC アドレスも消え、選んでいた台なら最初の台に戻る。最後の台でファイルも消える")
    func deleteOne() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let secrets = MemorySecretStore()
        let store = FileRegistrationStore(fileURL: url, secrets: secrets)
        let first = sampleDevice(udn: "uuid:sample-1")
        let second = sampleDevice(udn: "uuid:sample-2")
        try store.save(sampleRegistration(first), device: first)
        try store.save(sampleRegistration(second), device: second)
        try store.select(key: "uuid:sample-2")
        try store.delete(key: "uuid:sample-2")
        #expect(try secrets.read(account: FileRegistrationStore.macAccount(for: "uuid:sample-2")) == nil)
        #expect(try secrets.read(account: FileRegistrationStore.macAccount(for: "uuid:sample-1")) == sampleMAC)
        #expect(try store.load().selected?.key == "uuid:sample-1")
        try store.delete(key: "uuid:sample-1")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try store.load() == .empty)
        try store.delete(key: "uuid:sample-1")   // 2 回目も誤りにならない
    }

    @Test("Keychain に MAC アドレスが無い台は、登録が無いものとして読む（ほかの台は読む）")
    func missingSecret() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let secrets = MemorySecretStore()
        let store = FileRegistrationStore(fileURL: url, secrets: secrets)
        let first = sampleDevice(udn: "uuid:sample-1")
        let second = sampleDevice(udn: "uuid:sample-2")
        try store.save(sampleRegistration(first), device: first)
        try store.save(sampleRegistration(second), device: second)
        try secrets.delete(account: FileRegistrationStore.macAccount(for: "uuid:sample-1"))
        #expect(try store.load().entries.map(\.key) == ["uuid:sample-2"])
    }

    @Test("1.6 までの形（登録 1 台・MAC は 1 つの account）を読むと、一覧の形へ移して古い account を消す")
    func migratesSingleRegistration() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let secrets = MemorySecretStore()
        let device = sampleDevice()
        // 1.6 までの形のファイル：登録 1 台の項目に版 1 の欄を足したもの
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(try JSONSerialization.jsonObject(
            with: encoder.encode(SavedRegistration(registration: sampleRegistration(device), device: device))) as? [String: Any])
        object["version"] = 1
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        try secrets.write(sampleMAC, account: FileRegistrationStore.singleMacAccount)

        let store = FileRegistrationStore(fileURL: url, secrets: secrets)
        let list = try store.load()
        #expect(list.entries.count == 1)
        #expect(list.selected?.registration == sampleRegistration(device))
        #expect(list.selected?.device == device)
        #expect(try secrets.read(account: FileRegistrationStore.singleMacAccount) == nil)
        #expect(try secrets.read(account: FileRegistrationStore.macAccount(for: device.udn)) == sampleMAC)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(SavedRegistrationList.self, from: Data(contentsOf: url))
        #expect(saved.version == SavedRegistrationList.currentVersion)
        #expect(saved.selected == device.udn)
        #expect(try store.load() == list)   // 2 回目は移したものをそのまま読む
    }

    @Test("壊れたファイルは parse の誤り、新しい版の形は unsupported の誤りにする")
    func brokenOrNewerFile() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: url)
        let store = FileRegistrationStore(fileURL: url, secrets: MemorySecretStore())
        #expect(throws: NasneError.self) { try store.load() }
        try Data(#"{"version": 99, "devices": []}"#.utf8).write(to: url)
        #expect(throws: NasneError.self) { try store.load() }
    }

    @Test("呼び名を付けて読み戻せる。前後の空白は除き、空にすると外れる。書き換えの保存（アドレスが変わった）でも残る")
    func customName() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileRegistrationStore(fileURL: url, secrets: MemorySecretStore())
        let device = sampleDevice()
        try store.save(sampleRegistration(device), device: device)
        #expect(try store.load().entries.first?.customName == nil)
        try store.rename(key: device.udn, customName: "  録画用  ")
        #expect(try store.load().entries.first?.customName == "録画用")
        // アドレスが変わって保存し直しても、呼び名は残る
        let moved = NasneDevice(host: "192.0.2.99", descriptionURL: device.descriptionURL, friendlyName: device.friendlyName,
                                modelName: device.modelName, manufacturer: device.manufacturer, udn: device.udn, services: device.services)
        try store.save(sampleRegistration(moved), device: moved)
        let entry = try #require(try store.load().entries.first)
        #expect(entry.registration.host == "192.0.2.99" && entry.customName == "録画用")
        try store.rename(key: device.udn, customName: " ")
        #expect(try store.load().entries.first?.customName == nil)
        // 一覧に無い鍵は何もしない
        try store.rename(key: "uuid:none", customName: "x")
        #expect(try store.load().entries.count == 1)
    }

    @Test("呼び名の欄の無いファイル（1.7 までの形）も読め、版は 2 のまま")
    func customNameAbsent() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileRegistrationStore(fileURL: url, secrets: MemorySecretStore())
        let device = sampleDevice()
        try store.save(sampleRegistration(device), device: device)
        try store.rename(key: device.udn, customName: "録画用")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(#""customName" : "録画用""#) && text.contains(#""version" : 2"#))
        try store.rename(key: device.udn, customName: nil)
        #expect(try !String(contentsOf: url, encoding: .utf8).contains("customName"))
        #expect(try store.load().entries.first?.customName == nil)
    }

    @Test("本体名の書き換え：変わったときだけ書いて true。同じ・空・一覧に無い鍵は何もしない。呼び名は残る")
    func updateBoxName() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileRegistrationStore(fileURL: url, secrets: MemorySecretStore())
        let device = sampleDevice(name: "nasne")
        try store.save(sampleRegistration(device), device: device)
        try store.rename(key: device.udn, customName: "録画用")
        #expect(try !store.updateBoxName(key: device.udn, name: "nasne"))
        #expect(try !store.updateBoxName(key: device.udn, name: "  "))
        #expect(try !store.updateBoxName(key: "uuid:none", name: "居間"))
        #expect(try store.updateBoxName(key: device.udn, name: " 居間 "))
        let entry = try #require(try store.load().entries.first)
        #expect(entry.registration.friendlyName == "居間" && entry.device.friendlyName == "居間")
        #expect(entry.customName == "録画用")
    }
}

@Suite("登録した nasne の呼び名")
struct NasneDisplayNameTests {
    private func entry(_ udn: String, name: String, model: String) -> StoredNasne {
        let direct = NasneDevice.direct(host: NasneFixture.host)
        let device = NasneDevice(host: direct.host, descriptionURL: direct.descriptionURL, friendlyName: name, modelName: model,
                                 manufacturer: "test", udn: udn, services: direct.services)
        return StoredNasne(registration: sampleRegistration(device), device: device)
    }

    @Test("名前が違えばそのまま。同じ名前なら作り手を、作り手も同じなら登録の順の番号を添える")
    func disambiguates() {
        let entries = [
            entry("uuid:1", name: "nasne", model: NasneDevice.nasneModelName),
            entry("uuid:2", name: "nasne", model: NasneDevice.nasneModelName),
            entry("uuid:3", name: "nasne", model: NasneDevice.buffaloNasneModelName),
            entry("uuid:4", name: "居間", model: NasneDevice.buffaloNasneModelName),
            entry("uuid:5", name: " ", model: NasneDevice.buffaloNasneModelName),
        ]
        let names = NasneDisplayName.names(for: entries)
        #expect(names["uuid:1"] == "nasne（SIE・1）")
        #expect(names["uuid:2"] == "nasne（SIE・2）")
        #expect(names["uuid:3"] == "nasne（Buffalo・1）")
        #expect(names["uuid:4"] == "居間")
        #expect(names["uuid:5"] == "nasne（Buffalo・2）")   // 空の名前は「nasne」として数える
        let pair = NasneDisplayName.names(for: [entries[0], entries[2]])
        #expect(pair["uuid:1"] == "nasne（SIE）" && pair["uuid:3"] == "nasne（Buffalo）")
    }

    @Test("呼び名を付けた台は呼び名で呼ぶ。呼び名どうしが同じなら、本体名と同じく作り手を添える")
    func customNames() {
        var first = entry("uuid:1", name: "nasne", model: NasneDevice.nasneModelName)
        first.customName = "録画用"
        var second = entry("uuid:2", name: "nasne", model: NasneDevice.buffaloNasneModelName)
        let third = entry("uuid:3", name: "nasne", model: NasneDevice.nasneModelName)
        var names = NasneDisplayName.names(for: [first, second, third])
        #expect(names["uuid:1"] == "録画用")
        #expect(names["uuid:2"] == "nasne（Buffalo）" && names["uuid:3"] == "nasne（SIE）")
        second.customName = "録画用"
        names = NasneDisplayName.names(for: [first, second, third])
        #expect(names["uuid:1"] == "録画用（SIE）" && names["uuid:2"] == "録画用（Buffalo）" && names["uuid:3"] == "nasne")
        #expect(NasneDisplayName.boxName(of: first) == "nasne")
    }
}

/// 試験用の発見（呼ばれた回数を数え、決めた機器を返す）
private final class FakeDiscovery: DiscoveryService, @unchecked Sendable {
    let result: Result<[NasneDevice], NasneError>
    private let lock = NSLock()
    private var count = 0
    init(_ result: Result<[NasneDevice], NasneError>) { self.result = result }
    var calls: Int { lock.withLock { count } }
    func discover() async throws -> [NasneDevice] {
        lock.withLock { count += 1 }
        return try result.get()
    }
}

/// 試験用の登録
private struct FakeRegistration: RegistrationService {
    var fails: NasneError?
    func register(_ device: NasneDevice, now: Date) async throws -> RegisteredNasne {
        if let fails { throw fails }
        return RegisteredNasne(host: device.host, udn: device.udn, friendlyName: device.friendlyName,
                               macAddress: sampleMAC, registeredAt: now)
    }
    func verify(_ registration: RegisteredNasne) async throws -> Bool { true }
}

/// 試験用の保存先
private final class MemoryRegistrationStore: RegistrationStore, @unchecked Sendable {
    private let lock = NSLock()
    private var list = RegistrationList.empty
    var savedRegistration: RegisteredNasne? { lock.withLock { list.entries.last?.registration } }
    func load() throws -> RegistrationList { lock.withLock { list } }
    func save(_ registration: RegisteredNasne, device: NasneDevice) throws {
        lock.withLock {
            let entry = StoredNasne(registration: registration, device: device)
            if let index = list.entries.firstIndex(where: { $0.key == entry.key }) { list.entries[index] = entry } else { list.entries.append(entry) }
        }
    }
    func select(key: String) throws { lock.withLock { list.selectedKey = key } }
    func delete(key: String) throws { lock.withLock { list.entries.removeAll { $0.key == key } } }
    func rename(key: String, customName: String?) throws {
        lock.withLock {
            if let index = list.entries.firstIndex(where: { $0.key == key }) { list.entries[index].customName = customName }
        }
    }
    func updateBoxName(key: String, name: String) throws -> Bool { false }
}

@MainActor
@Suite("発見・登録の流れ")
struct DeviceSetupModelTests {
    @Test("自動で探すのは最初の方法（SSDP）だけ。走査は押したときだけ。nasne でない機器と重なりは除く")
    func automaticThenScan() async {
        let other = NasneDevice(host: "other", descriptionURL: URL(string: "http://other/")!, friendlyName: "x", modelName: "tv",
                                manufacturer: "", udn: "uuid:other", services: [:])
        let ssdp = FakeDiscovery(.success([sampleDevice(), other]))
        let scan = FakeDiscovery(.success([sampleDevice(name: "renamed"), sampleDevice(udn: "uuid:sample-2")]))
        let model = DeviceSetupModel(setup: DeviceSetupServices(discovery: [ssdp, scan], describe: { _ in sampleDevice() },
                                                                registration: FakeRegistration()),
                                     store: MemoryRegistrationStore()) { _, _ in }
        await model.searchAutomatically()
        #expect(ssdp.calls == 1 && scan.calls == 0)
        #expect(model.devices.map(\.udn) == ["uuid:sample-1"])
        #expect(model.searchedAutomatically && !model.scanned)
        await model.scan()
        #expect(scan.calls == 1)
        #expect(model.devices.map(\.udn) == ["uuid:sample-1", "uuid:sample-2"])
        #expect(model.devices[0].friendlyName == "renamed")
        #expect(model.activity == .idle)
    }

    @Test("登録が通ったら保存して知らせる。失敗したら保存せず、誤りを画面の形で持つ")
    func registerSavesOrReports() async {
        let store = MemoryRegistrationStore()
        var notified: RegisteredNasne?
        let model = DeviceSetupModel(setup: DeviceSetupServices(discovery: [], describe: { _ in sampleDevice() },
                                                                registration: FakeRegistration()),
                                     store: store) { registration, _ in notified = registration }
        await model.register(sampleDevice())
        #expect(store.savedRegistration?.macAddress == sampleMAC)
        #expect(notified?.udn == "uuid:sample-1")
        #expect(model.error == nil)

        let failingStore = MemoryRegistrationStore()
        let failing = DeviceSetupModel(setup: DeviceSetupServices(discovery: [], describe: { _ in sampleDevice() },
                                                                  registration: FakeRegistration(fails: .webapi(1, "webapi:/config/PINVerify"))),
                                       store: failingStore) { _, _ in Issue.record("知らせてはいけない") }
        await failing.register(sampleDevice())
        #expect(failingStore.savedRegistration == nil)
        #expect(failing.error?.code == "1")
    }

    @Test("アドレスで登録：記述を探してから登録する。nasne でなければ登録しない")
    func manualAddress() async {
        let store = MemoryRegistrationStore()
        let model = DeviceSetupModel(setup: DeviceSetupServices(discovery: [], describe: { _ in sampleDevice() },
                                                                registration: FakeRegistration()),
                                     store: store) { _, _ in }
        model.manualAddress = "  "
        await model.registerManualAddress()
        #expect(store.savedRegistration == nil)
        model.manualAddress = " \(NasneFixture.host) "
        await model.registerManualAddress()
        #expect(store.savedRegistration != nil)

        let notNasne = NasneDevice(host: "tv", descriptionURL: URL(string: "http://tv/")!, friendlyName: "tv", modelName: "tv",
                                   manufacturer: "", udn: "uuid:tv", services: [:])
        let other = DeviceSetupModel(setup: DeviceSetupServices(discovery: [], describe: { _ in notNasne },
                                                                registration: FakeRegistration()),
                                     store: MemoryRegistrationStore()) { _, _ in Issue.record("知らせてはいけない") }
        other.manualAddress = "tv"
        await other.registerManualAddress()
        #expect(other.error?.title == ErrorText.nasneMessages["error.notNasne"]?.title)
    }

    @Test("発見が誤りで終わっても、誤りを持って探すのをやめる（止まったままにしない）")
    func discoveryError() async {
        let model = DeviceSetupModel(setup: DeviceSetupServices(discovery: [FakeDiscovery(.failure(.unreachable("ssdp:search")))],
                                                                describe: { _ in sampleDevice() }, registration: FakeRegistration()),
                                     store: MemoryRegistrationStore()) { _, _ in }
        await model.searchAutomatically()
        #expect(model.error?.canRetry == true)
        #expect(model.activity == .idle)
        #expect(!model.canScan)
    }
}
