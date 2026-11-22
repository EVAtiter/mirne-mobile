import Foundation
import Observation
import os

// ライブで見る局。
//
// 並べる局は番組表と同じ（nasne のチャンネル一覧〔地上〕から、リモコンキーの順。サブチャンネルは番組表の設定に従う。
// 2026-11-20 に決めた）。それぞれを DLNA のライブの局（`0/video/LiveTuner/DTTB` の item）と、nid・tsid・svid の組で突き合わせる
// （同じ空間であることは で確かめた）。ライブの局に無い・配信の在りかの無い局は、見られない局として理由を添える。
// 帯域は地上だけ（BS・CS は受信を確かめていないので、確かめられるようになったら考え直す。2026-11-20 に決めた）。
// AppKit・SwiftUI に依存させない。

/// ライブで見る局の鍵（ネットワーク・TS・サービスの組。番組表の局と同じ空間）
public struct LiveStationKey: Sendable, Hashable {
    public var networkID: Int
    public var transportStreamID: Int
    public var serviceID: Int

    public init(networkID: Int, transportStreamID: Int, serviceID: Int) {
        self.networkID = networkID
        self.transportStreamID = transportStreamID
        self.serviceID = serviceID
    }

    public init(_ channel: Channel) {
        self.init(networkID: channel.networkID, transportStreamID: channel.transportStreamID, serviceID: channel.serviceID)
    }

    /// ライブの局の鍵（item id の問い合わせが読めなければ nil）
    public init?(_ live: LiveChannel) {
        guard let networkID = live.networkID, let transportStreamID = live.transportStreamID, let serviceID = live.serviceID else {
            return nil
        }
        self.init(networkID: networkID, transportStreamID: transportStreamID, serviceID: serviceID)
    }

    /// 保存する形（`ネットワーク-TS-サービス` の 10 進）
    public var storageValue: String { "\(networkID)-\(transportStreamID)-\(serviceID)" }

    public init?(storageValue: String) {
        let parts = storageValue.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(networkID: parts[0], transportStreamID: parts[1], serviceID: parts[2])
    }
}

/// ライブで見る局 1 つ（番組表の局と、突き合わせたライブの局）
public struct LiveStation: Sendable, Equatable, Identifiable {
    /// 番組表の局（局名・リモコンキー）
    public var channel: Channel
    /// 突き合わせたライブの局（ライブの局の一覧に無ければ nil）
    public var live: LiveChannel?

    public var key: LiveStationKey { LiveStationKey(channel) }
    public var id: LiveStationKey { key }

    /// 受信する配信の在りか（元画質。録画と同じ選び方）
    public var resource: TitleResource? { live?.originalResource }

    /// 切り替えられる画質（nasne の返した順。DR・3倍・モバイル）
    public var qualityChoices: [TitleResource] { live?.resources.filter { !$0.isMoveOnly } ?? [] }

    /// 画質 `quality` の配信の在りか。その画質が無ければ元画質
    public func resource(preferring quality: String?) -> TitleResource? {
        qualityChoices.first { $0.quality == quality } ?? resource
    }

    /// 見られない理由（見られるなら nil）
    public var unavailableReason: String? {
        if live == nil { return LiveText.notInLiveList }
        if resource == nil { return LiveText.noResource }
        return nil
    }
}

/// ライブの局で、見られるかどうか（番組表のボタンを灰色にするか）
public enum LiveAvailability: Sendable, Equatable {
    /// 見られる
    case available
    /// まだ分からない（読み込み中・読めなかった）。押せるようにし、押してから確かめる
    case unknown
    /// 見られない（理由）
    case unavailable(String)
}

/// ライブの画面の文言
public enum LiveText {
    static let notInLiveList = "nasne のライブの局の一覧にありません"
    static let noResource = "nasne がこの局の配信の在りかを返しません"
    static let noStation = "ライブで見られる局がありません"
}

/// リモコンキーとキーボードの対応。1〜9・0（10）・-（11）・^（12）。JIS 配列の数字の行に合わせる（mirne の RemoteControlKeys と同じ）
public enum LiveRemoteKeys {
    public static let keys: [(number: Int, character: Character)] = [
        (1, "1"), (2, "2"), (3, "3"), (4, "4"), (5, "5"), (6, "6"),
        (7, "7"), (8, "8"), (9, "9"), (10, "0"), (11, "-"), (12, "^"),
    ]

    /// 打った文字のリモコンキー（数字の行でなければ nil）
    public static func number(for character: Character) -> Int? {
        keys.first { $0.character == character }?.number
    }
}

/// 局の並べ方と選び方（純粋な関数。試験する）
public enum LiveLineup {
    /// 番組表の局（`channels`）を番組表と同じ順に並べ、ライブの局を突き合わせる
    public static func stations(channels: [Channel], live: [LiveChannel], showsSubchannels: Bool) -> [LiveStation] {
        var byKey: [LiveStationKey: LiveChannel] = [:]
        for channel in live {
            guard let key = LiveStationKey(channel), byKey[key] == nil else { continue }
            byKey[key] = channel
        }
        return GuideLineupModel.lineup(channels, showsSubchannels: showsSubchannels)
            .map { LiveStation(channel: $0, live: byKey[LiveStationKey($0)]) }
    }

