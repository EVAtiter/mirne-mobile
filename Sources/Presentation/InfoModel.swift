import Foundation
import Observation

/// 読み込みの状態（区画ごとに持ち、1 つが失敗してもほかは出す）
public enum Loadable<Value: Sendable & Equatable>: Sendable, Equatable {
    case idle
    case loading
    case loaded(Value)
    case failed(ErrorPresentation)

    /// 読み込んでいる途中か（まだ始めていない idle は含めない）
    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// 読み込めなかったときの誤り
    public var error: ErrorPresentation? {
        if case .failed(let error) = self { return error }
        return nil
    }

    public var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}

/// 情報の画面の本体情報
public struct DeviceSummary: Sendable, Equatable {
    public var name: String
    /// 公式の表示の版（「2.60」）
    public var softwareVersion: String
    /// 本体の時刻（読めなければ nil）
    public var currentDate: Date?
    /// 地域の名前（表に無ければ数のまま）
    public var area: String?
    public var updateExists: Bool
    /// 録画の件数と上限（読めなければ nil）
    public var titleCount: Int?
    public var titleMax: Int?
}

/// 情報の画面の HDD の 1 台。HDD のシリアルは持たない
public struct HDDSummary: Sendable, Equatable, Identifiable {
    public var id: Int
    public var isInternal: Bool
    /// 使える状態か（マウントされていて登録されている。そうでなければ「つながっていません」と出す）
    public var isConnected: Bool
    public var totalBytes: Int64?
    public var usedBytes: Int64?
    public var freeBytes: Int64?

    /// 使っている割合（0〜1。分からなければ nil）
    public var usedFraction: Double? {
        guard let totalBytes, let usedBytes, totalBytes > 0 else { return nil }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }
}

/// 情報の画面の状態
public struct StatusSummary: Sendable, Equatable {
    /// 録画中の番組名（録画の一覧の recordingFlag から）
    public var recordingTitles: [String]
    /// 選局の状態（`tuningStatus.status` の生の値。意味は未確定なので数のまま出す）
    public var tuningStatus: Int?
    /// お知らせ（CA と EMM。中身が無ければ空）
    public var messages: [String]
}

/// 情報の画面のモデル（2026-11-19 に「ホーム」から改名）。区画ごとに並べて読み込む
@MainActor
@Observable
public final class InfoModel {
    public private(set) var device = Loadable<DeviceSummary>.idle
    public private(set) var hdds = Loadable<[HDDSummary]>.idle
    public private(set) var status = Loadable<StatusSummary>.idle
    public private(set) var recNg = Loadable<[RecNgItem]>.idle
    /// 最後に読み込みを終えた時刻
    public private(set) var lastUpdated: Date?

    private let services: NasneServices
    /// 集約ステータスの見回り（ほかの画面と共通。無ければ世代では読み直さない）
    private let liveStatus: LiveStatusMonitor?
    /// 今の値を読んだときの世代と状態の並び（読めなかったら nil）
    @ObservationIgnored private var knownSignature: [Int?]?

    public init(services: NasneServices, liveStatus: LiveStatusMonitor? = nil) {
        self.services = services
        self.liveStatus = liveStatus
    }

    /// 見回りが最後に読んだ、情報の画面に出すものの世代と状態の並び（これが変わったら `refreshIfChanged` を呼ぶ）
    public var observedSignature: [Int?]? { liveStatus?.generations?.info }

    /// 見回りで読み直す。世代と状態の並びが、前に読んだときと違うときだけ、読み込み中を挟まずに全部の区画を読み直す。
    /// まだ読んでいない・読んでいる途中は何もしない
    public func refreshIfChanged() async {
        guard let signature = observedSignature, signature != knownSignature else { return }
        await refreshQuietly()
    }

    /// 読み込み中を挟まずに全部の区画を読み直す（開いている間の `InfoRefresh.periodicInterval` ごとの読み直しにも使う）。
    /// まだ読んでいない・読んでいる途中は何もしない
    public func refreshQuietly() async {
        guard lastUpdated != nil, !isLoading else { return }
        await reload(quietly: true)
    }

    public var isLoading: Bool {
        [device == .loading, hdds == .loading, status == .loading, recNg == .loading].contains(true)
    }

    /// どれかの区画に値が出ているか（起動してから情報の画面に値が出るまでの計測に使う）
    public var hasAnyValue: Bool {
        device.value != nil || hdds.value != nil || status.value != nil || recNg.value != nil
    }

