import Foundation
import Observation

/// 録画一覧と詳細のモデル。
///
/// 一覧は xsrs を主に DIDL を結合したもの（`TitleCatalogService`）。並べ替えは日時・局・ジャンル、
/// 絞り込みは番組名・局名と視聴の状態（未再生・途中まで）。同じ番組名の録画をまとめて見せられる。
///
/// 取った一覧は `LibraryStore` に保存し、次に起動したときは保存した一覧をすぐ出してから nasne に取り直す。
/// 保存した一覧を出している間は再生させない（res の URL・DTCP のポートが変わっていることがあり、録画が消えていることもある）
@MainActor
@Observable
public final class RecordingsModel {
    public enum SortOrder: String, CaseIterable, Sendable {
        case newestFirst
        case oldestFirst
        /// 局（番組表と同じ並び）。同じ局の中は新しい順（2026-11-20）
        case channel
        /// ジャンル（録画の最初のジャンルの ARIB の大分類の順）。同じジャンルの中は新しい順（2026-11-20）
        case genre
    }

    /// まとめる・まとめないの選択を保存する鍵（UserDefaults。：既定はまとめない）
    public static let groupsByNameKey = "recordingsGroupedByName"

    public private(set) var titles = Loadable<[RecordedTitle]>.idle
    /// 視聴の状態での絞り込み（選択は保存しない）
    public enum ViewingFilter: String, CaseIterable, Sendable {
        case all
        case unwatched
        case interrupted
    }

    /// 番組名・局名で絞り込む文字（空なら絞り込まない）
    public var searchText = ""
    /// 視聴の状態での絞り込み（2026-11-20 に「新着だけ」から替えた）
    public var viewingFilter = ViewingFilter.all
    public var sortOrder = SortOrder.newestFirst
    /// 選んだ録画の ID
    public var selectedID: RecordedTitle.ID?
    /// 同じ番組名の録画をまとめて見せるか（選択は保存する）
    public var groupsByName: Bool {
        didSet { defaults.set(groupsByName, forKey: Self.groupsByNameKey) }
    }
    /// 録画の件数と上限（取れなければ nil）
    public private(set) var counts: (count: Int, max: Int)?
    /// 局の並び（serviceID → 番組表の並びの番号。取れなければ空で、局名の順になる）
    public internal(set) var channelOrder: [Int: Int] = [:]
    /// 出している一覧を取った時刻
    public private(set) var fetchedAt: Date?
    /// 出している一覧が保存した一覧で、この起動ではまだ nasne から取り直せていないか（その間は再生させない）
    public private(set) var isShowingSavedList = false
    /// nasne から録画一覧を取り直している途中か（1 段目。この間は再生・削除・保護を待つ）
    public private(set) var isRefreshing = false
    /// 今の取り直しが見回りからのものか（知らせの帯に「更新しています」を出さない）
    public private(set) var isRefreshingAutomatically = false
    /// 取り直していることを知らせの帯に出すか（見回りからの取り直しは出さない）
    public var showsRefreshProgress: Bool { isRefreshing && !isRefreshingAutomatically }
    /// 全件の番組の情報を裏で読んでいる途中か（2 段目。一覧は使える）
    public private(set) var isCompletingMetadata = false
    /// 2 段目の読み込み（読み直したら捨てる）
    @ObservationIgnored private var metadataTask: Task<Void, Never>?
    /// 読み直した回数（古い 2 段目の結果を使わないため）
    @ObservationIgnored private var metadataGeneration = 0
    /// 一覧を出したまま取り直しに失敗したときの誤り（届かないなど）。取り直せたら消える
    public private(set) var refreshError: ErrorPresentation?
    /// 削除している録画の ID（送ってから一覧を読み直し終えるまで。2026-11-21 で行と下の欄に出す）
    public private(set) var deletingID: RecordedTitle.ID?
    /// 保護を切り替えている録画の ID（送ってから一覧を読み直し終えるまで）
    public private(set) var protectingID: RecordedTitle.ID?

    private let services: NasneServices
    /// 局の一覧（ほかの画面と共通。並べ替えの局の順に使う）
    private let channelCatalog: ChannelCatalog
    private let library: LibraryStore?
    /// 視聴の状態（無ければ nasne の値だけで決める）
    private let viewing: ViewingRecorder?
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    /// 集約ステータスの見回り（録画の一覧の世代。ほかの画面と共通。無ければ世代に頼らない読み直しだけ）
    private let liveStatus: LiveStatusMonitor?
    /// 読み直すかの判断（前に一覧を読んだときの世代と時刻）
    @ObservationIgnored private var tracker = ListRefreshTracker(fallbackInterval: RecordingsRefresh.fallbackInterval)

