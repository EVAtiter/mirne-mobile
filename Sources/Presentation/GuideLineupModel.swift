import Foundation
import Observation
import os

// 番組表に並べる局。
//
// 局は nasne のチャンネル一覧（`status/channelListGet`。地上）から作る。一覧はほかの画面と共通の `ChannelCatalog` が持つ。テレビのサービスだけを並べ、
// サブチャンネル（同じ TS の中の、本チャンネルでないテレビのサービス。`Channel.subchannelServiceIDs`）は既定で隠す。
// 局のロゴ（`chEpg/channelLogoDataGet`）もここで持つ。ロゴはメモリにだけ置き（ディスクに書かない）、
// 取れなくても番組表は出す（ロゴの無い局名だけになる。torne mobile HB と同じ）。
// AppKit・SwiftUI に依存させない。

/// 番組表に並べる局の一覧のモデル
@MainActor
@Observable
public final class GuideLineupModel {
    /// 局の一覧（共通の `ChannelCatalog` のもの）
    public var channels: Loadable<[Channel]> { catalog.channels }
    /// サブチャンネルも並べるか（既定は隠す）
    public var showsSubchannels: Bool
    /// 局のロゴ（serviceID → PNG）。読めるまでと、読めなかったときは空
    public private(set) var logos: [Int: Data] = [:]

    private let catalog: ChannelCatalog
    private let logoSource: (any ProgramGuideService)?
    /// ロゴを読み終えたか（失敗したら false のまま、次に開いたときに読み直す）
    @ObservationIgnored private var logosLoaded = false
    @ObservationIgnored private var loadingLogos = false
    private static let logger = Logger(subsystem: AppLog.subsystem, category: "epg")

    public init(channels: ChannelCatalog, logoSource: (any ProgramGuideService)? = nil, showsSubchannels: Bool = false) {
        catalog = channels
        self.logoSource = logoSource
        self.showsSubchannels = showsSubchannels
    }

    /// 並べる局（リモコンキーの順。サブチャンネルは同じ局の本チャンネルのすぐ右。キーの無い局は後ろ）
    public var lineup: [Channel] {
        guard let channels = channels.value else { return [] }
        return Self.lineup(channels, showsSubchannels: showsSubchannels)
    }

    /// 読み込む（読み込み済みなら読み直さない。失敗していたら読み直す）
    public func load() async {
        await catalog.load()
    }

    /// 局のロゴを読む。読み終えていたら、`reload`（手動の更新）のときだけ読み直す。
    /// 失敗しても誤りは出さず、前に読めたロゴを残す（ロゴは番組表の飾りなので、番組表を止めない）
    public func loadLogos(reload: Bool = false) async {
        guard let logoSource, !loadingLogos, reload || !logosLoaded else { return }
        loadingLogos = true
        defer { loadingLogos = false }
        do {
            logos = try await logoSource.logos(broadcastingType: BroadcastingType.terrestrial)
            logosLoaded = true
            Self.logger.info("局のロゴ: \(self.logos.count, privacy: .public) 件")
        } catch {
            Self.logger.error("局のロゴ: 読めなかった（\(NasneDiagnostics.summary(error), privacy: .public)）")
        }
    }

    /// テレビのサービスを並べる。サブチャンネルは `showsSubchannels` のときだけ。
    ///
    /// 並びは局（同じネットワーク・TS）ごとに、その局のリモコンキーの順。局の中は本チャンネル、サブチャンネルの順（serviceID の順）。
    /// nasne はサブチャンネルのリモコンキーを 0 で返すので、0 はキーが無いものとして扱い、局のキーは本チャンネルのものを使う
    /// （0 をそのまま並べると、サブチャンネルが左端にまとまり、番組の無い列ばかりが見えた。2026-11-19 実機）
    nonisolated static func lineup(_ channels: [Channel], showsSubchannels: Bool) -> [Channel] {
        let subchannels = Channel.subchannelServiceIDs(channels)
        let television = channels
            .filter { $0.serviceType == Channel.televisionServiceType }
            .filter { showsSubchannels || !subchannels.contains($0.serviceID) }
        // 局ごとのリモコンキー（その局のテレビのサービスの、0 でない最小のキー）
        var stationKeys: [[Int]: Int] = [:]
        for channel in channels where channel.serviceType == Channel.televisionServiceType {
            guard let key = channel.remoteControlKey else { continue }
            let station = [channel.networkID, channel.transportStreamID]
            stationKeys[station] = min(stationKeys[station] ?? key, key)
        }
        func sortKey(_ channel: Channel) -> (Int, Int, Int, Int) {
            let stationKey = stationKeys[[channel.networkID, channel.transportStreamID]]
            // キーのある局が先（キーの順）、無い局は後ろ（TS の順）。局の中は本チャンネルが先、その後は serviceID の順
            return (stationKey == nil ? 1 : 0, stationKey ?? channel.transportStreamID,
                    subchannels.contains(channel.serviceID) ? 1 : 0, channel.serviceID)
        }
        return television.sorted { sortKey($0) < sortKey($1) }
    }
}
