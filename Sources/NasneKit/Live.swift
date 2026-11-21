// torne mobile HB（MIT、© mar1mo-41414）の lib/core/services/live_catalog.dart・models/live_channel.dart・
// parsing/didl.dart の liveChannelFromDidl を Swift へ移植したもの（plan.md §39）。
//
// ライブの局は DMS の `0/video/LiveTuner` の木にある：直下が帯域の container（地上・BS・CS）、
// その下が局の item。局の res は録画と同じ形の DTCP-IP の在りか（`/web/video/ch?nid=&tsid=&svid=&quality=`）。
// 一覧を読むのは Browse だけで、チューナーは動かない。受信（GET）は別の段。

import Foundation

/// ライブの帯域 1 つ（地上・BS・CS）と、その局
public struct LiveBand: Sendable, Equatable {
    /// 例：`0/video/LiveTuner/DTTB`
    public var containerID: String
    /// nasne の付けた帯域の名前（例：地上デジタル）
    public var title: String
    public var channels: [LiveChannel]
}

/// ライブの局 1 つと、いま放送中の番組（一覧を読んだ時点のもの。番組の境目では古くなる）
public struct LiveChannel: Sendable, Equatable {
    /// DIDL の item id（例：`0/video/LiveTuner/DTTB/ch?nid=…&tsid=…&svid=…`）
    public var id: String
    /// 載っていた帯域の container id
    public var bandID: String
    /// item id の問い合わせの 16 進の値。`channelListGet` の 10 進の値と同じ空間（plan.md §39）
    public var networkID: Int?
    public var transportStreamID: Int?
    public var serviceID: Int?
    public var channelName: String?
    public var channelNumber: Int?
    /// いま放送中の番組
    public var programTitle: String
    public var programStart: Date?
    public var programEnd: Date?
    /// dr・x3・mobile（録画と同じ形）
    public var resources: [TitleResource]

    /// item id の問い合わせのうち、局を示す 16 進の値の名前
    static let networkIDParameter = "nid"
    static let transportStreamIDParameter = "tsid"
    static let serviceIDParameter = "svid"

    init(item: DIDLItem) {
        id = item.id
        bandID = item.parentID
        func hexParameter(_ name: String) -> Int? {
            guard let query = item.id.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
            for pair in query.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0] == name { return Int(parts[1], radix: 16) }
            }
            return nil
        }
        networkID = hexParameter(Self.networkIDParameter)
        transportStreamID = hexParameter(Self.transportStreamIDParameter)
        serviceID = hexParameter(Self.serviceIDParameter)
        channelName = item.channelName
        channelNumber = item.channelNumber
        programTitle = item.title
        programStart = item.scheduledStart
        programEnd = item.scheduledEnd
        resources = item.resources
    }

    /// 値から作る（試験・プレビュー）
    init(id: String, bandID: String, networkID: Int?, transportStreamID: Int?, serviceID: Int?,
         channelName: String? = nil, programTitle: String = "", resources: [TitleResource]) {
        self.id = id
        self.bandID = bandID
        self.networkID = networkID
        self.transportStreamID = transportStreamID
        self.serviceID = serviceID
        self.channelName = channelName
        self.programTitle = programTitle
        self.resources = resources
    }

    /// 元画質の在りか（録画と同じ選び方。plan.md §33）
    public var originalResource: TitleResource? {
        resources.first { $0.quality != TitleResource.mobileQuality } ?? resources.first
    }
}

/// ライブの局の一覧を読む（DLNA の Browse だけ。チューナーは動かない）
public struct DLNALiveCatalogService: Sendable {
    private let catalog: RecordingCatalogService

    public init(catalog: RecordingCatalogService) {
        self.catalog = catalog
    }

    /// 木の在りか（ライブの木の根・帯域の名前。機器の表）
    private var dlna: DLNATable { catalog.profile.dlna }

    /// 帯域ごとの局。帯域は nasne の並びのまま、局も帯域の中の並びのまま
    public func bands() async throws -> [LiveBand] {
        var bands: [LiveBand] = []
        for case .container(let container) in try await catalog.browseEntries(dlna.liveTunerContainer) {
            // 帯域の中は頁送りが要る（BS は 78 件。plan.md §39.1）
            let channels = try await catalog.browse(container.id).map(LiveChannel.init(item:))
            bands.append(LiveBand(containerID: container.id, title: container.title, channels: channels))
        }
        return bands
    }

    /// 1 つの放送の種別の帯域の局（帯域の container id の末尾は機器の表から引く。例：地上は `DTTB`）。
    /// ほかの帯域は Browse しない（BS・CS は頁送りで時間がかかる）。帯域が無ければ空
    public func channels(broadcastingType: Int) async throws -> [LiveChannel] {
        guard let band = dlna.liveBandSuffixes[broadcastingType] else { return [] }
        for case .container(let container) in try await catalog.browseEntries(dlna.liveTunerContainer)
        where container.id.hasSuffix("/" + band) {
            return try await catalog.browse(container.id).map(LiveChannel.init(item:))
        }
        return []
    }
}