    /// `channels` は、ほかの画面と共通の局の一覧（無ければこのモデルだけのものを作る。試験）
    public init(services: NasneServices, channels: ChannelCatalog? = nil, library: LibraryStore? = nil, viewing: ViewingRecorder? = nil,
                liveStatus: LiveStatusMonitor? = nil, defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.services = services
        channelCatalog = channels ?? ChannelCatalog(deviceInfo: services.deviceInfo)
        self.library = library
        self.viewing = viewing
        self.liveStatus = liveStatus
        self.defaults = defaults
        self.now = now
        groupsByName = defaults.bool(forKey: Self.groupsByNameKey)
    }

    /// 見回りが最後に読んだ録画の一覧の世代（これが変わったら `refreshIfChanged` を呼ぶ）
    public var observedGeneration: Int? { liveStatus?.generations?.recordings }

    /// 見回りで読み直す。録画の一覧の世代が前に一覧を読んだときと違うとき（世代が読めないときは `RecordingsRefresh.fallbackInterval` ごと）だけ、
    /// 1 段目（録画一覧と新しい録画の番組の情報）を読み直す。局の一覧は読み直さず、2 段目（全件の番組の情報。約 11 秒）は、
    /// 新しい録画が多くて 1 件ずつ補えなかったときだけ読む。まだ一覧を出していない・取り直している途中は何もしない
    public func refreshIfChanged() async {
        guard liveStatus.allowsNasneRequests, titles.value != nil, !isRefreshing else { return }
        guard tracker.needsRefresh(observed: observedGeneration, now: now()) else { return }
        await reload(waitsForMetadata: false, automatic: true)
    }

    /// 一覧をまだ出していなければ、保存した一覧を出す（無ければ何もしない）
    private func showSavedListIfEmpty() async {
        guard titles.value == nil, let saved = await library?.titleList(udn: services.registration.udn) else { return }
        titles = .loaded(saved.titles)
        fetchedAt = saved.fetchedAt
        counts = saved.counts
        isShowingSavedList = true
    }

    /// 録画の視聴の状態（手元の記録と nasne の値を合わせたもの）
    public func viewingState(of title: RecordedTitle) -> ViewingState {
        viewing?.state(of: title) ?? ViewingPolicy.resolve(title, local: nil)
    }

    /// 録画を再生させてよいか（この起動で nasne から一覧を取り直した後だけ）
    public var canPlay: Bool { titles.value != nil && !isShowingSavedList && !isOffline }

    /// nasne に届かないか（つながっていない間は再生・削除・保護をさせない。2026-11-24）
    public var isOffline: Bool { !liveStatus.allowsNasneRequests }

    /// 並べ替えと絞り込みをした一覧
    public var visibleTitles: [RecordedTitle] { arrange(titles.value ?? []) }

    /// 絞り込んで並べ替える
    func arrange(_ all: [RecordedTitle]) -> [RecordedTitle] {
        all.filter(matches).sorted(by: isOrderedBefore)
    }

    /// まとめて見せる一覧。まとめの名前は絞り込む前の全部の録画で決め、絞り込みはまとめの中の録画に効かせる。
    /// 当てはまる録画の無いまとめは出さない。まとめの順は、中の先頭の録画の順
    public var visibleGroups: [RecordingGroup] { groups(titles.value ?? []) }

    /// 全部の録画でまとめの名前を決め、絞り込んで並べ替えた録画をまとめる
    func groups(_ all: [RecordedTitle]) -> [RecordingGroup] {
        let names = RecordingNameGrouping.groupNames(all)
        var order: [String] = []
        var members: [String: [RecordedTitle]] = [:]
        for title in arrange(all) {
            let name = names[title.id] ?? title.title
            if members[name] == nil { order.append(name) }
            members[name, default: []].append(title)
        }
        return order.map { name in
            let titles = members[name] ?? []
            return RecordingGroup(name: name, titles: titles,
                                  unwatchedCount: titles.filter { viewingState(of: $0) == .unwatched }.count)
        }
    }

