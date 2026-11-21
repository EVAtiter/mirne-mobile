import Foundation
import Observation

/// 発見・登録の流れ。画面（SetupView）はこれの状態を出すだけ。
///
/// - 最初の発見の方法（SSDP）は画面を開いたら自動で試す
/// - 残りの方法（/24 の走査）は、利用者が押したときだけ試す（254 個のアドレスに問い合わせるので、黙って始めない）
/// - アドレスを入れての登録もできる（記述は `/` → ユニキャストの M-SEARCH の順に探す）。デバイス記述の URL を入れてもよい
/// - 登録（MAC → PIN → PINVerify）が通ったら保存して、`onRegistered` で知らせる
@MainActor
@Observable
public final class DeviceSetupModel {
    public enum Activity: Equatable, Sendable {
        case idle
        /// 探している（SSDP か走査か）
        case searching(SearchKind)
        /// 記述を取っている・登録している
        case registering
    }

    public enum SearchKind: Equatable, Sendable {
        case automatic
        case scan
    }

    public private(set) var activity = Activity.idle
    /// 見つかった nasne（UDN、無ければアドレスで重ねない）
    public private(set) var devices: [NasneDevice] = []
    /// 自動の発見を一度でも終えたか（見つからなかったときに走査と手入力を勧める）
    public private(set) var searchedAutomatically = false
    /// 走査を一度でも終えたか
    public private(set) var scanned = false
    /// 手で入れるアドレス
    public var manualAddress = ""
    /// 直近の誤り（画面に出す形）
    public private(set) var error: ErrorPresentation?

    private let setup: DeviceSetupServices
    private let store: any RegistrationStore
    private let onRegistered: @MainActor (RegisteredNasne, NasneDevice) -> Void

    public init(setup: DeviceSetupServices, store: any RegistrationStore,
                onRegistered: @escaping @MainActor (RegisteredNasne, NasneDevice) -> Void) {
        self.setup = setup
        self.store = store
        self.onRegistered = onRegistered
    }

    /// 走査の方法があるか（発見の 2 つ目以降）
    public var canScan: Bool { setup.discovery.count > 1 }

    public var isBusy: Bool { activity != .idle }

    /// 最初の方法（SSDP）で探す
    public func searchAutomatically() async {
        guard let first = setup.discovery.first else { return }
        await search(with: [first], kind: .automatic)
        searchedAutomatically = true
    }

    /// 残りの方法（/24 の走査）で探す
    public func scan() async {
        await search(with: Array(setup.discovery.dropFirst()), kind: .scan)
        scanned = true
    }

    private func search(with methods: [any DiscoveryService], kind: SearchKind) async {
        guard !isBusy else { return }
        activity = .searching(kind)
        error = nil
        defer { activity = .idle }
        for method in methods {
            do {
                merge(try await method.discover())
            } catch {
                self.error = ErrorText.present(error)
            }
        }
    }

    private func merge(_ found: [NasneDevice]) {
        for device in found where device.isNasne {
            let key = device.udn.isEmpty ? device.host : device.udn
            if let index = devices.firstIndex(where: { ($0.udn.isEmpty ? $0.host : $0.udn) == key }) {
                devices[index] = device
            } else {
                devices.append(device)
            }
        }
    }

    /// 見つかった nasne を登録する
    public func register(_ device: NasneDevice) async {
        guard !isBusy else { return }
        activity = .registering
        error = nil
        defer { activity = .idle }
        await completeRegistration(device)
    }

    /// 入れたアドレスの nasne を登録する（記述を探してから）
    public func registerManualAddress() async {
        let host = manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !isBusy else { return }
        activity = .registering
        error = nil
        defer { activity = .idle }
        let device: NasneDevice
        do {
            device = try await setup.describe(host)
        } catch {
            self.error = ErrorText.present(error)
            return
        }
        guard device.isNasne else {
            error = ErrorText.present(NasneError(category: .validation, source: "setup:manual", messageKey: "error.notNasne",
                                                 detail: "modelName is not a nasne"))
            return
        }
        await completeRegistration(device)
    }

    private func completeRegistration(_ device: NasneDevice) async {
        do {
            let registration = try await setup.registration.register(device)
            try store.save(registration, device: device)
            onRegistered(registration, device)
        } catch {
            self.error = ErrorText.present(error)
        }
    }
}
