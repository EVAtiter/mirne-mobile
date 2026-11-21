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
    /// nasne から取り直している途中か
    public private(set) var isRefreshing = false
    /// 一覧を出したまま取り直しに失敗したときの誤り（届かないなど）。取り直せたら消える
    public private(set) var refreshError: ErrorPresentation?
    /// 削除している録画の ID（送ってから一覧を読み直し終えるまで。2026-11-21 で行と下の欄に出す）
    public private(set) var deletingID: RecordedTitle.ID?

    private let services: NasneServices
    /// 局の一覧（ほかの画面と共通。並べ替えの局の順に使う）
    private let channelCatalog: ChannelCatalog
    private let library: LibraryStore?
    /// 視聴の状態（無ければ nasne の値だけで決める）
    private let viewing: ViewingRecorder?
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    /// `channels` は、ほかの画面と共通の局の一覧（無ければこのモデルだけのものを作る。試験）
    public init(services: NasneServices, channels: ChannelCatalog? = nil, library: LibraryStore? = nil, viewing: ViewingRecorder? = nil,
                defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.services = services
        channelCatalog = channels ?? ChannelCatalog(deviceInfo: services.deviceInfo)
        self.library = library
        self.viewing = viewing
        self.defaults = defaults
        self.now = now
        groupsByName = defaults.bool(forKey: Self.groupsByNameKey)
    }

    /// 録画の視聴の状態（手元の記録と nasne の値を合わせたもの）
    public func viewingState(of title: RecordedTitle) -> ViewingState {
        viewing?.state(of: title) ?? ViewingPolicy.resolve(title, local: nil)
    }

    /// 録画を再生させてよいか（この起動で nasne から一覧を取り直した後だけ）
    public var canPlay: Bool { titles.value != nil && !isShowingSavedList }

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

    /// 読み込み直す（選んでいた録画は、まだあれば選んだまま）。
    ///
    /// 一覧をまだ出していなければ、保存した一覧があればそれを先に出す。nasne から取り直せたら、その一覧を正として差し替えて保存する。
    /// 一覧を出したまま取り直しに失敗したら、一覧はそのままにして `refreshError` を立てる（出していなければ失敗を出す）
    public func reload() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let udn = services.registration.udn
        if titles.value == nil {
            if let saved = await library?.titleList(udn: udn) {
                titles = .loaded(saved.titles)
                fetchedAt = saved.fetchedAt
                counts = saved.counts
                isShowingSavedList = true
            } else {
                titles = .loading
            }
        }
        // 件数と上限・局の並びは、取れなくても一覧は出す。局の一覧はほかの画面と共通で、読み直すとほかの画面も新しくなる
        // （読み直しに失敗したら前の一覧のまま）
        let freshCounts = try? await services.deviceInfo.titleCounts()
        await channelCatalog.load(reload: true)
        if let channels = channelCatalog.channels.value {
            var order: [Int: Int] = [:]
            for (index, channel) in GuideLineupModel.lineup(channels, showsSubchannels: true).enumerated()
            where order[channel.serviceID] == nil {
                order[channel.serviceID] = index
            }
            channelOrder = order
        }
        do {
            let fresh = try await services.titles.titles()
            let fetched = now()
            titles = .loaded(fresh)
            fetchedAt = fetched
            counts = freshCounts
            isShowingSavedList = false
            refreshError = nil
            await library?.saveTitleList(SavedTitleList(titles: fresh, fetchedAt: fetched, counts: freshCounts), udn: udn)
        } catch {
            let presented = ErrorText.present(error)
            if titles.value != nil {
                refreshError = presented
            } else {
                titles = .failed(presented)
            }
        }
        if let selectedID, titles.value?.contains(where: { $0.id == selectedID }) != true {
            self.selectedID = nil
        }
    }

    /// 録画を消せないときの理由（消せるなら nil）
    public func deletionBlocker(_ title: RecordedTitle) -> RecordingDeletion.Blocker? {
        RecordingDeletion.blocker(title, isShowingSavedList: isShowingSavedList, isDeleting: deletingID != nil,
                                  isRefreshing: isRefreshing)
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
        await reload()
        if let failure { return failure }
        if let refreshError { return refreshError }
        if titles.value?.contains(where: { $0.id == title.id }) == true { return RecordingDeletion.stillListed }
        return nil
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
        /// 一覧を取り直している途中（取り直しの後に消すと、消えたかを読み直して確かめられないため）
        case refreshing

        public var text: String {
            switch self {
            case .protected: "保護されている録画は削除できません"
            case .recording: "録画中の録画は削除できません"
            case .savedList: "更新が終わってから削除できます"
            case .deleting: "ほかの録画を削除しています"
            case .refreshing: "一覧を更新しています"
            }
        }
    }

    public static func blocker(_ title: RecordedTitle, isShowingSavedList: Bool, isDeleting: Bool = false,
                               isRefreshing: Bool = false) -> Blocker? {
        if title.isProtected { return .protected }
        if title.isRecording { return .recording }
        if isShowingSavedList { return .savedList }
        if isDeleting { return .deleting }
        if isRefreshing { return .refreshing }
        return nil
    }

    /// nasne が受け付けたのに、読み直した一覧に残っているとき
    public static let stillListed = ErrorPresentation(
        title: "録画が一覧に残っています",
        message: "nasne は削除を受け付けましたが、一覧から消えていません。一覧を更新して確かめてください。")
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
        /// 前回の起動で保存した一覧を出していて、取り直しに失敗した（「更新」で取り直せば押せる。2026-11-20 に分けた）
        public static let savedListFailed = "更新できませんでした。もう一度更新すると再生できます"
        public static let starting = "再生を始めています…"
        public static let noResource = "この録画には再生できる画質がありません"
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
                            isRefreshing: Bool = false) -> RecordingPlayPanel {
        guard let title else { return .blocked(Reason.noSelection) }
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