    /// 絞り込みに当てはまるか
    private func matches(_ title: RecordedTitle) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = viewingFilter == .all ? nil : viewingState(of: title)
        let viewingMatches = switch viewingFilter {
        case .all: true
        case .unwatched: state == .unwatched
        case .interrupted: state?.resumeSeconds != nil
        }
        return viewingMatches
            && (query.isEmpty || title.title.localizedCaseInsensitiveContains(query)
                || (title.channelName?.localizedCaseInsensitiveContains(query) ?? false))
    }

    /// 並べ替えの順で `lhs` が先か
    private func isOrderedBefore(_ lhs: RecordedTitle, _ rhs: RecordedTitle) -> Bool {
        switch sortOrder {
        case .newestFirst: return Self.byDate(lhs, rhs, newestFirst: true)
        case .oldestFirst: return Self.byDate(lhs, rhs, newestFirst: false)
        case .channel:
            // 番組表の並びに無い局は後ろ（局名の順）
            let left = lhs.channel.flatMap { channelOrder[$0.serviceID] } ?? Int.max
            let right = rhs.channel.flatMap { channelOrder[$0.serviceID] } ?? Int.max
            if left != right { return left < right }
            let leftName = lhs.channelName ?? "", rightName = rhs.channelName ?? ""
            if leftName != rightName { return leftName.localizedStandardCompare(rightName) == .orderedAscending }
        case .genre:
            let left = RecordingGenreOrder.rank(lhs.genres.first), right = RecordingGenreOrder.rank(rhs.genres.first)
            if left != right { return left < right }
        }
        return Self.byDate(lhs, rhs, newestFirst: true)
    }

    /// 日時の順（日時の無いものは最後に）
    private static func byDate(_ lhs: RecordedTitle, _ rhs: RecordedTitle, newestFirst: Bool) -> Bool {
        switch (lhs.displayStart, rhs.displayStart) {
        case let (left?, right?) where left != right: newestFirst ? left > right : left < right
        case (.some, .none): true
        case (.none, .some): false
        default: lhs.id < rhs.id
        }
    }

    /// 選んだ録画
    public var selectedTitle: RecordedTitle? {
        guard let selectedID else { return nil }
        return titles.value?.first { $0.id == selectedID }
    }

    /// 読み込み直す（選んでいた録画は、まだあれば選んだまま）。2 段に分ける：
    ///
    /// 1. 録画一覧（`X_GetTitleList`。約 0.5 秒）だけを読み、出している一覧と突き合わせる（`RecordingListMerge`）。消えた録画を外し、
    ///    前からある録画は番組の情報（説明・ジャンル・再生の在りかなど）を保存した値のまま、保護・新着・録画中・続きの位置を nasne の値に直す。
    ///    新しい録画は、`metadataByItemLimit` 件までなら 1 件ずつ番組の情報を読んで補う。ここで一覧を正として保存し、再生・削除・保護を許す
    ///    （保存した再生の在りかは時間が経っても変わらなかった。2026-11-22・Buffalo 製で 3.2 時間）
    /// 2. 裏で全件の番組の情報（Browse。約 11 秒）を読み、番組の情報から入る項目だけを足し込んで保存する（`isCompletingMetadata`）。
    ///    この間に変えた保護などを、古い値で上書きしない。失敗しても知らせない（1 段目の一覧のまま）
    ///
    /// 一覧をまだ出していなければ、保存した一覧があればそれを先に出す。1 段目に失敗したら、一覧はそのままにして `refreshError` を立てる
    /// （出していなければ失敗を出す）。`waitsForMetadata` が偽なら 2 段目を待たずに返る（削除の後の読み直し）
    /// `automatic` は見回りからの読み直し（局の一覧を読み直さず、2 段目は要るときだけ）
    public func reload(waitsForMetadata: Bool = true, automatic: Bool = false) async {
        guard !isRefreshing else { return }
        // つながっていない間は nasne から読まず、保存した一覧があればそれだけを出す（つながったら読み直す）
        guard liveStatus.allowsNasneRequests else {
            await showSavedListIfEmpty()
            return
        }
        // 世代は一覧より先に控える（読んでいる間に変わったら、次の見回りで世代の違いとして見つかる）
        let listGeneration = observedGeneration
        // 走っている 2 段目は捨てる（結果を使わない）
        metadataGeneration += 1
        metadataTask?.cancel()
        isCompletingMetadata = false
        isRefreshing = true
        isRefreshingAutomatically = automatic
        defer { isRefreshingAutomatically = false }
        let udn = services.registration.udn
        if titles.value == nil {
            await showSavedListIfEmpty()
            if titles.value == nil { titles = .loading }
        }
        // 件数と上限・局の一覧・録画一覧を同時に読む。件数と局の並びは、取れなくても一覧は出す。
        // 局の一覧はほかの画面と共通で、読み直すとほかの画面も新しくなる（読み直しに失敗したら前の一覧のまま）
        let catalog = services.titles
        let deviceInfo = services.deviceInfo
        async let countsResult = try? deviceInfo.titleCounts()
        let listing = Task { try await catalog.titles(withMetadata: false) }
        await channelCatalog.load(reload: !automatic)
        if let channels = channelCatalog.channels.value {
            var order: [Int: Int] = [:]
            for (index, channel) in GuideLineupModel.lineup(channels, showsSubchannels: true).enumerated()
            where order[channel.serviceID] == nil {
                order[channel.serviceID] = index
            }
            channelOrder = order
        }
        let freshCounts = await countsResult
        let needsFullMetadata: Bool
        do {
            let listed = try await listing.value
            let merged = RecordingListMerge.merge(shown: titles.value ?? [], listed: listed,
                                                  channels: channelCatalog.channels.value ?? [])
            var list = merged.titles
            needsFullMetadata = merged.needsMetadata.count > Self.metadataByItemLimit
            if !needsFullMetadata {
                for id in merged.needsMetadata {
                    guard let index = list.firstIndex(where: { $0.id == id }),
                          let didl = try? await catalog.titleMetadata(id: id) else { continue }
                    list[index] = list[index].merging(didl)
                }
            }
            let fetched = now()
            titles = .loaded(list)
            fetchedAt = fetched
            counts = freshCounts
            isShowingSavedList = false
            refreshError = nil
            tracker.noteRead(generation: listGeneration, at: fetched)
            await library?.saveTitleList(SavedTitleList(titles: list, fetchedAt: fetched, counts: freshCounts), udn: udn)
        } catch {
            let presented = ErrorText.present(error)
            if titles.value != nil {
                // 見回りからの取り直しの失敗は知らせない（世代は覚えていないので、次の見回りでもう一度読む）
                if !automatic { refreshError = presented }
            } else {
                titles = .failed(presented)
            }
            dropMissingSelection()
            isRefreshing = false
            return
        }
        dropMissingSelection()
        isRefreshing = false
        if automatic && !needsFullMetadata { return }

        // 2 段目：全件の番組の情報
        let generation = metadataGeneration
        isCompletingMetadata = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.completeMetadata(generation: generation)
        }
        metadataTask = task
        if waitsForMetadata { await task.value }
    }

    /// 新しい録画を 1 件ずつ番組の情報で補う上限（これより多ければ、2 段目の全件の読み込みを待つ。保存した一覧の無い初回など）
    static let metadataByItemLimit = 20

    /// 2 段目：全件の番組の情報を読み、出している一覧に番組の情報から入る項目だけを足し込んで保存する。
    /// その間に一覧を読み直した（`generation` が進んだ）なら使わない
    private func completeMetadata(generation: Int) async {
        defer { if generation == metadataGeneration { isCompletingMetadata = false } }
        guard let full = try? await services.titles.titles(withMetadata: true),
              generation == metadataGeneration, !Task.isCancelled, let shown = titles.value else { return }
        let list = RecordingListMerge.completing(shown: shown, withMetadataFrom: full)
        titles = .loaded(list)
        if let fetchedAt {
            await library?.saveTitleList(SavedTitleList(titles: list, fetchedAt: fetchedAt, counts: counts), udn: services.registration.udn)
        }
    }

    /// 選んでいた録画が一覧から消えたら、選択を外す
    private func dropMissingSelection() {
        if let selectedID, titles.value?.contains(where: { $0.id == selectedID }) != true {
            self.selectedID = nil
        }
    }

    /// 録画を消せないときの理由（消せるなら nil）
    public func deletionBlocker(_ title: RecordedTitle) -> RecordingDeletion.Blocker? {
        RecordingDeletion.blocker(title, isShowingSavedList: isShowingSavedList, isDeleting: deletingID != nil,
                                  isProtecting: protectingID != nil, isRefreshing: isRefreshing, isOffline: isOffline)
    }

    /// 保護を切り替えられないときの理由（切り替えられるなら nil）
    public func protectionBlocker(_ title: RecordedTitle) -> RecordingProtection.Blocker? {
        RecordingProtection.blocker(title, isShowingSavedList: isShowingSavedList, isDeleting: deletingID != nil,
                                    isProtecting: protectingID != nil, isRefreshing: isRefreshing, isOffline: isOffline)
    }

    /// 録画の保護を切り替える（`protect` が真なら保護する）。自動で再試行しない。
    /// 送った後は録画の一覧（`X_GetTitleList`。番組の情報の Browse は読まない。約 0.5 秒）を読み直し、保護の印が変わったことを確かめて、
    /// 出している一覧と保存した一覧のその録画だけを直す。届かなかったときも、変わっているかもしれないので読み直す
    public func setProtection(_ title: RecordedTitle, protect: Bool) async -> ErrorPresentation? {
        guard protectionBlocker(title) == nil, title.isProtected != protect else { return nil }
        protectingID = title.id
        defer { protectingID = nil }
        var failure: ErrorPresentation?
        do {
            try await services.titles.setProtection(id: title.id, protect: protect)
        } catch {
            failure = ErrorText.present(error)
        }
        let listed: RecordedTitle?
        do {
            listed = try await services.titles.titles(withMetadata: false).first { $0.id == title.id }
        } catch {
            return failure ?? ErrorText.present(error)
        }
        if let listed { await applyProtection(listed.isProtected, to: title.id) }
        if let failure { return failure }
        guard let listed else { return RecordingProtection.notListed }
        return listed.isProtected == protect ? nil : RecordingProtection.unchanged
    }

    /// 出している一覧と保存した一覧の、その録画の保護の印だけを直す
    private func applyProtection(_ isProtected: Bool, to id: RecordedTitle.ID) async {
        guard var list = titles.value, let index = list.firstIndex(where: { $0.id == id }),
              list[index].isProtected != isProtected else { return }
        list[index].isProtected = isProtected
        titles = .loaded(list)
        guard !isShowingSavedList, let fetchedAt else { return }
        await library?.saveTitleList(SavedTitleList(titles: list, fetchedAt: fetchedAt, counts: counts), udn: services.registration.udn)
    }

    /// 録画を 1 件消す（確かめと、再生していれば先に止めるのは画面が行う）。自動で再試行しない。
    /// 送った後は一覧を読み直し（届かなかったときも、消えているかもしれないので読み直す）、手元のキャッシュと視聴の記録からも消す
    /// （`reload` が一覧を差し替えて保存する）。消えたことを一覧で確かめ、残っていれば誤りを返す
    public func delete(_ title: RecordedTitle) async -> ErrorPresentation? {
        guard deletionBlocker(title) == nil else { return nil }
        deletingID = title.id
        defer { deletingID = nil }
        var failure: ErrorPresentation?
        do {
            try await services.titles.deleteTitle(id: title.id)
        } catch {
            failure = ErrorText.present(error)
        }
        // 消えたかは録画一覧（1 段目）で確かめる。全件の番組の情報は待たない
        await reload(waitsForMetadata: false)
        if let failure { return failure }
        if let refreshError { return refreshError }
        if titles.value?.contains(where: { $0.id == title.id }) == true { return RecordingDeletion.stillListed }
        return nil
    }
}

