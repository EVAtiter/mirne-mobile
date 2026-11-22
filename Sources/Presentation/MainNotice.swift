import Foundation
import Observation

// 主ウインドウの上の帯に出す知らせ（2026-11-21）。
// 主ウインドウの全部の画面の、読み込み中・誤り・操作の結果の知らせを、nasne を探しているときと同じ帯にまとめて出す。
// 一覧の場所や一覧の下の欄には出さない。答えを求める確かめ（削除しますか？）はダイアログのまま。
// 知らせは 2 種類：モデルの状態（読み込み中・読み込めなかった）から毎回作るものと、操作の結果として置くもの（削除できなかった・予約した）

/// 知らせの種類（帯の印と、閉じられるかを決める）
public enum MainNoticeKind: Sendable, Equatable {
    /// 読み込み中・探している（閉じられない。終われば消える）
    case progress
    /// 誤り（閉じられる）
    case error
    /// 操作がうまくいった（閉じられる。少したつと消える）
    case success
}

/// 知らせのボタンが行うこと
public enum MainNoticeAction: Sendable, Equatable {
    /// nasne を探し直す
    case retryConnection
    case reloadRecordings
    case reloadSchedules
    case reloadInfo
    /// 番組表を更新する
    case refreshGuide
    /// 局の一覧を読み込み直す
    case reloadLineup

    /// ボタンの名前
    public var title: String {
        switch self {
        case .retryConnection: "探し直す"
        case .refreshGuide: "更新"
        case .reloadRecordings, .reloadSchedules, .reloadInfo, .reloadLineup: "もう一度読み込む"
        }
    }
}

/// 帯の 1 行
public struct MainNotice: Identifiable, Hashable, Sendable {
    /// 知らせの出どころ（同じ出どころの知らせは 1 つだけ）
    public var id: String
    public var kind: MainNoticeKind
    public var title: String
    /// 続きの説明（帯には 1 行で出し、マウスを載せると全部出す）
    public var detail: String?
    public var action: MainNoticeAction?

    public init(id: String, kind: MainNoticeKind, title: String, detail: String? = nil, action: MainNoticeAction? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.action = action
    }

    /// 閉じられるか（読み込み中は閉じられない）
    public var isDismissible: Bool { kind != .progress }

    /// 誤りから作る（説明に番号を添える）
    public static func error(id: String, _ error: ErrorPresentation, prefix: String? = nil, note: String? = nil,
                             action: MainNoticeAction? = nil) -> MainNotice {
        let message = error.message + (error.code.map { "（\($0)）" } ?? "") + (note.map { " " + $0 } ?? "")
        return MainNotice(id: id, kind: .error, title: (prefix.map { $0 + "：" } ?? "") + error.title,
                          detail: message, action: action)
    }
}

/// モデルの状態から知らせを作る決まり
public enum MainNotices {
    /// nasne を探している・見つからない
    public static func connection(_ state: NasneConnectionState) -> MainNotice? {
        switch state {
        case .connected:
            return nil
        case .searching:
            return MainNotice(id: "connection", kind: .progress, title: "nasne に届かないので探しています…")
        case .notFound:
            return MainNotice(id: "connection", kind: .error, title: "nasne が見つかりません",
                              detail: "電源とネットワークを確かめてください。", action: .retryConnection)
        }
    }

    /// 録画一覧：読み込み中・更新中・読み込めなかった・更新できなかった（前の一覧を出している）・削除している・保護を切り替えている
    public static func recordings(isLoading: Bool, loadError: ErrorPresentation?, isRefreshing: Bool,
                                  refreshError: ErrorPresentation?, isShowingSavedList: Bool, isDeleting: Bool,
                                  isProtecting: Bool = false) -> [MainNotice] {
        var notices: [MainNotice] = []
        if isLoading {
            notices.append(MainNotice(id: "recordings", kind: .progress, title: "録画一覧を読み込んでいます…"))
        } else if isRefreshing {
            notices.append(MainNotice(id: "recordings", kind: .progress, title: "録画一覧を更新しています…"))
        } else if let loadError {
            notices.append(.error(id: "recordings", loadError, prefix: "録画一覧", action: .reloadRecordings))
        } else if let refreshError {
            // 取り直せなかったときは、出している一覧が前に取ったものだと添える
            notices.append(.error(id: "recordings", refreshError, prefix: "録画一覧",
                                  note: isShowingSavedList ? "前回取得した一覧を表示しています。" : "前に取得した一覧を表示しています。",
                                  action: .reloadRecordings))
        }
        if isDeleting {
            notices.append(MainNotice(id: "recordings.deletion", kind: .progress, title: "録画を削除しています…"))
        }
        if isProtecting {
            notices.append(MainNotice(id: "recordings.protection", kind: .progress, title: "録画の保護を切り替えています…"))
        }
        return notices
    }

