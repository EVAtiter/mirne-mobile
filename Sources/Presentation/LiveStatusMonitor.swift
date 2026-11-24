import Foundation
import Observation

// 集約ステータス（`status/liveStreamStatusListGet`）の見回り。
//
// nasne は一覧が変わったことを知らせない（予約のサービスには通知する状態変数が無い）。代わりに集約ステータスが一覧ごとの
// 世代（generation）を持ち、一覧が変わるたびに進む。公式の torne® mobile もこの頼みを 2 秒ごとに読んでいる。
// アプリが前面にある間、ここだけが読み、各画面のモデルは読んだ世代を見て、変わったときだけ自分の一覧を読み直す
// （画面ごとに同じ頼みを読まない）。nasne に届くか（オフラインか）もここで決める（2026-11-24）。AppKit・SwiftUI に依存させない。

/// nasne に届くか（集約ステータスの見回りが決める。2026-11-24）
public enum NasneLinkState: Sendable, Equatable {
    /// まだ確かめている（起動した直後。1 回目が読めなかったら、すぐ読み直して決める）
    case checking
    /// 集約ステータスが読めている
    case online
    /// 集約ステータスが続けて読めなかった（`NasneLinkPolicy.failuresBeforeOffline` 回）
    case offline
}

/// 集約ステータスの見回り。一覧ごとの世代と、nasne に届くか（`link`）を持つ。
///
/// 届くかはここだけが決める。各画面のモデルは、つながっていない（`isOnline` が偽）間は nasne から読まない
/// （起動した直後に確かめる前に読み込みを始めない・オフラインの間に各画面の読み込みが失敗して知らせが並ばないようにする）
@MainActor
@Observable
public final class LiveStatusMonitor {
    /// 最後に読めた世代。読めなかったら nil（各画面は世代に頼らない読み直しに切り替える）
    public private(set) var generations: LiveGenerations?
    /// nasne に届くか
    public private(set) var link: NasneLinkState
    /// オフラインのまま `NasneLinkPolicy.giveUpAfter` が経ち、自動の読み直しを止めた
    public private(set) var hasGivenUp = false
    /// 見回りを始め直す印（`retry()` で進む。画面は `run()` をこれと前面かどうかで回し直す）
    public private(set) var runToken = 0

    /// 続けて読めなかった回数
    @ObservationIgnored private var failures = 0
    /// オフラインになった時刻（`run()` を始め直すと、オフラインのままならその時刻から数え直す）
    @ObservationIgnored private var offlineSince: ContinuousClock.Instant?

    private let deviceInfo: any DeviceInfoService

    /// `initialLink` は試験で、確かめた後の状態から始めるときに渡す
    public init(deviceInfo: any DeviceInfoService, initialLink: NasneLinkState = .checking) {
        self.deviceInfo = deviceInfo
        link = initialLink
    }

    /// つながっているか（各画面のモデルは、偽の間は nasne から読まない）
    public var isOnline: Bool { link == .online }

    /// 1 回読む。続けて `NasneLinkPolicy.failuresBeforeOffline` 回読めなければオフラインにし、世代を nil にする
    /// （古い世代のまま「変わっていない」と見なさない）
    public func poll() async {
        let status = await Self.read(deviceInfo)
        if let status {
            generations = LiveGenerations(status)
            failures = 0
            offlineSince = nil
            hasGivenUp = false
            link = .online
        } else {
            failures += 1
            // オフラインと見なす前の 1 回の取りこぼしでは世代を消さない（すぐ読み直す。消すと各画面が時間で読み直しに走る）
            guard failures >= NasneLinkPolicy.failuresBeforeOffline else { return }
            generations = nil
            if link != .offline { offlineSince = .now }
            link = .offline
        }
    }

    /// 取り消されるか、オフラインのまま `NasneLinkPolicy.giveUpAfter` が経つまで読む
    /// （呼ぶ側が、アプリが前面にある間だけ回す。`runToken` が変わったら回し直す）
    public func run() async {
        hasGivenUp = false
        // 始め直したら、オフラインのままでも 10 分を数え直す
        if link == .offline { offlineSince = .now }
        while !Task.isCancelled {
            await poll()
            let offlineFor = offlineSince.map { ContinuousClock.now - $0 }
            guard let delay = NasneLinkPolicy.nextDelay(link: link, failures: failures, offlineFor: offlineFor) else {
                hasGivenUp = true
                return
            }
            try? await Task.sleep(for: delay)
        }
    }

    /// 見回りを始め直す（「探し直す」・ネットワークが切り替わったとき）。止めた後の読み直しもここから始まる
    public func retry() {
        hasGivenUp = false
        runToken += 1
    }