/// 録画一覧の突き合わせ（2 段の取り直し。純粋な関数で、試験する）
public enum RecordingListMerge {
    /// 1 段目：録画一覧（xsrs だけ）を、出している一覧と突き合わせる。並びは録画一覧のまま。
    /// 前からある録画（ID と録り始めの日時が同じ）は番組の情報から入る項目を引き継ぐ。新しい録画は局名を番組表の局の一覧から引く。
    /// 番組の情報を補う録画（新しい録画と、前から再生の在りかが無かった録画）の ID も返す
    public static func merge(shown: [RecordedTitle], listed: [RecordedTitle], channels: [Channel])
        -> (titles: [RecordedTitle], needsMetadata: [RecordedTitle.ID]) {
        let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var needsMetadata: [RecordedTitle.ID] = []
        let titles = listed.map { title -> RecordedTitle in
            if let saved = byID[title.id], saved.start == title.start {
                if saved.resources.isEmpty { needsMetadata.append(title.id) }
                return title.keepingMetadata(of: saved)
            }
            needsMetadata.append(title.id)
            var added = title
            if let channel = title.channel {
                added.channelName = channels.first {
                    $0.serviceID == channel.serviceID && $0.broadcastingType == channel.broadcastingType
                }?.serviceName
            }
            return added
        }
        return (titles, needsMetadata)
    }