    /// `current` から `offset`（↑ は -1・↓ は +1）だけ動いた先の、見られる局（端では反対の端へ回る。mirne と同じ）。
    ///
    /// `visible` は並べている局、`all` はサブチャンネルも含めた全部の局（同じ順）。いまの局が `visible` に無い
    /// （番組表から隠したサブチャンネルを見ている）ときは、`all` の中の位置から、その向きで次に `visible` にある局へ動く。
    /// いまの局が無ければ、最初の見られる局（↓）か最後の見られる局（↑）
    public static func step(from current: LiveStationKey?, offset: Int, visible: [LiveStation], all: [LiveStation]) -> LiveStation? {
        let candidates = visible.filter { $0.unavailableReason == nil }
        guard !candidates.isEmpty, offset != 0 else { return nil }
        let direction = offset > 0 ? 1 : -1
        // 全部の局の中の位置（見られない局も含めた順）
        let order = all.isEmpty ? visible : all
        guard let current, let start = order.firstIndex(where: { $0.key == current }) else {
            return direction > 0 ? candidates.first : candidates.last
        }
        let wanted = Set(candidates.map(\.key))
        var remaining = abs(offset)
        var index = start
        var found: LiveStation?
        for _ in 0..<(order.count * abs(offset)) {
            index = (index + direction + order.count) % order.count
            guard wanted.contains(order[index].key) else { continue }
            found = order[index]
            remaining -= 1
            if remaining == 0 { break }
        }
        return found
    }

    /// リモコンキー `number` の局（並べている局の中で、そのキーを持つ最初の見られる局）
    public static func station(remoteKey number: Int, in stations: [LiveStation]) -> LiveStation? {
        stations.first { $0.channel.remoteControlKey == number && $0.unavailableReason == nil }
    }

    /// ライブを始めるときの局：前に見た局が見られればそれ、無ければ並べている最初の見られる局
    /// 録画中の録画の局（見られる局の中で。録画中の録画が無い・その局が見られなければ nil）。
    /// nasne はチューナーが 1 つで、録画している間は、録画している局しかライブで見られない（ほかの局は配信が 511 で断られた。2026-11-22・Buffalo 製）
    public static func recordingStation(_ titles: [RecordedTitle], in stations: [LiveStation]) -> LiveStation? {
        for title in titles where title.isRecording {
            guard let channel = title.channel else { continue }
            if let station = stations.first(where: {
                $0.channel.serviceID == channel.serviceID && $0.channel.broadcastingType == channel.broadcastingType
                    && $0.unavailableReason == nil
            }) {
                return station
            }
        }
        return nil
    }

    public static func initialStation(last: LiveStationKey?, visible: [LiveStation], all: [LiveStation]) -> LiveStation? {
        if let last, let station = (all + visible).first(where: { $0.key == last }), station.unavailableReason == nil {
            return station
        }
        return visible.first { $0.unavailableReason == nil }
    }
}

/// ライブの設定の鍵（UserDefaults）
public enum LiveSettingsKey {
    /// 前に見た局（`LiveStationKey.storageValue`）。登録を外したら消す
    public static let lastStation = "liveLastStation"
    /// ライブを始めるときの画質（`LiveQuality` の rawValue。未設定なら DR）
    public static let defaultQuality = "liveDefaultQuality"
}

/// ライブの既定の画質の選択肢（設定。値は res の URL の `quality`）
public enum LiveQuality: String, CaseIterable, Sendable {
    case dr
    case x3
    case mobile

    /// 設定の既定（初めて使うとき）
    public static let initial = LiveQuality.dr

    /// 画面に出す名前（録画の画質の名前と同じ）
    public var label: String { RecordingFormat.resourceQuality(rawValue) }

    /// 保存した値（知らない値・未設定なら既定）
    public static func saved(_ value: String?) -> LiveQuality {
        value.flatMap(LiveQuality.init(rawValue:)) ?? initial
    }
}

/// 再生中の画質の切り替えの順（Q キーで次へ）
public enum PlaybackQuality {
    /// `choices` の中で `current` の次の画質（最後なら最初へ回る。`current` が無ければ最初）。選べる画質が 2 つ未満なら nil
    public static func next(after current: TitleResource?, in choices: [TitleResource]) -> TitleResource? {
        guard choices.count > 1 else { return nil }
        guard let current, let index = choices.firstIndex(where: { $0.quality == current.quality }) else { return choices.first }
        return choices[(index + 1) % choices.count]
    }

    /// 録画で切り替えられる画質（元画質と、あればモバイル）
    public static func choices(of title: RecordedTitle) -> [TitleResource] {
        guard let original = title.originalResource else { return [] }
        if title.offersQualityChoice, let mobile = title.mobileResource { return [original, mobile] }
        return [original]
    }
}

