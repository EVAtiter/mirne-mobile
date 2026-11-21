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

@Suite("登録の保存")
struct RegistrationStoreTests {
    @Test("保存して読み戻せる。control URL も戻り、MAC アドレスはファイルに書かず Keychain の側にだけある")
    func roundTrip() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let secrets = MemorySecretStore()
        let store = FileRegistrationStore(fileURL: url, secrets: secrets)
        #expect(try store.load() == nil)
        let device = sampleDevice()
        let registration = RegisteredNasne(host: device.host, udn: device.udn, friendlyName: device.friendlyName,
                                           macAddress: sampleMAC, registeredAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.save(registration, device: device)
        let file = try String(contentsOf: url, encoding: .utf8)
        #expect(!file.contains(sampleMAC))
        #expect(!file.lowercased().contains("macaddress"))
        #expect(try secrets.read(account: FileRegistrationStore.macAccount) == sampleMAC)
        let loaded = try #require(try store.load())
        #expect(loaded.registration == registration)
        #expect(loaded.device == device)
        #expect(loaded.device.controlURL(for: NasneProfiles.standard.soap.scheduledRecording) == device.controlURL(for: NasneProfiles.standard.soap.scheduledRecording))
    }

    @Test("Keychain に MAC アドレスが無ければ、登録は無いものとして読む。消すと両方消える")
    func missingSecretAndDelete() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let secrets = MemorySecretStore()
        let store = FileRegistrationStore(fileURL: url, secrets: secrets)
        let device = sampleDevice()
        try store.save(RegisteredNasne(host: device.host, udn: device.udn, friendlyName: device.friendlyName, macAddress: sampleMAC),
                       device: device)
        try secrets.delete(account: FileRegistrationStore.macAccount)
        #expect(try store.load() == nil)
        try store.save(RegisteredNasne(host: device.host, udn: device.udn, friendlyName: device.friendlyName, macAddress: sampleMAC),
                       device: device)
        try store.delete()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try secrets.read(account: FileRegistrationStore.macAccount) == nil)
        try store.delete()   // 2 回目も誤りにならない
    }

    @Test("壊れたファイルは parse の誤りにする")
    func brokenFile() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: url)
        let store = FileRegistrationStore(fileURL: url, secrets: MemorySecretStore())
        #expect(throws: NasneError.self) { try store.load() }
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
    private var saved: (RegisteredNasne, NasneDevice)?
    var savedRegistration: RegisteredNasne? { lock.withLock { saved?.0 } }
    func load() throws -> (registration: RegisteredNasne, device: NasneDevice)? { lock.withLock { saved.map { ($0.0, $0.1) } } }
    func save(_ registration: RegisteredNasne, device: NasneDevice) throws { lock.withLock { saved = (registration, device) } }
    func delete() throws { lock.withLock { saved = nil } }
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