    /// 予約の一覧：読み込み中・読み込めなかった
    public static func schedules(isLoading: Bool, loadError: ErrorPresentation?) -> MainNotice? {
        if isLoading { return MainNotice(id: "schedules", kind: .progress, title: "予約の一覧を読み込んでいます…") }
        return loadError.map { .error(id: "schedules", $0, prefix: "予約の一覧", action: .reloadSchedules) }
    }

    /// 情報：読み込み中・読み込めなかった区画（最初の 1 つ）
    public static func info(isLoading: Bool, errors: [ErrorPresentation]) -> MainNotice? {
        if isLoading { return MainNotice(id: "info", kind: .progress, title: "情報を読み込んでいます…") }
        return errors.first.map { .error(id: "info", $0, prefix: "情報", action: .reloadInfo) }
    }

    /// 番組表：開けない・更新中・更新できなかった
    public static func guide(canOpen: Bool, refreshState: ProgramGuideRefreshState?) -> MainNotice? {
        guard canOpen else {
            return MainNotice(id: "guide", kind: .error, title: "番組表を開けません", detail: "この Mac に番組表を保存できませんでした。")
        }
        switch refreshState {
        case .checking, .fetching:
            return MainNotice(id: "guide", kind: .progress, title: "番組表を更新しています…")
        case .failed(let error):
            return .error(id: "guide", error, prefix: "番組表", action: .refreshGuide)
        case .idle, .updated, nil:
            return nil
        }
    }

    /// 局の一覧（番組表の局の並び）：読み込み中・読み込めなかった
    public static func lineup(isLoading: Bool, loadError: ErrorPresentation?) -> MainNotice? {
        if isLoading { return MainNotice(id: "lineup", kind: .progress, title: "局の一覧を読み込んでいます…") }
        return loadError.map { .error(id: "lineup", $0, prefix: "局の一覧", action: .reloadLineup) }
    }
}

/// 操作の結果として置く知らせ（削除できなかった・予約した）と、閉じた知らせを持つ
@MainActor
@Observable
public final class MainNoticeCenter {
    /// 操作の結果の知らせ（置いた順）
    public private(set) var events: [MainNotice] = []
    /// 閉じた知らせ（状態から作る知らせは、同じものが続く間は出さない。違う知らせになったら忘れる）
    public private(set) var dismissed: Set<MainNotice> = []
    /// うまくいった知らせを消すまでの時間
    public static let successLifetime: Duration = .seconds(4)

    public init() {}

    /// 知らせを置く（同じ出どころの前の知らせは置き換える）
    public func post(_ notice: MainNotice) {
        events.removeAll { $0.id == notice.id }
        events.append(notice)
        if notice.kind == .success {
            Task { [weak self] in
                try? await Task.sleep(for: Self.successLifetime)
                self?.events.removeAll { $0 == notice }
            }
        }
    }

    /// 閉じる
    public func dismiss(_ notice: MainNotice) {
        if events.contains(notice) {
            events.removeAll { $0 == notice }
        } else {
            dismissed.insert(notice)
        }
    }

    /// 帯に出す知らせ：状態から作った知らせ（閉じたものを除く）のあとに、操作の結果の知らせ（画面を描く間に呼ぶので、何も書き換えない）
    public func visible(state: [MainNotice]) -> [MainNotice] {
        state.filter { !dismissed.contains($0) } + events
    }

    /// 閉じた知らせのうち、もう状態から作られないものを忘れる（同じ誤りがまた起きたら出す）。状態が変わったときに呼ぶ
    public func forgetDismissed(notIn state: [MainNotice]) {
        let current = Set(state)
        if !dismissed.isSubset(of: current) { dismissed.formIntersection(current) }
    }
}
