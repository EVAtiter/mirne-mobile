import Foundation
import Observation

/// 録画の視聴の状態
public enum ViewingState: Sendable, Equatable {
    /// まだ見ていない
    case unwatched
    /// 見終わった（残りが `ViewingPolicy.completionRemaining` を切ったところまで見た）
    case completed
    /// 途中まで見た（録画の頭からの秒）
    case interrupted(seconds: Double)

    /// 途中までの位置（途中まででなければ nil）
    public var resumeSeconds: Double? {
        if case .interrupted(let seconds) = self { return seconds }
        return nil
    }
}

/// 視聴の状態の決まり
public enum ViewingPolicy {
    /// 残りがこれを切っていれば「完了」（番組の終わりの次回予告や提供で止めても完了にする。目安の値で、実機で見て決める）
    public static let completionRemaining: Double = 60
    /// 再生している間に位置を書く間隔（落ちたり止まったりしても、続きの位置が大きくずれないように。2026-11-20 に決めた）
    public static let checkpointInterval: Duration = .seconds(30)
    /// 同じ録画・同じ位置の書き戻しを続けて送らない間（止めると同時に別の録画へ替えたときなど、1 回の操作で二度知らせが来る）
    public static let writeBackDuplicateWindow: TimeInterval = 5
    /// アプリを終える・登録を外す前に、書き戻しを待つ上限（nasne に届かないときに終われなくならないように）
    public static let writeBackWaitLimit: Duration = .seconds(2)

    /// 止めた位置からの状態（長さが分からなければ途中まで）
    public static func state(position: Double, duration: Double?) -> ViewingState {
        if let duration, duration - position < completionRemaining { return .completed }
        return .interrupted(seconds: max(0, position))
    }

    /// 手元の記録と nasne の値を合わせた状態（nasne の値は読むだけで、nasne には書き戻さない）。
    ///
    /// - nasne の前回の再生の時刻が手元の記録より新しければ、nasne の再開位置を採る（公式 torne などで見た）
    /// - 手元の記録があればそれ
    /// - 手元の記録が無ければ nasne の値から：再開位置があれば途中まで、新着の印があって前回の再生の時刻が無ければ未再生、
    ///   どちらでもなければ完了（torne などで見終えたものと見なす。2026-11-20 に決めた）
    ///
    /// このアプリの受信（DTCP-IP）では nasne の前回の再生の時刻も再開位置も変わらない（2026-11-20・Buffalo 製で確かめた）。
    /// 再開位置は止めたときに書き戻す（`ViewingRecorder`）。書き戻しは新着の印を消さないので、見終えて 0 を書き戻した録画は
    /// 新着の印が残ったまま前回の再生の時刻が入る。再生されたことの無い録画には前回の再生の時刻が無い（2026-11-22・Buffalo 製で 651 件を数えた）ので、
    /// 時刻があれば未再生にしない
    public static func resolve(_ title: RecordedTitle, local: ViewingRecord?) -> ViewingState {
        if let local, !(title.lastPlaybackTime.map { $0 > local.updatedAt } ?? false) {
            return local.state
        }
        if let resume = title.resumePointSeconds, resume > 0 {
            return state(position: Double(resume), duration: title.durationSeconds.map(Double.init))
        }
        if local == nil, title.isNew, title.lastPlaybackTime == nil { return .unwatched }
        return .completed
    }
}

/// 視聴の記録を見分ける鍵：タイトル ID と録画の開始日時（xsrs の `scheduledStartDateTime`）の組。
/// nasne が消した録画のタイトル ID を使い回すかは確かめていないので、ID だけにしない
public struct ViewingKey: Sendable, Hashable {
    public var titleID: String
    public var recordedStart: Date?

    public init(titleID: String, recordedStart: Date?) {
        self.titleID = titleID
        self.recordedStart = recordedStart
    }

    public init(_ title: RecordedTitle) {
        self.init(titleID: title.id, recordedStart: title.start)
    }
}

/// この Mac の視聴の記録 1 件（最後に見た結果で上書きする）
public struct ViewingRecord: Sendable, Equatable {
    public var key: ViewingKey
    /// 完了か途中まで（未再生は記録しない）
    public var state: ViewingState
    /// 記録した時刻（nasne の前回の再生の時刻と比べる）
    public var updatedAt: Date

    public init(key: ViewingKey, state: ViewingState, updatedAt: Date) {
        self.key = key
        self.state = state
        self.updatedAt = updatedAt
    }
}

/// 再生の止めどころ（位置を記録する時機に再生の制御が知らせる）
public struct PlaybackCheckpoint: Sendable, Equatable {
    /// 録画の頭からの秒
    public var position: Double
    /// 録画の長さ（秒。分からなければ nil）
    public var duration: Double?
    /// 最後まで受け取って出し切ったか
    public var ended: Bool
    /// 知らせた時機（録画から離れたときだけ nasne へ書き戻す）
    public var occasion: Occasion

