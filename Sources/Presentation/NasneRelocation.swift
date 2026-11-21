import Foundation

// nasne のアドレスの変化・ネットワークの切り替えへの追従。
// いつ確かめるか・ネットワークが変わったと見るか、の決まり。確かめ方（今のアドレスへ PINVerify、届かなければ SSDP で
// 記述の UDN が同じ nasne を探す）はアプリの環境（AppEnvironment）が行う

/// nasne につながっているか（主ウインドウの上の帯に出す）
public enum NasneConnectionState: Equatable, Sendable {
    /// つながっている（帯を出さない）
    case connected
    /// 今のアドレスに届かないので探している
    case searching
    /// 探したが見つからなかった
    case notFound
}

/// 確かめるきっかけ
public enum NasneRelocationTrigger: String, Sendable {
    /// 起動して保存した登録で部品を作った
    case launch
    /// ネットワークが切り替わった
    case networkChange
    /// 使っている途中で頼みが届かなかった
    case requestFailed
    /// 帯の「探し直す」を押した
    case manual
}

/// ネットワークの経路の要約（NWPath から作る。試験できるように Network に依存させない）
public struct NetworkPathSnapshot: Equatable, Sendable {
    /// 使える経路があるか
    public var isSatisfied: Bool
    /// 使っている接続の名前（en0 など）
    public var interfaces: [String]

    public init(isSatisfied: Bool, interfaces: [String]) {
        self.isSatisfied = isSatisfied
        self.interfaces = interfaces
    }
}

/// 探し直しの決まり
public enum NasneRelocationPolicy {
    /// 頼みが届かなかったことで確かめるのは、前に確かめてからこの間をあけてから
    /// （1 つの画面を開くと頼みが続けて失敗するので、そのたびに探さない）
    public static let failureCooldown: Duration = .seconds(30)
    /// ネットワークが切り替わってから確かめるまで待つ（切り替わった直後はアドレスを取り終えていないことがある。体感の値）
    public static let networkSettleDelay: Duration = .seconds(2)

    /// 確かめてよいか。確かめている最中は確かめない。頼みが届かなかったときだけ、前に確かめてから `failureCooldown` をあける
    public static func shouldCheck(_ trigger: NasneRelocationTrigger, isChecking: Bool,
                                   sinceLastCheck: Duration?) -> Bool {
        guard !isChecking else { return false }
        switch trigger {
        case .launch, .networkChange, .manual:
            return true
        case .requestFailed:
            guard let sinceLastCheck else { return true }
            return sinceLastCheck >= failureCooldown
        }
    }

    /// ネットワークが切り替わったと見て確かめるか：使える経路があり、前は無かったか、使っている接続が変わったとき。
    /// 前が無い（見張りを始めて最初の知らせ）ときは確かめない（起動のときは別に確かめる）
    public static func shouldCheckAfterPathUpdate(previous: NetworkPathSnapshot?, current: NetworkPathSnapshot) -> Bool {
        guard let previous, current.isSatisfied else { return false }
        return !previous.isSatisfied || previous.interfaces != current.interfaces
    }
}
