import CryptoKit
import Foundation
import Observation
import os

// 番組表の取り直し。
//
// 版数表（`status/EPGVersionInfoGet`）を読み、前に取ったときの版数表と同じなら EPGGet を送らない。
// 違えば EPGGet を送り、セクションを EPGStore（mirne から写したもの）に入れる。
// 取り直しの時機（起動したとき・番組表を開いたとき・手動）は呼び出し側が決め、ここは `refresh()` だけを持つ。
// AppKit・SwiftUI に依存させない。

/// 前に取ったときの版数表の控え（版数表の SHA-256 の 16 進）。番組表と一緒に消す
public protocol ProgramGuideVersionStore: Sendable {
    func load() -> String?
    func save(_ digest: String) throws
    func delete() throws
}

/// 番組表の隣のファイルに置く控え（`epg.version`）
public struct FileProgramGuideVersionStore: ProgramGuideVersionStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> String? {
        (try? String(contentsOf: fileURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func save(_ digest: String) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(digest.utf8).write(to: fileURL, options: .atomic)
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

/// 試験とプレビュー用の控え
public final class MemoryProgramGuideVersionStore: ProgramGuideVersionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var digest: String?

    public init(digest: String? = nil) {
        self.digest = digest
    }

    public func load() -> String? { lock.withLock { digest } }
    public func save(_ digest: String) throws { lock.withLock { self.digest = digest } }
    public func delete() throws { lock.withLock { digest = nil } }
}

/// この Mac に置く番組表のファイル（登録を外したら全部消す）
public enum ProgramGuideFiles {
    /// 番組表（`~/Library/Application Support/mirne-mobile/epg.sqlite`）
    public static func storeURL() throws -> URL { try EPGStore.defaultFileURL() }

    /// 版数表の控え（番組表の隣）
    public static func versionURL(storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("epg.version")
    }

    /// 番組表と、その隣のファイル（SQLite が書き込みの途中に作るもの）と、版数表の控えを消す。無いものは飛ばす
    public static func delete(storeURL: URL) throws {
        let paths = SQLiteFiles.paths(of: storeURL) + [versionURL(storeURL: storeURL).path]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }
}

/// 番組表の取り直しの状態
public enum ProgramGuideRefreshState: Sendable, Equatable {
    case idle
    /// 版数表を読んでいる
    case checking
    /// EPGGet を送って、番組表に入れている
    case fetching
    /// 取り直した（`changed` が false なら、版数表が同じで EPGGet を送らなかった）
    case updated(at: Date, changed: Bool)
    case failed(ErrorPresentation)

    public var isRunning: Bool {
        self == .checking || self == .fetching
    }
}

#if DEBUG
/// EPGGet を送って番組表を書き換えた取り直し（非機能要件の計測。開発用のビルドだけ）
public struct ProgramGuideChangedFetch: Sendable, Equatable {
    /// 書き換えた後の `ProgramGuideModel.revision`
    public let revision: Int
    /// 取り直しを始めた時刻（版数表を読む前）
    public let startedAt: ContinuousClock.Instant
    /// 取り直しを始めてから番組表に書き終えるまで
    public let fetchMilliseconds: Int
}
#endif

/// 番組表の取り直しのモデル
@MainActor
@Observable
public final class ProgramGuideModel {
    public private(set) var state = ProgramGuideRefreshState.idle
    /// 番組表に書き込んだ回数（画面はこれが変わったら読み直す）
    public private(set) var revision = 0
    /// 番組表（画面はここから番組を読む）
    public let store: EPGStore
    #if DEBUG
    /// 最後に EPGGet を送って番組表を書き換えた取り直し（非機能要件の計測。画面が表を出すまでの時間を測る起点。開発用のビルドだけ）
    @ObservationIgnored public private(set) var lastChangedFetch: ProgramGuideChangedFetch?
    #endif

    private let service: any ProgramGuideService
    private let versions: any ProgramGuideVersionStore
    private let now: @Sendable () -> Date
    @ObservationIgnored private var running: Task<Void, Never>?
    private static let logger = Logger(subsystem: AppLog.subsystem, category: "epg")

    public init(service: any ProgramGuideService, store: EPGStore, versions: any ProgramGuideVersionStore,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.service = service
        self.store = store
        self.versions = versions
        self.now = now
    }

    /// 取り直す。版数表が前と同じで、番組表に番組があれば EPGGet を送らない。
    /// 取り直している間にもう一度呼ばれたら、同じ取り直しが終わるのを待つ（二重に送らない）
    public func refresh() async {
        if let running {
            await running.value
            return
        }
        let task = Task { await perform() }
        running = task
        await task.value
        running = nil
    }

    /// 取り直しが終わるのを待ち、番組表への書き込みも済ませる（登録を外す前）
    public func finish() async {
        await running?.value
        await store.flushed()
    }

    /// 取り直しを取り消してから終える（nasne のアドレスが変わって作り直すとき。古いアドレスへの頼み直しを待たない）
    public func cancelAndFinish() async {
        running?.cancel()
        await finish()
    }

    private func perform() async {
        let started = ContinuousClock.now
        state = .checking
        do {
            let table = try await service.versionTable()
            let digest = Self.digest(table)
            let stored = store.storedServices().count
            if digest == versions.load(), stored > 0 {
                state = .updated(at: now(), changed: false)
                Self.logger.info("番組表: 版数表が前と同じなので取り直さない（\(table.count, privacy: .public) バイト・保存したサービス \(stored, privacy: .public) 件）")
                return
            }
            state = .fetching
            let result = try await service.fetch(versionTable: table)
            store.save(result.sections, receivedAt: now())
            await store.flushed()
            try versions.save(digest)
            revision += 1
            #if DEBUG
            lastChangedFetch = ProgramGuideChangedFetch(revision: revision, startedAt: started,
                                                        fetchMilliseconds: started.elapsedMilliseconds)
            #endif
            state = .updated(at: now(), changed: true)
            Self.logger.info("番組表: 取り直した（サービス \(result.serviceCount, privacy: .public) 件・セクション \(result.sections.count, privacy: .public) 件・応答 \(result.responseBytes, privacy: .public) バイト・\(started.elapsedMilliseconds, privacy: .public) ms）")
        } catch {
            state = .failed(ErrorText.present(error))
            Self.logger.error("番組表: 取り直せなかった（\(NasneDiagnostics.summary(error), privacy: .public)）")
        }
    }

    /// 版数表の要約（SHA-256 の 16 進）
    /// 版数表の読み方の版。控えの値の頭に付け、読み方を変えたら上げて、版数表が前と同じでも一度取り直させる。
    /// 2：flags でレコードの長さが変わる読み方にした（2026-11-21。前の読み方では地上の 7 局を読んでいなかった）
    static let versionTableReadingRevision = 2

    static func digest(_ table: Data) -> String {
        "r\(versionTableReadingRevision):" + SHA256.hash(data: table).map { String(format: "%02x", $0) }.joined()
    }
}
