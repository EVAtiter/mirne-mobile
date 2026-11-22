/// ローカルネットワークの許可（macOS 版）。macOS では探す前に聞かない（初めて LAN へ通信したときに OS が聞く）
enum LocalNetworkPermission {
    @MainActor
    static func request() async -> Bool { true }
}