    /// 2 段目：出している一覧に、全件の読み込みの番組の情報から入る項目だけを足し込む。並びと、保護などの nasne の値は出している一覧のまま。
    /// 全件の読み込みにしか無い録画（読み込みの間に増えた）は後ろに足す
    public static func completing(shown: [RecordedTitle], withMetadataFrom full: [RecordedTitle]) -> [RecordedTitle] {
        let byID = Dictionary(full.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shownIDs = Set(shown.map(\.id))
        let updated = shown.map { title in
            guard let fresh = byID[title.id], fresh.start == title.start else { return title }
            return title.keepingMetadata(of: fresh)
        }
        return updated + full.filter { !shownIDs.contains($0.id) }
    }
}

/// 録画の削除の決まり（画面と試験で同じものを使う）
public enum RecordingDeletion {
    /// 消せない理由。保護・録画中は nasne に送らない（送ったときの振る舞いは測っていない）。
    /// 保存した一覧を出している間は、録画がもう無いこともあるので取り直してから（再生と同じ扱い）
    public enum Blocker: Sendable, Equatable {
        case protected
        case recording
        case savedList
        /// ほかの録画を削除している途中（1 件ずつ）
        case deleting
        /// 録画の保護を切り替えている途中
        case protecting
        /// 一覧を取り直している途中（取り直しの後に消すと、消えたかを読み直して確かめられないため）
        case refreshing
        /// nasne に届かない（2026-11-24）
        case offline

