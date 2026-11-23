import Foundation
import Observation

// 予約の一覧と詳細と、手動の予約の作成・変更・削除。
//
// 一覧は `X_GetRecordScheduleList`（50 件ずつ頁を送る）を、開始の早い順に並べる。局名は nasne のチャンネル一覧
// （地上）から serviceID で引き、読めなければ serviceID のまま出す（予約の一覧は止めない）。
// AppKit・SwiftUI に依存させない。

/// 予約の一覧のモデル
@MainActor
@Observable
public final class SchedulesModel {
    public private(set) var schedules = Loadable<[RecordSchedule]>.idle
    /// 選んだ予約の ID（一覧の item id）
    public var selectedID: String?
    /// テレビの局（番組表と同じ並び。サブチャンネルも入れる）。チャンネル一覧が読めなければ空
    public var channels: [Channel] {
        GuideLineupModel.lineup(catalog.channels.value ?? [], showsSubchannels: true)
    }

    private let service: any ScheduleService
    /// 局の一覧（ほかの画面と共通）
    private let catalog: ChannelCatalog
    /// 集約ステータスの見回り（予約の一覧の世代。ほかの画面と共通）
    private let liveStatus: LiveStatusMonitor
    private let now: @Sendable () -> Date
    /// 読み直すかの判断（前に一覧を読んだときの世代と時刻）
    @ObservationIgnored private var tracker = ListRefreshTracker(fallbackInterval: SchedulesRefresh.fallbackInterval)

    public init(schedules: any ScheduleService, channels: ChannelCatalog, liveStatus: LiveStatusMonitor,
                now: @escaping @Sendable () -> Date = { Date() }) {
        service = schedules
        catalog = channels
        self.liveStatus = liveStatus
        self.now = now
    }

    /// 見回りが最後に読んだ予約の一覧の世代（画面はこれが変わったら `refreshIfChanged` を呼ぶ）
    public var observedGeneration: Int? { liveStatus.generations?.schedules }

    /// 開始の早い順の一覧（同じ開始なら局の serviceID、ID の順）
    public var sortedSchedules: [RecordSchedule] {
        (schedules.value ?? []).sorted {
            ($0.start, $0.channel.serviceID, $0.id) < ($1.start, $1.channel.serviceID, $1.id)
        }
    }

    /// 選んだ予約
    public var selectedSchedule: RecordSchedule? {
        guard let selectedID else { return nil }
        return schedules.value?.first { $0.id == selectedID }
    }

    /// 局名（引けなければ serviceID の 16 進）。チャンネル一覧から serviceID で引く（局名の無い項目は使わない）
    public func channelName(_ channel: ScheduleChannel) -> String {
        let named = catalog.channels.value?.last { $0.serviceID == channel.serviceID && !$0.serviceName.isEmpty }
        return named?.serviceName ?? "サービス \(channel.serviceIDHex)"
    }

    /// 読み込み直す（選んでいた予約は、まだあれば選んだまま）。局名は読めていなければ一緒に読む
    public func reload() async {
        schedules = .loading
        async let names: Void = catalog.load()
        // 世代は一覧より先に控える（読んでいる間に変わったら、次の見回りで世代の違いとして見つかる。
        // 見回りの世代が少し古くても、一度余分に読み直すだけ）
        let generation = observedGeneration
        do {
            schedules = .loaded(try await service.schedules())
            noteListRead(generation: generation)
        } catch {
            schedules = .failed(ErrorText.present(error))
        }
        await names
        dropMissingSelection()
    }

    /// 画面を開いている間の読み直し。見回り（`LiveStatusMonitor`）が読んだ予約の一覧の世代が、前に一覧を読んだときと違うときだけ一覧を読み直す。
    /// nasne の予約のサービスは変わったことを知らせない（SCPD に通知する状態変数が無い）ので、公式のアプリやほかの端末の変更、
    /// 録画の後に繰り返しの予約が次の回へ進んだことは、こうして見つける（公式の torne® mobile も同じ頼みを見回っている）。
    /// 世代が読めないとき（見回りの頼みが失敗した・項目が無い）は、`SchedulesRefresh.fallbackInterval` ごとに一覧を読み直す。
    /// まだ読んでいない・読み込みの途中・読み込めなかったときは何もしない（最初の読み込みと読み直しは `reload` が受け持つ）
    public func refreshIfChanged() async {
        guard case .loaded = schedules else { return }
        let generation = observedGeneration
        guard tracker.needsRefresh(observed: generation, now: now()) else { return }
        await refreshQuietly(generation: generation)
    }

