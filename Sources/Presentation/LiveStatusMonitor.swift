import Foundation
import Observation

// 集約ステータス（`status/liveStreamStatusListGet`）の見回り。
//
// nasne は一覧が変わったことを知らせない（予約のサービスには通知する状態変数が無い）。代わりに集約ステータスが一覧ごとの
// 世代（generation）を持ち、一覧が変わるたびに進む。公式の torne® mobile もこの頼みを 2 秒ごとに読んでいる。
// アプリが前面にある間、ここだけが読み、各画面のモデルは読んだ世代を見て、変わったときだけ自分の一覧を読み直す
// （画面ごとに同じ頼みを読まない）。AppKit・SwiftUI に依存させない。

/// 集約ステータスの見回り
@MainActor
@Observable
public final class LiveStatusMonitor {
    /// 最後に読めた世代。読めなかったら nil（各画面は世代に頼らない読み直しに切り替える）
    public private(set) var generations: LiveGenerations?

    private let deviceInfo: any DeviceInfoService

    public init(deviceInfo: any DeviceInfoService) {
        self.deviceInfo = deviceInfo
    }

    /// 1 回読む。読めなければ世代を nil にする（古い世代のまま「変わっていない」と見なさない）
    public func poll() async {
        generations = (try? await deviceInfo.liveStatus()).map(LiveGenerations.init)
    }

    /// 取り消されるまで `LiveStatusMonitorTiming.interval` ごとに読む（呼ぶ側が、アプリが前面にある間だけ回す）
    public func run() async {
        while !Task.isCancelled {
            await poll()
            try? await Task.sleep(for: LiveStatusMonitorTiming.interval)
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