/// ライブで見る局のモデル（登録した nasne ごとに 1 つ。主ウィンドウの番組表と視聴ウィンドウが同じものを見る）
@MainActor
@Observable
public final class LiveModel {
    /// 番組表の局（nasne のチャンネル一覧。地上。ほかの画面と共通の `ChannelCatalog` のもの）
    public var channels: Loadable<[Channel]> { channelCatalog.channels }
    /// ライブの局（DLNA の Browse。地上の帯域だけ）
    public private(set) var liveChannels: Loadable<[LiveChannel]> = .idle
    /// 局ごとの放送中の番組名（番組表から引く。番組表に無ければライブの item の番組名）
    public private(set) var programs: [LiveStationKey: String] = [:]

    private let channelCatalog: ChannelCatalog
    private let catalog: any LiveCatalogService
    private let programGuide: EPGStore?
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    @ObservationIgnored private var loading: Task<Void, Never>?
    private static let logger = Logger(subsystem: AppLog.subsystem, category: "live")

    public init(channels: ChannelCatalog, catalog: any LiveCatalogService, programGuide: EPGStore?,
                defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = Date.init) {
        channelCatalog = channels
        self.catalog = catalog
        self.programGuide = programGuide
        self.defaults = defaults
        self.now = now
    }

    /// 前に見た局
    public var lastStation: LiveStationKey? {
        get { defaults.string(forKey: LiveSettingsKey.lastStation).flatMap(LiveStationKey.init(storageValue:)) }
        set { defaults.set(newValue?.storageValue, forKey: LiveSettingsKey.lastStation) }
    }

    /// 並べる局（番組表と同じ順）
    public func stations(showsSubchannels: Bool) -> [LiveStation] {
        guard let channels = channels.value else { return [] }
        return LiveLineup.stations(channels: channels, live: liveChannels.value ?? [], showsSubchannels: showsSubchannels)
    }

    /// 鍵の局（サブチャンネルも含めて探す）
    public func station(_ key: LiveStationKey) -> LiveStation? {
        stations(showsSubchannels: true).first { $0.key == key }
    }

    /// 番組表の局をライブで見られるか
    public func availability(of channel: Channel) -> LiveAvailability {
        guard channels.value != nil, liveChannels.value != nil else { return .unknown }
        guard let station = station(LiveStationKey(channel)) else { return .unavailable(LiveText.notInLiveList) }
        return station.unavailableReason.map(LiveAvailability.unavailable) ?? .available
    }

    /// 局の一覧とライブの局を読む。`reload` なら読み終えていても読み直す（ライブのボタンを押したとき。放送中の番組名を新しくする）。
    /// 読んでいる間にもう一度呼ばれたら、同じ読み込みを待つ
    public func load(reload: Bool = false) async {
        if let loading {
            await loading.value
            return
        }
        let needsChannels = channels.value == nil || reload
        let needsLive = liveChannels.value == nil || reload
        guard needsChannels || needsLive else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            if needsChannels { await self.channelCatalog.load(reload: true) }
            if needsLive { await self.loadLiveChannels() }
            await self.refreshPrograms()
        }
        loading = task
        await task.value
        loading = nil
    }

    private func loadLiveChannels() async {
        if liveChannels.value == nil { liveChannels = .loading }
        do {
            let live = try await catalog.channels(broadcastingType: BroadcastingType.terrestrial)
            liveChannels = .loaded(live)
            Self.logger.info("ライブの局: \(live.count, privacy: .public) 件")
        } catch {
            Self.logger.error("ライブの局を読めない: \(NasneDiagnostics.summary(error), privacy: .public)")
            if liveChannels.value == nil { liveChannels = .failed(ErrorText.present(error)) }
        }
    }

    /// 放送中の番組名を引き直す（番組表から。番組表に無い局は、ライブの item の番組名）
    public func refreshPrograms() async {
        let stations = stations(showsSubchannels: true)
        guard !stations.isEmpty else { return }
        let at = now()
        var names: [LiveStationKey: String] = [:]
        if let programGuide {
            let keys = stations.map { EPGStore.ServiceKey(networkID: $0.key.networkID, transportStreamID: $0.key.transportStreamID,
                                                          serviceID: $0.key.serviceID) }
            let schedules = await programGuide.schedules(of: keys, overlapping: at..<at.addingTimeInterval(1))
                .map { $0.normalizingBroadcastMarks() }
            for (station, schedule) in zip(stations, schedules) {
                if let event = schedule.events.first(where: { ($0.start ?? .distantFuture) <= at && at < ($0.end ?? .distantFuture) }),
                   !event.title.isEmpty {
                    names[station.key] = event.title
                }
            }
        }
        for station in stations where names[station.key] == nil {
            if let title = station.live?.programTitle, !title.isEmpty { names[station.key] = title }
        }
        programs = names
    }
}