        public var text: String {
            switch self {
            case .protected: "保護されている録画は削除できません"
            case .recording: "録画中の録画は削除できません"
            case .savedList: "更新が終わってから削除できます"
            case .deleting: "ほかの録画を削除しています"
            case .protecting: "録画の保護を切り替えています"
            case .refreshing: "一覧を更新しています"
            case .offline: RecordingOffline.text
            }
        }
    }

    public static func blocker(_ title: RecordedTitle, isShowingSavedList: Bool, isDeleting: Bool = false,
                               isProtecting: Bool = false, isRefreshing: Bool = false, isOffline: Bool = false) -> Blocker? {
        if title.isProtected { return .protected }
        if title.isRecording { return .recording }
        if isOffline { return .offline }
        if isShowingSavedList { return .savedList }
        if isDeleting { return .deleting }
        if isProtecting { return .protecting }
        if isRefreshing { return .refreshing }
        return nil
    }

    /// nasne が受け付けたのに、読み直した一覧に残っているとき
    public static let stillListed = ErrorPresentation(
        title: "録画が一覧に残っています",
        message: "nasne は削除を受け付けましたが、一覧から消えていません。一覧を更新して確かめてください。")
}

/// nasne に届かないときの、録画の操作を押せない理由（再生・削除・保護で同じ文言）
public enum RecordingOffline {
    public static let text = "nasne が見つかりません。つながると操作できます"
}

/// 録画の保護の切り替えの決まり（画面と試験で同じものを使う）
public enum RecordingProtection {
    /// 切り替えられない理由。録画中は nasne に送らない（送ったときの振る舞いは測っていない。削除と同じ）。
    /// 保存した一覧を出している間は、取り直してから（今の状態が分からないため）
    public enum Blocker: Sendable, Equatable {
        case recording
        case savedList
        /// 録画を削除している途中
        case deleting
        /// ほかの録画の保護を切り替えている途中（1 件ずつ）
        case protecting
        /// 一覧を取り直している途中
        case refreshing
        /// nasne に届かない（2026-11-24）
        case offline

        public var text: String {
            switch self {
            case .recording: "録画中の録画は保護を切り替えられません"
            case .savedList: "更新が終わってから切り替えられます"
            case .deleting: "録画を削除しています"
            case .protecting: "ほかの録画の保護を切り替えています"
            case .refreshing: "一覧を更新しています"
            case .offline: RecordingOffline.text
            }
        }
    }

    public static func blocker(_ title: RecordedTitle, isShowingSavedList: Bool, isDeleting: Bool = false,
                               isProtecting: Bool = false, isRefreshing: Bool = false, isOffline: Bool = false) -> Blocker? {
        if title.isRecording { return .recording }
        if isOffline { return .offline }
        if isShowingSavedList { return .savedList }
        if isDeleting { return .deleting }
        if isProtecting { return .protecting }
        if isRefreshing { return .refreshing }
        return nil
    }