    /// 全部の区画を読み込み直す（並べて読む。ひとつの失敗はほかに及ばない）。
    /// `quietly` は見回りからの読み直し：読み込み中を挟まず、読めなかった区画は今の値を残す（誤りは出さない）
    public func reload(quietly: Bool = false) async {
        knownSignature = observedSignature
        if !quietly {
            device = .loading
            hdds = .loading
            status = .loading
            recNg = .loading
        }
        let services = services
        // 読めた区画から出す。「状態」は録画中の番組を探すために録画の一覧を全部読むので遅く、ほかの区画を待たせない
        // （前は並べて読んでも出すのは順に待ったので、「録画の失敗」が「状態」を待っていた。2026-11-21）
        await withTaskGroup(of: InfoSectionResult.self) { group in
            group.addTask { .device(await Self.capture { try await Self.loadDevice(services) }) }
            group.addTask { .hdds(await Self.capture { try await Self.loadHDDs(services) }) }
            group.addTask { .status(await Self.capture { try await Self.loadStatus(services) }) }
            group.addTask { .recNg(await Self.capture { try await services.deviceInfo.recNgList() }) }
            for await result in group {
                switch result {
                case .device(let value): device = Self.merge(device, value, quietly: quietly)
                case .hdds(let value): hdds = Self.merge(hdds, value, quietly: quietly)
                case .status(let value): status = Self.merge(status, value, quietly: quietly)
                case .recNg(let value): recNg = Self.merge(recNg, value, quietly: quietly)
                }
            }
        }
        lastUpdated = Date()
    }

    /// 読み直した区画の値。見回りからの読み直しで読めなかったときは、出している値を残す（同じ値なら差し替えない）
    private static func merge<Value: Sendable & Equatable>(_ current: Loadable<Value>, _ new: Loadable<Value>, quietly: Bool) -> Loadable<Value> {
        if quietly, case .failed = new, current.value != nil { return current }
        return new == current ? current : new
    }

    /// 読み終えた区画 1 つ
    private enum InfoSectionResult: Sendable {
        case device(Loadable<DeviceSummary>)
        case hdds(Loadable<[HDDSummary]>)
        case status(Loadable<StatusSummary>)
        case recNg(Loadable<[RecNgItem]>)
    }

    private nonisolated static func capture<Value: Sendable & Equatable>(
        _ work: @Sendable () async throws -> Value) async -> Loadable<Value> {
        do {
            return .loaded(try await work())
        } catch {
            return .failed(ErrorText.present(error))
        }
    }

    nonisolated static func loadDevice(_ services: NasneServices) async throws -> DeviceSummary {
        let info = try await services.deviceInfo.deviceInfo()
        // 件数は無くても情報の画面は出す
        let counts = try? await services.deviceInfo.titleCounts()
        return DeviceSummary(name: info.name, softwareVersion: info.displaySoftwareVersion,
                             currentDate: NasneDateTime.parse(info.currentDate),
                             area: AreaNames.label(areaIdentifierCode: info.areaIdentifierCode, pref: info.pref),
                             updateExists: info.updateExists, titleCount: counts?.count, titleMax: counts?.max)
    }

    nonisolated static func loadHDDs(_ services: NasneServices) async throws -> [HDDSummary] {
        var summaries: [HDDSummary] = []
        for entry in try await services.deviceInfo.hddList() {
            var summary = HDDSummary(id: entry.id, isInternal: entry.isInternal, isConnected: entry.isConnected)
            // マウントされていない・登録されていない HDD は詳細が取れない（頼むと失敗する）ので頼まない
            if entry.isConnected, let info = try? await services.deviceInfo.hddInfo(id: entry.id) {
                summary.totalBytes = info.totalBytes
                summary.usedBytes = info.usedBytes
                summary.freeBytes = info.freeBytes
            }
            summaries.append(summary)
        }
        return summaries
    }

    nonisolated static func loadStatus(_ services: NasneServices) async throws -> StatusSummary {
        let live = try await services.deviceInfo.liveStatus()
        // 録画中は録画の一覧の recordingFlag で見る（DIDL は要らないので取らない）
        let recording = try await services.titles.titles(withMetadata: false).filter(\.isRecording).map(\.title)
        return StatusSummary(recordingTitles: recording, tuningStatus: live.tuningStatus,
                             messages: live.caMessages + live.emmMessages)
    }
}

/// 情報の画面の読み直し（体感の値）
public enum InfoRefresh {
    /// 開いている間に読み直す間。HDD の使用量は録画の最中に世代を進めずに増えていくので、世代の変化とは別にこの間で読み直す
    public static let periodicInterval: TimeInterval = 60
}
