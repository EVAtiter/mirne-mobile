import Foundation
import Observation
import os

// 局のロゴ（番組表の局名の横と、録画・予約の一覧の行の頭に出す）。画面に共通の置き場。
//
// 地上・BS・CS のロゴを `chEpg/channelLogoDataGet` で取り、番組表の保存先（`epg.sqlite` の logos の表）にも保存する。
// 起動したときは保存したロゴをすぐ出し（保存した一覧と一緒に出るように）、nasne から 1 回読み直して差し替える。
// 番組表の「更新」でも読み直す。読めなくても誤りは出さず、前のロゴを残す（ロゴは飾りなので、ほかの画面を止めない）。
// ロゴの PNG はパレットの無い形で届くので、共通固定色を足したものを持つ（`EPGFormat.logos` が足す）。
// AppKit・SwiftUI に依存させない（絵に直すのは画面の側）

/// 局のロゴの置き場
@MainActor
@Observable
public final class ChannelLogoModel {
    /// ロゴ（放送の種類と serviceID → PNG）。読めるまでと、読めなかったときは空（保存したものがあればそれ）
    public private(set) var logos: [ChannelLogoKey: Data] = [:]
    /// 中身が変わるたびに進む（画面が絵を作り直す合図）
    public private(set) var revision = 0

    /// 取る放送の種類（地上・BS・CS）
    public static let bands = [BroadcastingType.terrestrial, BroadcastingType.bs, BroadcastingType.cs]

    private let source: (any ProgramGuideService)?
    private let store: EPGStore?
    /// nasne から読み終えたか（失敗したら false のまま、次に頼まれたときに読み直す）
    @ObservationIgnored public private(set) var fetched = false
    @ObservationIgnored private var fetching = false
    private static let logger = Logger(subsystem: AppLog.subsystem, category: "epg")

    public init(source: (any ProgramGuideService)?, store: EPGStore?) {
        self.source = source
        self.store = store
    }

    /// 保存したロゴを読む（起動したとき。すぐ返る）
    public func loadSaved() {
        guard let store else { return }
        let saved = store.logos()
        guard !saved.isEmpty else { return }
        logos = saved
        revision += 1
    }

    /// nasne から読み直す。読めた放送の種類だけ差し替えて保存する（読めなかった種類は前のロゴのまま）
    public func refresh() async {
        guard let source, !fetching else { return }
        fetching = true
        defer { fetching = false }
        var next = logos
        var counts: [String] = []
        var anyFetched = false
        for band in Self.bands {
            do {
                let fetched = try await source.logos(broadcastingType: band)
                next = next.filter { $0.key.broadcastingType != band }
                for (serviceID, png) in fetched { next[ChannelLogoKey(broadcastingType: band, serviceID: serviceID)] = png }
                store?.saveLogos(fetched, broadcastingType: band, receivedAt: Date())
                counts.append("\(band)=\(fetched.count)")
                anyFetched = true
            } catch {
                Self.logger.error("局のロゴ（種類 \(band, privacy: .public)）: 読めなかった（\(NasneDiagnostics.summary(error), privacy: .public)）")
            }
        }
        if anyFetched {
            fetched = true
            Self.logger.info("局のロゴ: \(counts.joined(separator: " "), privacy: .public)")
        }
        if next != logos {
            logos = next
            revision += 1
        }
    }

    /// 地上の局のロゴ（serviceID → PNG。番組表に使う）
    public var terrestrial: [Int: Data] {
        var result: [Int: Data] = [:]
        for (key, png) in logos where key.broadcastingType == BroadcastingType.terrestrial { result[key.serviceID] = png }
        return result
    }
}