    /// nasne が受け付けたのに、読み直した一覧で保護の印が変わっていないとき
    public static let unchanged = ErrorPresentation(
        title: "保護が切り替わっていません",
        message: "nasne は受け付けましたが、一覧の保護の印が変わっていません。一覧を更新して確かめてください。")

    /// 読み直した一覧にその録画が無いとき（ほかの機器で消されたなど）
    public static let notListed = ErrorPresentation(
        title: "録画が一覧にありません",
        message: "ほかの機器で削除されたかもしれません。一覧を更新して確かめてください。")
}

/// ジャンルの並び（ARIB STD-B10 の大分類の順。DIDL の `upnp:genre` はこの名前で届く。2026-11-20 実機）
public enum RecordingGenreOrder {
    public static let names = ["ニュース／報道", "スポーツ", "情報／ワイドショー", "ドラマ", "音楽", "バラエティ", "映画",
                               "アニメ／特撮", "ドキュメンタリー／教養", "劇場／公演", "趣味／教育", "福祉", "その他"]

    /// 並びの番号。知らない名前は「その他」の後、ジャンルの無い録画はさらに後
    public static func rank(_ genre: String?) -> Int {
        guard let genre else { return names.count + 1 }
        return names.firstIndex(of: genre) ?? names.count
    }
}

/// 録画の表示の決まり（画面と試験で同じものを使う）
public enum RecordingFormat {
    /// 長さ（「1 時間 5 分」「25 分」「45 秒」）
    public static func duration(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let hours = seconds / 3600
        let minutes = seconds % 3600 / 60
        if hours > 0 { return minutes > 0 ? "\(hours) 時間 \(minutes) 分" : "\(hours) 時間" }
        if minutes > 0 { return "\(minutes) 分" }
        return "\(seconds) 秒"
    }

    /// 途中まで見た録画の残り（秒。途中まででない・長さが分からなければ nil）
    public static func remainingSeconds(_ state: ViewingState, duration: Int?) -> Int? {
        guard let position = state.resumeSeconds, let duration else { return nil }
        return max(0, duration - Int(position.rounded()))
    }

    /// 視聴の状態の表記（詳細）：「未再生」「見終わった」「途中まで（12 分・残り 25 分）」
    public static func viewing(_ state: ViewingState, duration: Int?) -> String {
        switch state {
        case .unwatched: return "未再生"
        case .completed: return "見終わった"
        case .interrupted(let seconds):
            let position = Self.duration(Int(seconds.rounded())) ?? "最初"
            guard let remaining = remainingSeconds(state, duration: duration), let left = Self.duration(remaining) else {
                return "途中まで（\(position)）"
            }
            return "途中まで（\(position)・残り \(left)）"
        }
    }

    /// 画質（公式の表記。知らない値は数のまま）
    public static func quality(_ mode: Int?) -> String? {
        mode.map(QualityMode.label)
    }

    /// 残りコピー回数（DIDL の `av:COGCount`）の表記。
    ///
    /// 値は最後のムーブを含む回数（ダビング 10 なら 10）。0 は「コピーできない」とは限らない：
    /// お引っ越しダビングで移した録画は 0 でも最後のムーブが残っている（pydtcpip の nasne の報告）。
    /// そのため 0 は回数に添え書きをする
    public static func copyCount(_ count: Int?) -> String? {
        guard let count else { return nil }
        return count == 0 ? "0 回（ムーブは残っていることがあります）" : "\(count) 回"
    }

    /// res の画質の表記（torne mobile HB の resQualityLabel と同じ。知らない値は元の値のまま）
    public static func resourceQuality(_ value: String?) -> String {
        switch value {
        case "dr": "DR"
        case "x3": "3倍"
        case TitleResource.mobileQuality: "モバイル"
        case let other?: other
        case nil: "元画質"
        }
    }
}

/// 一覧の下の欄の上の段：選んだ録画の再生のボタンか、押せない理由。
/// AppKit・SwiftUI に依存させない（iPad 版でも同じ欄にする）
public enum RecordingPlayPanel: Sendable, Equatable {
    /// 再生のボタン
    case actions([RecordingPlayAction], fromStart: RecordingPlayAction?)
    /// 押せない（ボタンを消して、その場所に出す理由）
    case blocked(String)