    /// 読み込み中の表示を出さずに一覧を読み直し、中身が変わったときだけ差し替える。読めなかったときは今の一覧を残す
    /// （誤りは出さない。次の見回りか、更新で出す）
    private func refreshQuietly(generation: Int?) async {
        guard case .loaded(let current) = schedules else { return }
        guard let latest = try? await service.schedules() else { return }
        // 待っている間に更新などで状態が変わっていたら、そちらを正とする
        guard case .loaded = schedules else { return }
        if latest != current { schedules = .loaded(latest) }
        noteListRead(generation: generation)
        dropMissingSelection()
    }

    /// 一覧を読めたときの世代と時刻を覚える
    private func noteListRead(generation: Int?) {
        tracker.noteRead(generation: generation, at: now())
    }

    /// 選んでいた予約が一覧から無くなったら、選ぶのをやめる
    private func dropMissingSelection() {
        if let selectedID, schedules.value?.contains(where: { $0.id == selectedID }) != true {
            self.selectedID = nil
        }
    }

    /// 予約を消す（確かめは画面が行う）。消したら一覧を読み直す。消せなければ誤りを返す（自動で再試行しない）。
    /// 届かなかったときも、消えているかもしれないので一覧を読み直す
    public func delete(_ schedule: RecordSchedule) async -> ErrorPresentation? {
        var failure: ErrorPresentation?
        do {
            try await service.delete(id: schedule.id)
        } catch {
            failure = ErrorText.present(error)
        }
        await reload()
        return failure
    }

}

/// 予約の画面の読み直し（体感の値。画面で見て決める）
public enum SchedulesRefresh {
    /// 世代が読めないときに一覧そのものを読み直す間（予約 100 件で 50 件ずつ 2 回の読み取りになるので、世代の見回りより長くする）
    public static let fallbackInterval: TimeInterval = 15
}

/// 予約の時期（今の時刻との前後）
public enum ScheduleTiming: Sendable, Equatable {
    case upcoming
    case recording
    case ended

    public init(_ schedule: RecordSchedule, now: Date) {
        if schedule.end <= now {
            self = .ended
        } else if schedule.start <= now {
            self = .recording
        } else {
            self = .upcoming
        }
    }
}

extension Channel {
    /// 予約で局を選ぶ鍵（帯域・ネットワーク・TS・サービス）。serviceID だけでは別の TS・帯域の同じ ID と取り違える
    /// （torne mobile HB §83。BS の予約のパッチで複合の鍵にした）
    public var scheduleKey: String { "\(broadcastingType):\(networkID):\(transportStreamID):\(serviceID)" }
}

/// 手動の予約の作成画面の既定の値（2026-11-19 に。torne mobile HB と同じ 60 分・DR）
public enum ScheduleCreationDefaults {
    public static let durationMinutes = 60
    public static let qualityMode = QualityMode.dr

    /// 開始の既定：今の次の正時（20:41 なら 21:00、21:00 ちょうどなら 22:00。nasne の時刻帯で数える）
    public static func start(after now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = NasneDateTime.timeZone
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        return calendar.date(byAdding: .hour, value: 1, to: hour) ?? now
    }
}

/// 番組表から予約する番組。局・開始・長さは番組のもので、入力では変えない
/// （nasne は番組の予約の開始と長さを番組に合わせて直す。torne mobile HB §74.7）
public struct ScheduleProgram: Sendable, Equatable {
    public var channel: Channel
    public var eventID: Int
    public var title: String
    public var start: Date
    public var durationSeconds: Int

    public init(channel: Channel, eventID: Int, title: String, start: Date, durationSeconds: Int) {
        self.channel = channel
        self.eventID = eventID
        self.title = title
        self.start = start
        self.durationSeconds = durationSeconds
    }