    /// 止めどころを知らせる時機
    public enum Occasion: Sendable, Equatable {
        /// 再生している間の定期の記録
        case periodic
        /// 一時停止
        case paused
        /// 録画から離れた（止めた・窓を閉じた・別の録画やライブへ替えた・スリープ・裏へ回した・最後まで）
        case left
    }

    public init(position: Double, duration: Double?, ended: Bool, occasion: Occasion = .periodic) {
        self.position = position
        self.duration = duration
        self.ended = ended
        self.occasion = occasion
    }
}

/// 視聴の設定の鍵（UserDefaults）
public enum ViewingSettingsKey {
    /// 止めた位置を nasne へ書き戻すか（未設定なら書き戻す）
    public static let writesResumePosition = "writesResumePositionToNasne"
}

/// 視聴の状態を記録して見せる。登録した nasne ごとに 1 つ。
///
/// 再生を始めるときに `begin` で録画を知らせ、再生の制御の止めどころ（`PlaybackCheckpoint`）を `record` で受けて
/// `LibraryStore` に書く。画面は `state(of:)` で、手元の記録と nasne の値を合わせた状態を読む
@MainActor
@Observable
public final class ViewingRecorder {
    /// 手元の記録（読み込むまでは空）
    public private(set) var records: [ViewingKey: ViewingRecord] = [:]
    /// いま再生している録画
    @ObservationIgnored private var current: ViewingKey?
    /// いま再生している録画が録画中か（録画中の録画には書き戻さない）
    @ObservationIgnored private var currentIsRecording = false
    /// 書き込みを順に行う（終了・登録を外す前に待つ）
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// nasne への書き戻しを順に行う
    @ObservationIgnored private var writing: Task<Void, Never>?
    /// 最後に書き戻した録画・位置（秒）・時刻（続けて同じものを送らない）
    @ObservationIgnored private var lastWriteBack: (key: ViewingKey, seconds: Int, at: Date)?

    private let udn: String
    private let library: LibraryStore?
    /// 再開位置の書き戻し（無ければ書き戻さない）
    private let resumePositions: (any ResumePositionService)?
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    public init(udn: String, library: LibraryStore?, resumePositions: (any ResumePositionService)? = nil,
                defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.udn = udn
        self.library = library
        self.resumePositions = resumePositions
        self.defaults = defaults
        self.now = now
    }

    /// 保存した記録を読む（読む前に書いた記録は残す）
    public func load() async {
        guard let library else { return }
        let saved = await library.viewingRecords(udn: udn)
        records = saved.merging(records) { _, recorded in recorded }
    }

    /// 合わせた状態
    public func state(of title: RecordedTitle) -> ViewingState {
        ViewingPolicy.resolve(title, local: records[ViewingKey(title)])
    }

    /// これから再生する録画
    public func begin(_ title: RecordedTitle) {
        current = ViewingKey(title)
        currentIsRecording = title.isRecording
    }

    /// 録画の再生を終えた（ライブに替えた）。この後の止めどころは記録しない
    public func end() {
        current = nil
    }

    /// 止めどころを記録する（いま再生している録画のもの）
    public func record(_ checkpoint: PlaybackCheckpoint) {
        guard let current else { return }
        let state = checkpoint.ended ? .completed : ViewingPolicy.state(position: checkpoint.position, duration: checkpoint.duration)
        let record = ViewingRecord(key: current, state: state, updatedAt: now())
        records[current] = record
        if checkpoint.occasion == .left || checkpoint.ended { writeBack(current, state: state) }
        guard let library else { return }
        let previous = pending
        let udn = udn
        pending = Task {
            await previous?.value
            await library.saveViewing(record, udn: udn)
        }
    }

    /// 止めた位置を nasne へ書き戻す（見終わったら 0 で再開位置を消す）。設定で切ってある・録画中の録画・
    /// 同じ録画と位置を続けて送るときは送らない。失敗は知らせず（手元の記録は残る）、再試行しない
    private func writeBack(_ key: ViewingKey, state: ViewingState) {
        guard let resumePositions, !currentIsRecording,
              defaults.object(forKey: ViewingSettingsKey.writesResumePosition) as? Bool ?? true else { return }
        let seconds = state.resumeSeconds ?? 0
        let at = now()
        if let last = lastWriteBack, last.key == key, last.seconds == Int(seconds),
           at.timeIntervalSince(last.at) < ViewingPolicy.writeBackDuplicateWindow { return }
        lastWriteBack = (key, Int(seconds), at)
        let previous = writing
        let id = key.titleID
        writing = Task {
            await previous?.value
            try? await resumePositions.setResumePosition(id: id, seconds: seconds)
        }
    }

    /// 頼んだ書き込みが済むまで待つ（nasne への書き戻しは `ViewingPolicy.writeBackWaitLimit` まで）
    public func flush() async {
        await pending?.value
        guard let writing else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await writing.value }
            group.addTask { try? await Task.sleep(for: ViewingPolicy.writeBackWaitLimit) }
            await group.next()
            group.cancelAll()
        }
    }
}
