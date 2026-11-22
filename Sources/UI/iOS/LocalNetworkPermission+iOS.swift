import Foundation
import Network
import os

/// ローカルネットワークの許可（iOS / iPadOS 版）。
///
/// iOS には許可を直接聞く API が無く、初めて LAN へ通信したときに OS が聞く。聞いている間に走査すると、
/// 全部の宛先に届かず 0 台になる（2026-11-21・iPadOS 27.2.1 で実測）。そこで、このアプリの中だけで Bonjour の
/// 受け口（`NWListener`）と探し手（`NWBrowser`）を立てて OS に聞かせ、答えが出るまで待ってから走査する。
/// 探し手が自分の受け口を見つけたら許可あり、`PolicyDenied` で待たされたら許可なし。
/// サービスの種類は Info.plist の `NSBonjourServices` に書いたものと同じにする
enum LocalNetworkPermission {
    /// 許可を確かめるためだけの Bonjour のサービスの種類（Info.plist の `NSBonjourServices` と同じ）
    static let serviceType = "_mirnemobile._tcp"
    /// 答えを待つ上限。過ぎたら、分からないまま走査に進む（許可を聞く画面を出したまま放っておかれたとき）
    static let answerTimeout: Duration = .seconds(120)

    /// 許可を聞き（初めてなら OS が聞く）、答えを返す。分からないまま上限を過ぎたら true（走査に進む）
    @MainActor
    static func request() async -> Bool {
        await withCheckedContinuation { continuation in
            PermissionCheck(continuation: continuation).start()
        }
    }
}

/// 受け口と探し手を立てて、答えが出たら 1 回だけ返す。返すまで自分を持ち続ける
@MainActor
private final class PermissionCheck {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var timeout: Task<Void, Never>?
    /// 答えが出るまで自分を持つ（受け口と探し手の知らせは自分を弱く持つので）
    private var keepAlive: PermissionCheck?
    private let logger = Logger(subsystem: AppLog.subsystem, category: "discovery")

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func start() {
        keepAlive = self
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: UUID().uuidString, type: LocalNetworkPermission.serviceType)
            listener.newConnectionHandler = { $0.cancel() }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state { Task { @MainActor in self?.finish(true, reason: "受け口を立てられない") } }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            finish(true, reason: "受け口を作れない")
            return
        }
        let browser = NWBrowser(for: .bonjour(type: LocalNetworkPermission.serviceType, domain: nil), using: NWParameters())
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .waiting(let error):
                    if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                        self?.finish(false, reason: "許可されていない")
                    }
                case .failed:
                    self?.finish(true, reason: "探し手が止まった")
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard !results.isEmpty else { return }
            Task { @MainActor in self?.finish(true, reason: "許可されている") }
        }
        browser.start(queue: .main)
        self.browser = browser
        timeout = Task { [weak self] in
            try? await Task.sleep(for: LocalNetworkPermission.answerTimeout)
            self?.finish(true, reason: "答えが出ないまま上限を過ぎた")
        }
    }

    private func finish(_ allowed: Bool, reason: String) {
        guard let continuation else { return }
        self.continuation = nil
        logger.notice("ローカルネットワークの許可：\(reason, privacy: .public)")
        listener?.cancel()
        browser?.cancel()
        timeout?.cancel()
        listener = nil
        browser = nil
        continuation.resume(returning: allowed)
        keepAlive = nil
    }
}