    /// 番組表の局と番組から作る。開始か長さの分からない番組は予約できない（nil）
    public init?(station: Channel, event: BroadcastEvent) {
        guard let start = event.start, let duration = event.duration, duration > 0 else { return nil }
        self.init(channel: station, eventID: Int(event.eventID), title: event.title, start: start, durationSeconds: duration)
    }

    public var end: Date { start.addingTimeInterval(TimeInterval(durationSeconds)) }

    /// 予約できる番組か（終わっていない。放送中も出す。torne mobile HB と同じ）
    public func isReservable(at now: Date) -> Bool { end > now }
}

/// 予約の作成のモデル。手動の予約（時刻を指定した予約。eventId 0）と、
/// 番組表からの予約（`program` がある。eventId 付き）。
///
/// 作る前に `X_GetConflictList` で重なる予約を読み、あれば一覧を見せて続けるかを聞く。作成は自動で再試行しない
/// （届かなくても作られていることがあるので、そのときは一覧を確かめるよう添える）
@MainActor
@Observable
public final class ScheduleCreationModel {
    public enum Phase: Sendable, Equatable {
        case editing
        /// 重なる予約を読んでいる
        case checking
        /// 重なる予約があり、続けるかを聞いている
        case confirmingConflicts([RecordSchedule])
        case creating
        /// 作れなかった。`mayHaveCreated` は、届かなかったなどで、作られているかが分からないとき
        case failed(ErrorPresentation, mayHaveCreated: Bool)
        /// 作った（一覧の形の ID）
        case created(String)

        public var isBusy: Bool {
            switch self {
            case .checking, .creating: true
            default: false
            }
        }
    }

    /// 選べる局（番組表と同じ並び）
    public let channels: [Channel]
    /// 選んだ局の鍵（`Channel.scheduleKey`）。serviceID だけでは局が決まらない（torne mobile HB §83）
    public var channelKey: String?
    /// 開始（分の単位。秒は送る前に切り捨てる）
    public var start: Date
    public var durationMinutes: Int
    public var qualityMode: Int
    public private(set) var phase = Phase.editing
    /// 番組表から予約する番組（手動の予約なら nil）
    public let program: ScheduleProgram?

    private let service: any ScheduleService
    private let now: @Sendable () -> Date

    public init(channels: [Channel], service: any ScheduleService, now: @escaping @Sendable () -> Date = Date.init) {
        self.channels = channels
        self.service = service
        self.now = now
        program = nil
        channelKey = channels.first?.scheduleKey
        start = ScheduleCreationDefaults.start(after: now())
        durationMinutes = ScheduleCreationDefaults.durationMinutes
        qualityMode = ScheduleCreationDefaults.qualityMode
    }

    /// 番組表から予約する（局・開始・長さは番組のもの。画質は既定から選ぶ）
    public init(program: ScheduleProgram, service: any ScheduleService, now: @escaping @Sendable () -> Date = Date.init) {
        channels = [program.channel]
        self.service = service
        self.now = now
        self.program = program
        channelKey = program.channel.scheduleKey
        start = program.start
        durationMinutes = max(1, Int((Double(program.durationSeconds) / 60).rounded(.up)))
        qualityMode = ScheduleCreationDefaults.qualityMode
    }

    /// 選んだ局（鍵が選べる局に無ければ nil。ほかの局へ黙って替えない）
    public var channel: Channel? { channels.first { $0.scheduleKey == channelKey } }