    /// 押せない理由の文言
    public enum Reason {
        public static let noSelection = "録画を選ぶと、ここに再生のボタンが出ます"
        /// 前回の起動で保存した一覧を出していて、いま取り直している（2026-11-20 に文言を改めた）
        public static let savedList = "更新しています。終わると再生できます"
        /// 前回の起動で保存した一覧を出していて、取り直しに失敗した（知らせの帯の「もう一度読み込む」で取り直せば押せる。2026-11-20 に分けた。
        /// 2026-11-24 に「更新」のボタンを外したので文言を改めた）
        public static let savedListFailed = "一覧を読み込めませんでした。「もう一度読み込む」を押すと再生できます"
        public static let starting = "再生を始めています…"
        public static let noResource = "この録画には再生できる画質がありません"
        /// nasne に届かない（2026-11-24）
        public static let offline = RecordingOffline.text
    }

    /// 「最初から」の文字
    public static let fromStartLabel = "最初から"

    /// 欄の中身を決める。
    ///
    /// - 画質ごとのボタン：元画質（録画の画質の名前で「DR再生」「3倍再生」）と、モバイルの版があれば「モバイル再生」
    /// - 途中まで見た録画では、どのボタンも続きから再生し、元画質の「最初から」（番組の開始から）を添える（2026-11-20 に決めた）
    /// - 押せないのは、録画を選んでいない・前回の起動で保存した一覧でまだ取り直せていない（`canPlay` が false。
    ///   この起動で一度取り直した一覧なら、後の取り直しが失敗しても押せる。2026-11-20 に決めた）・再生を始めている途中・再生できる版が無い
    /// - まだ取り直せていないときの理由は、取り直している途中（`isRefreshing`）か、失敗した後かで分ける（2026-11-20 に決めた）
    public static func make(title: RecordedTitle?, state: ViewingState, canPlay: Bool, isStarting: Bool,
                            isRefreshing: Bool = false, isOffline: Bool = false) -> RecordingPlayPanel {
        guard let title else { return .blocked(Reason.noSelection) }
        guard !isOffline else { return .blocked(Reason.offline) }
        guard canPlay else { return .blocked(isRefreshing ? Reason.savedList : Reason.savedListFailed) }
        guard !isStarting else { return .blocked(Reason.starting) }
        guard let original = title.originalResource else { return .blocked(Reason.noResource) }
        let from = state.resumeSeconds ?? title.playbackStartSeconds
        let originalName = RecordingFormat.resourceQuality(original.quality)
        var actions = [RecordingPlayAction(label: originalName + "再生", resource: original, from: from, buttonLabel: originalName)]
        if title.offersQualityChoice, let mobile = title.mobileResource {
            let mobileName = RecordingFormat.resourceQuality(mobile.quality)
            actions.append(RecordingPlayAction(label: mobileName + "再生", resource: mobile, from: from, buttonLabel: mobileName))
        }
        let fromStart = state.resumeSeconds == nil
            ? nil : RecordingPlayAction(label: fromStartLabel, resource: original, from: title.playbackStartSeconds, startsOver: true)
        return .actions(actions, fromStart: fromStart)
    }

    /// 一覧の行のダブルクリック・Return で行う再生（最初のボタンと同じ）
    public var primary: RecordingPlayAction? {
        if case .actions(let actions, _) = self { return actions.first }
        return nil
    }
}

/// 再生のボタン 1 つ（押したら `resource` を `from` 秒から再生する）
public struct RecordingPlayAction: Sendable, Equatable, Identifiable {
    /// 名前（ファイルのメニューの項目。絵が無いので「DR再生」のように再生と書く）
    public var label: String
    public var resource: TitleResource
    /// 録画の頭からの秒
    public var from: Double
    /// 再生中の同じ録画でも、切り替えずに始め直すか（「最初から」。画質のボタンは、再生中の録画なら画質の切り替えになる）
    public var startsOver = false
    /// 浮かべるボタンの名前（三角の絵で再生と分かるので画質の名前だけ。「DR」「3倍」「モバイル」。2026-11-21）。無ければ `label`
    public var buttonLabel: String? = nil

    public var id: String { label }
}

/// 録画の一覧の読み直し（体感の値）
public enum RecordingsRefresh {
    /// 世代が読めないときに一覧を読み直す間（録画一覧は数百件で約 0.5 秒かかるので、予約の一覧より長くする）
    public static let fallbackInterval: TimeInterval = 60
}