    /// 集約ステータスを読む（`NasneLinkPolicy.requestTimeout` で打ち切る。届かない nasne に 15 秒待たない）
    private static func read(_ deviceInfo: any DeviceInfoService) async -> LiveStatus? {
        await withTaskGroup(of: LiveStatus?.self) { group in
            group.addTask { try? await deviceInfo.liveStatus() }
            group.addTask {
                try? await Task.sleep(for: NasneLinkPolicy.requestTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

extension Optional where Wrapped == LiveStatusMonitor {
    /// nasne から読んでよいか（つながっているとき。見回りを持たない部品〔試験〕はいつでもよい）
    @MainActor public var allowsNasneRequests: Bool { self?.isOnline ?? true }
}

/// 届くかの見分け方と、読み直しの間の決まり（2026-11-24）
public enum NasneLinkPolicy {
    /// 続けて何回読めなかったらオフラインと見なすか（1 回の取りこぼしで画面を止めない）
    public static let failuresBeforeOffline = 2
    /// 集約ステータスの 1 回の打ち切り（ふだんの頼みの 15 秒を待つと、オフラインと分かるまでが長い）
    public static let requestTimeout: Duration = .seconds(5)
    /// オフラインになってからこの間は `offlineFastInterval` ごとに読み直す（nasne の再起動・Wi-Fi のつなぎ直しにすぐ気付く）
    public static let offlineFastPeriod: Duration = .seconds(60)
    public static let offlineFastInterval: Duration = .seconds(5)
    /// その後は `offlineSlowInterval` ごと
    public static let offlineSlowInterval: Duration = .seconds(30)
    /// オフラインのままこの間が経ったら、自動の読み直しを止める（外出先で開いたままでも読み続けない）
    public static let giveUpAfter: Duration = .seconds(600)

    /// 次に読むまでの間。nil なら止める
    public static func nextDelay(link: NasneLinkState, failures: Int, offlineFor: Duration?) -> Duration? {
        switch link {
        case .online, .checking:
            // 読めなかったら（まだオフラインと見なす前）、すぐもう 1 回読む
            return failures > 0 ? .zero : LiveStatusMonitorTiming.interval
        case .offline:
            let elapsed = offlineFor ?? .zero
            if elapsed >= giveUpAfter { return nil }
            return elapsed < offlineFastPeriod ? offlineFastInterval : offlineSlowInterval
        }
    }
}

/// 一覧ごとの世代（使うものだけを持つ。値が無い項目は nil）
public struct LiveGenerations: Sendable, Equatable {
    /// 予約の一覧
    public var schedules: Int?
    /// 録画の一覧
    public var recordings: Int?
    /// 情報の画面に出すものの世代と状態（録画の一覧・予約の失敗・外付け HDD・お知らせの世代と、選局の状態）
    public var info: [Int?]

    public init(schedules: Int? = nil, recordings: Int? = nil, info: [Int?] = []) {
        self.schedules = schedules
        self.recordings = recordings
        self.info = info
    }

    init(_ status: LiveStatus) {
        schedules = status.scheduleListGeneration
        recordings = status.recordingListGeneration
        info = [status.recordingListGeneration, status.recNgListGeneration, status.externalHDDGeneration,
                status.caMessageGeneration, status.emmMessageGeneration, status.tuningStatus]
    }
}

/// 一覧を読み直すかの判断（予約・録画の画面で同じ決まりを使う。情報の画面は世代の並びで見るので使わない）。
/// 世代が読めていれば、前に一覧を読んだときの世代と違うときだけ読み直す。読めないときは、前に読んでから `fallbackInterval` 経ったら読み直す
public struct ListRefreshTracker: Sendable {
    /// 世代が読めないときの読み直しの間（一覧ごとに違う。重い一覧ほど長い）
    public let fallbackInterval: TimeInterval
    /// 今の一覧を読んだときの世代（読めなかったら nil）
    public private(set) var knownGeneration: Int?
    /// 最後に一覧を読めた時刻
    public private(set) var lastRead: Date?

    public init(fallbackInterval: TimeInterval) {
        self.fallbackInterval = fallbackInterval
    }

    /// 読み直すか（`observed` は見回りが最後に読んだ世代）
    public func needsRefresh(observed: Int?, now: Date) -> Bool {
        if let observed { return observed != knownGeneration }
        guard let lastRead else { return true }
        return now.timeIntervalSince(lastRead) >= fallbackInterval
    }

    /// 一覧を読めたときに、読む前に控えた世代と時刻を覚える
    public mutating func noteRead(generation: Int?, at date: Date) {
        knownGeneration = generation
        lastRead = date
    }
}

/// 見回りの間
public enum LiveStatusMonitorTiming {
    /// 集約ステータスを読む間。公式の torne® mobile と同じ 2 秒（頼みは 1 KB ほどを 1 回）
    public static let interval: Duration = .seconds(2)
}