    /// 秒を切り捨てた開始（番組の予約は番組の開始のまま）
    var startMinute: Date {
        if let program { return program.start }
        return Date(timeIntervalSince1970: (start.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    /// 終わり（表示用）
    public var end: Date { program?.end ?? startMinute.addingTimeInterval(TimeInterval(durationMinutes * 60)) }

    /// 入力の誤り（無ければ nil）
    public var validationMessage: String? {
        if let program {
            return program.isReservable(at: now()) ? nil : "番組が終わっています"
        }
        if channel == nil { return "局を選んでください" }
        if durationMinutes < 1 { return "長さは 1 分以上にしてください" }
        if startMinute <= now() { return "開始の時刻が過ぎています" }
        return nil
    }

    /// 送る予約（入力に誤りがあれば nil）
    public var draft: NewRecordSchedule? {
        guard validationMessage == nil, let channel else { return nil }
        // 番組の eventId は、番組の局のときだけ載せる（別の局の番組の eventId を流用しない。torne mobile HB §83）
        let eventID = program.flatMap { $0.channel.scheduleKey == channel.scheduleKey ? $0.eventID : nil } ?? 0
        return NewRecordSchedule(
            start: startMinute, durationSeconds: program?.durationSeconds ?? durationMinutes * 60,
            channel: ScheduleChannel(broadcastingType: channel.broadcastingType, channelType: channel.broadcastingType,
                                     serviceID: channel.serviceID),
            networkID: channel.networkID, eventID: eventID, desiredQualityMode: qualityMode)
    }

    /// 重なる予約を確かめ、無ければ作る。あれば `confirmingConflicts` で止まる
    public func submit() async {
        guard !phase.isBusy, let draft else { return }
        phase = .checking
        do {
            let conflicts = try await service.conflicts(for: draft)
            if conflicts.isEmpty {
                await create(draft)
            } else {
                phase = .confirmingConflicts(conflicts)
            }
        } catch {
            phase = .failed(ErrorText.present(error), mayHaveCreated: false)
        }
    }

    /// 重なる予約があっても作る
    public func confirmConflicts() async {
        guard case .confirmingConflicts = phase, let draft else { return }
        await create(draft)
    }

    /// 重なる予約を見て、やめる（入力に戻る）
    public func cancelConflicts() {
        if case .confirmingConflicts = phase { phase = .editing }
    }

    /// 誤りを見たあと、入力に戻る
    public func dismissFailure() {
        if case .failed = phase { phase = .editing }
    }

    private func create(_ draft: NewRecordSchedule) async {
        phase = .creating
        do {
            phase = .created(try await service.create(draft))
        } catch {
            // 届かなかった・応答が読めなかったときは、nasne に届いて作られていることがある
            let unknown = (error as? NasneError).map { $0.category == .unreachable || $0.category == .parse } ?? true
            phase = .failed(ErrorText.present(error), mayHaveCreated: unknown)
        }
    }
}

/// 予約の画質の変更（疎な更新）。
///
/// 画質と、組の録画先を送り、priorityFlag は今の値のまま送る（2026-11-19）。nasne は受け付けても値を変えないことが
/// あるので、送った後は一覧を読み直し、読み直した値が変わっていなければそのことを出す。自動で再試行しない
@MainActor
@Observable
public final class ScheduleEditModel {
    public enum Phase: Sendable, Equatable {
        case editing
        case sending
        /// 送って読み直した。`reflected` は、読み直した画質が選んだ画質になっていたか
        case finished(reflected: Bool)
        /// 読み直したら、予約が一覧に無かった
        case missing
        /// 送れなかった。`mayHaveChanged` は、届かなかったなどで、変わったかが分からないとき
        case failed(ErrorPresentation, mayHaveChanged: Bool)
    }

    public let original: RecordSchedule
    public var qualityMode: Int
    public private(set) var phase = Phase.editing
    /// 読み直した予約（送った後）
    public private(set) var reread: RecordSchedule?

    private let service: any ScheduleService

    public init(original: RecordSchedule, service: any ScheduleService) {
        self.original = original
        self.service = service
        qualityMode = original.desiredQualityMode == QualityMode.threeTimes ? QualityMode.threeTimes : QualityMode.dr
    }

    /// 元の画質から変えたか（変えていなければ送らない）
    public var hasChange: Bool { qualityMode != original.desiredQualityMode }

    public func submit() async {
        guard hasChange, phase != .sending else { return }
        phase = .sending
        do {
            try await service.update(ScheduleUpdate.quality(qualityMode, of: original))
        } catch {
            let unknown = (error as? NasneError).map { $0.category == .unreachable || $0.category == .parse } ?? true
            phase = .failed(ErrorText.present(error), mayHaveChanged: unknown)
            return
        }
        // 受け付けられても変わらないことがあるので、読み直した値を正とする
        do {
            let found = try await service.schedules().first { $0.id == original.id }
            reread = found
            phase = found.map { .finished(reflected: $0.desiredQualityMode == qualityMode) } ?? .missing
        } catch {
            phase = .failed(ErrorText.present(error), mayHaveChanged: true)
        }
    }

    public func dismissFailure() {
        if case .failed = phase { phase = .editing }
    }
}
