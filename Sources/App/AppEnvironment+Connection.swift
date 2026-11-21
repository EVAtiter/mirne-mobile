import Foundation
import Network
import os

/// nasne のアドレスの変化・ネットワークの切り替えへの追従。
///
/// 確かめるのは 3 つのとき（2026-11-21 に決めた）：起動して保存したアドレスで部品を作ったとき／ネットワークが切り替わったとき／
/// 使っている途中で頼みが届かなかったとき（`ReachabilityReportingHTTPClient` の知らせ。30 秒に 1 回まで）。帯の「探し直す」でも確かめる。
/// 確かめ方：今のアドレスへ PINVerify（状態を変えない）→ 届かなければ SSDP で記述の UDN が同じ nasne を探す（M-SEARCH、
/// 応えが無ければ知らせを最長 35 秒待つ。/24 の走査は使わない）→ 見つかったら、新しいアドレスで PINVerify が通るのを確かめ、
/// 保存した登録（アドレス・記述と control URL）を書き換えて部品を作り直す（再生は止め、主ウインドウは開き直す）
extension AppEnvironment {
    private var connectionLogger: Logger { Logger(subsystem: AppLog.subsystem, category: "discovery") }

    /// 今のアドレスに届くかを確かめ、届かなければ探し直す（決まりは `NasneRelocationPolicy`）
    func checkConnection(_ trigger: NasneRelocationTrigger) {
        guard let services else { return }
        let since = lastConnectionCheck.map { ContinuousClock.now - $0 }
        guard NasneRelocationPolicy.shouldCheck(trigger, isChecking: connectionCheckTask != nil, sinceLastCheck: since) else { return }
        lastConnectionCheck = .now
        let registration = services.registration
        connectionCheckTask = Task { [weak self] in
            await self?.runConnectionCheck(registration: registration, trigger: trigger)
            self?.connectionCheckTask = nil
        }
    }

    /// ネットワークの切り替えを見張る（起動のときに 1 回）
    func startWatchingNetwork() {
        networkWatcher = NetworkPathWatcher { [weak self] in self?.checkConnection(.networkChange) }
    }

    private func runConnectionCheck(registration: RegisteredNasne, trigger: NasneRelocationTrigger) async {
        let logger = connectionLogger
        let started = ContinuousClock.now
        // 今のアドレスで確かめる
        do {
            let accepted = try await setup.checkConnection.verify(registration)
            // 拒まれた（登録が外れたなど）のはアドレスの問題ではないので、探さない
            logger.info("接続の確かめ（\(trigger.rawValue, privacy: .public)）: 今のアドレスに届いた・登録 \(accepted ? "通った" : "拒まれた", privacy: .public)")
            connection = .connected
            return
        } catch where NasneReachability.isUnreachable(error) {
            logger.info("接続の確かめ（\(trigger.rawValue, privacy: .public)）: 今のアドレスに届かない。探し直す")
        } catch {
            logger.error("接続の確かめ（\(trigger.rawValue, privacy: .public)）: 確かめられない（\(NasneDiagnostics.summary(error), privacy: .public)）")
            connection = .connected
            return
        }
        // 記述の UDN が同じ nasne を探す
        connection = .searching
        do {
            guard let device = try await setup.relocate(registration.udn) else {
                logger.info("探し直し: 見つからない・\(started.elapsedMilliseconds, privacy: .public) ms")
                connection = .notFound
                return
            }
            let moved = RegisteredNasne(host: device.host, udn: registration.udn, friendlyName: registration.friendlyName,
                                        macAddress: registration.macAddress, registeredAt: registration.registeredAt)
            guard try await setup.checkConnection.verify(moved) else {
                logger.error("探し直し: 見つけた nasne で登録が通らない")
                connection = .notFound
                return
            }
            guard self.services?.registration.udn == registration.udn else { return }
            if device.host == registration.host {
                // 同じアドレスで見つかった（一時的に届かなかった）。作り直さない
                logger.info("探し直し: 同じアドレスで見つかった・\(started.elapsedMilliseconds, privacy: .public) ms")
            } else {
                try await moveConnection(to: moved, device: device)
                logger.info("探し直し: 新しいアドレスで見つけ、登録を書き換えた・\(started.elapsedMilliseconds, privacy: .public) ms")
            }
            connection = .connected
        } catch {
            logger.error("探し直し: 失敗（\(NasneDiagnostics.summary(error), privacy: .public)）")
            connection = .notFound
        }
    }

    /// 新しいアドレスの登録を保存し、部品を作り直す（再生は止める。主ウインドウは RootView の id が変わって開き直す）
    private func moveConnection(to registration: RegisteredNasne, device: NasneDevice) async throws {
        try store.save(registration, device: device)
        endViewing()
        // ライブの局の一覧・番組表・録画一覧のキャッシュ・視聴の記録は connect が作り直す
        await viewing?.flush()
        // 古いアドレスへの番組表の取り直し（届かずに頼み直している）は待たずに取り消す
        await programGuide?.cancelAndFinish()
        await library?.close()
        try connect(registration: registration, device: device)
    }
}

/// ネットワークの経路の切り替えを見張る（NWPathMonitor）。
/// 使える経路ができた・使っている接続が変わったら、少し待ってから知らせる（決まりは `NasneRelocationPolicy`）
@MainActor
final class NetworkPathWatcher {
    private let monitor = NWPathMonitor()
    private var previous: NetworkPathSnapshot?
    private var settleTask: Task<Void, Never>?
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = NetworkPathSnapshot(isSatisfied: path.status == .satisfied,
                                               interfaces: path.availableInterfaces.map(\.name))
            Task { @MainActor in self?.update(snapshot) }
        }
        monitor.start(queue: DispatchQueue(label: "com.slack-kingdom.mirne-mobile.network-path"))
    }

    private func update(_ snapshot: NetworkPathSnapshot) {
        let shouldCheck = NasneRelocationPolicy.shouldCheckAfterPathUpdate(previous: previous, current: snapshot)
        previous = snapshot
        guard shouldCheck else { return }
        // 接続の名前は端末の事情なので数だけ書く
        Logger(subsystem: AppLog.subsystem, category: "discovery")
            .info("ネットワークが切り替わった: 接続 \(snapshot.interfaces.count, privacy: .public) 本")
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: NasneRelocationPolicy.networkSettleDelay)
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }
}
