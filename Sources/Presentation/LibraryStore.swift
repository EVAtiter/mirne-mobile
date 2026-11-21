import Foundation
import os
import SQLite3

/// 保存した録画一覧。nasne から取った一覧と、取った時刻・件数と上限
public struct SavedTitleList: Sendable, Equatable {
    /// nasne が返した順の録画（詳細の項目と res も入る。映像は入らない）
    public var titles: [RecordedTitle]
    /// 一覧を取った時刻（Mac の時刻）
    public var fetchedAt: Date
    /// 録画の件数と上限（取れなかったときは nil）
    public var counts: (count: Int, max: Int)?

    public init(titles: [RecordedTitle], fetchedAt: Date, counts: (count: Int, max: Int)? = nil) {
        self.titles = titles
        self.fetchedAt = fetchedAt
        self.counts = counts
    }

    public static func == (lhs: SavedTitleList, rhs: SavedTitleList) -> Bool {
        lhs.titles == rhs.titles && lhs.fetchedAt == rhs.fetchedAt
            && lhs.counts?.count == rhs.counts?.count && lhs.counts?.max == rhs.counts?.max
    }
}

/// 録画の保存先が使えない
public struct LibraryStoreError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { "録画一覧を保存できません: \(message)" }
}

/// 録画一覧のキャッシュ。番組表（`EPGStore`）とは別のファイルに置く。
///
/// nasne ごと（デバイス記述の UDN）に、取った一覧を丸ごと差し替えて保存する（消えた録画はキャッシュからも消える）。
/// 差し替えは 1 つのトランザクションで行うので、書いている途中で落ちても前の一覧が残る。
/// 録画 1 件は `RecordedTitle` の JSON で持つ（項目が増えても表の作りを変えずに済む。読めない行があれば、その一覧は無いものとする）。
/// 録画の映像（TS）は保存しない。
///
/// 視聴の状態も同じファイルの `viewing` に持つ。鍵は UDN・タイトル ID・録画の開始日時。
/// 1 件ずつ 1 つの文で上書きするので、書いている途中で落ちても前の記録が残る。一覧を差し替えるとき、nasne から消えた録画の記録も消す
public final class LibraryStore: @unchecked Sendable {
    /// 保存先（`~/Library/Application Support/mirne-mobile/library.sqlite`）
    public static func defaultFileURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return support.appendingPathComponent("mirne-mobile", isDirectory: true).appendingPathComponent("library.sqlite")
    }

    /// 保存先と、その隣のファイルを消す（登録を外したとき）。無いものは飛ばす。開いている `LibraryStore` は先に `close()` する
    public static func delete(fileURL: URL) throws {
        for path in SQLiteFiles.paths(of: fileURL) where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    /// ログに出す誤りの要約：SQLite の文面（パスは入らない）か、ほかの誤りは種類だけ（ファイルの誤りの文面にはパスが入る）
    static func summary(_ error: any Error) -> String {
        (error as? LibraryStoreError)?.message ?? NasneDiagnostics.summary(error)
    }

    /// 表の作りの版（`PRAGMA user_version`）。1 → 2 は視聴の状態の表を足すだけ（キャッシュは残す）。
    /// 知らない版なら全部作り直す（キャッシュは取り直せば戻るが、視聴の記録は消える）
    static let schemaVersion: Int32 = 2
    /// キャッシュの表だけがある版
    static let schemaVersionWithoutViewing: Int32 = 1
    /// 録画の開始日時が分からない記録の、開始日時の列の値（主キーに NULL を入れないため。実際の日時と重ならない負の値）
    static let unknownRecordedStart: Double = -1

    private let queue = DispatchQueue(label: "com.slack-kingdom.mirne-mobile.library")
    /// SQLite の接続（`queue` の中だけで触る。閉じた後の読み書きは何もしない）
    private let database: SQLiteDatabase
    private static let logger = Logger(subsystem: AppLog.subsystem, category: "library")

    public init(fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try SQLiteDatabase(fileURL: fileURL) { LibraryStoreError(message: $0) }
        do {
            try createSchema()
        } catch {
            database.close()
            throw error
        }
    }

    /// 保存した一覧。無い・読めない・閉じた後なら nil
    public func titleList(udn: String) async -> SavedTitleList? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: readTitleList(udn: udn)) }
        }
    }

    /// 一覧を丸ごと差し替えて保存する。保存できなければ前の一覧のまま（ログに残す）。閉じた後は何もしない
    public func saveTitleList(_ list: SavedTitleList, udn: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                defer { continuation.resume() }
                guard database.isOpen else { return }
                do {
                    try writeTitleList(list, udn: udn)
                } catch {
                    Self.logger.error("録画一覧を保存できない: \(Self.summary(error), privacy: .public)")
                }
            }
        }
    }

    /// 閉じる。頼まれていた保存を済ませてから閉じ、その後の読み書きは何もしない（ファイルを消す前に呼ぶ）
    public func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                database.close()
                continuation.resume()
            }
        }
    }

    // MARK: - 中身（`queue` の中で呼ぶ）

    private func createSchema() throws {
        var version: Int32 = 0
        try database.query("PRAGMA user_version", []) { version = sqlite3_column_int($0, 0) }
        // 0 は新しいファイル。1 は視聴の状態の表を足すだけ
        if version != 0 && version != Self.schemaVersionWithoutViewing && version != Self.schemaVersion {
            try database.execute("DROP TABLE IF EXISTS title_lists", [])
            try database.execute("DROP TABLE IF EXISTS titles", [])
            try database.execute("DROP TABLE IF EXISTS viewing", [])
        }
        try database.execute("""
            CREATE TABLE IF NOT EXISTS title_lists (
                udn TEXT PRIMARY KEY, fetched_at REAL NOT NULL, title_count INTEGER, title_max INTEGER)
            """, [])
        try database.execute("""
            CREATE TABLE IF NOT EXISTS titles (
                udn TEXT NOT NULL, title_id TEXT NOT NULL, position INTEGER NOT NULL, body BLOB NOT NULL,
                PRIMARY KEY (udn, title_id))
            """, [])
        try database.execute("""
            CREATE TABLE IF NOT EXISTS viewing (
                udn TEXT NOT NULL, title_id TEXT NOT NULL, recorded_start REAL NOT NULL,
                completed INTEGER NOT NULL, position REAL NOT NULL, updated_at REAL NOT NULL,
                PRIMARY KEY (udn, title_id, recorded_start))
            """, [])
        try database.execute("PRAGMA user_version = \(Self.schemaVersion)", [])
    }

    private func readTitleList(udn: String) -> SavedTitleList? {
        guard database.isOpen else { return nil }
        var header: (fetchedAt: Date, counts: (count: Int, max: Int)?)?
        var bodies: [Data] = []
        do {
            try database.query("SELECT fetched_at, title_count, title_max FROM title_lists WHERE udn = ?", [.text(udn)]) { row in
                let counts: (count: Int, max: Int)? = sqlite3_column_type(row, 1) == SQLITE_NULL || sqlite3_column_type(row, 2) == SQLITE_NULL
                    ? nil : (Int(sqlite3_column_int64(row, 1)), Int(sqlite3_column_int64(row, 2)))
                header = (Date(timeIntervalSince1970: sqlite3_column_double(row, 0)), counts)
            }
            guard header != nil else { return nil }
            try database.query("SELECT body FROM titles WHERE udn = ? ORDER BY position", [.text(udn)]) { row in
                let length = Int(sqlite3_column_bytes(row, 0))
                bodies.append(sqlite3_column_blob(row, 0).map { Data(bytes: $0, count: length) } ?? Data())
            }
        } catch {
            Self.logger.error("録画一覧を読めない: \(Self.summary(error), privacy: .public)")
            return nil
        }
        guard let header else { return nil }
        let decoder = JSONDecoder()
        do {
            let titles = try bodies.map { try decoder.decode(RecordedTitle.self, from: $0) }
            return SavedTitleList(titles: titles, fetchedAt: header.fetchedAt, counts: header.counts)
        } catch {
            // 型の項目が変わって読めない行がある。その一覧は使わない（取り直せば上書きされる）
            Self.logger.notice("保存した録画一覧を読めないので使わない（\(bodies.count, privacy: .public) 件）")
            return nil
        }
    }

    private func writeTitleList(_ list: SavedTitleList, udn: String) throws {
        let encoder = JSONEncoder()
        let bodies = try list.titles.map { try encoder.encode($0) }
        try database.transaction(begin: "BEGIN IMMEDIATE") {
            try database.execute("DELETE FROM titles WHERE udn = ?", [.text(udn)])
            for (position, (title, body)) in zip(list.titles, bodies).enumerated() {
                try database.execute("INSERT OR REPLACE INTO titles (udn, title_id, position, body) VALUES (?, ?, ?, ?)",
                            [.text(udn), .text(title.id), .integer(position), .blob(body)])
            }
            try database.execute("INSERT OR REPLACE INTO title_lists (udn, fetched_at, title_count, title_max) VALUES (?, ?, ?, ?)",
                        [.text(udn), .double(list.fetchedAt.timeIntervalSince1970),
                         list.counts.map { .integer($0.count) } ?? .null, list.counts.map { .integer($0.max) } ?? .null])
            // nasne から消えた録画の視聴の記録も消す（番組名と見た記録を残さない）
            let kept = Set(list.titles.map { Self.viewingColumns(ViewingKey($0)) })
            var gone: [ViewingColumns] = []
            try database.query("SELECT title_id, recorded_start FROM viewing WHERE udn = ?", [.text(udn)]) { row in
                let columns = ViewingColumns(titleID: String(cString: sqlite3_column_text(row, 0)), recordedStart: sqlite3_column_double(row, 1))
                if !kept.contains(columns) { gone.append(columns) }
            }
            for columns in gone {
                try database.execute("DELETE FROM viewing WHERE udn = ? AND title_id = ? AND recorded_start = ?",
                            [.text(udn), .text(columns.titleID), .double(columns.recordedStart)])
            }
        }
    }

    // MARK: - 視聴の状態

    /// 保存した視聴の記録（閉じた後・読めなければ空）
    public func viewingRecords(udn: String) async -> [ViewingKey: ViewingRecord] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: readViewing(udn: udn)) }
        }
    }

    /// 視聴の記録を 1 件上書きする（保存できなければログに残す）。閉じた後は何もしない
    public func saveViewing(_ record: ViewingRecord, udn: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                defer { continuation.resume() }
                guard database.isOpen else { return }
                let columns = Self.viewingColumns(record.key)
                let completed = record.state == .completed
                do {
                    try database.execute("""
                        INSERT OR REPLACE INTO viewing (udn, title_id, recorded_start, completed, position, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, [.text(udn), .text(columns.titleID), .double(columns.recordedStart), .integer(completed ? 1 : 0),
                              .double(record.state.resumeSeconds ?? 0), .double(record.updatedAt.timeIntervalSince1970)])
                } catch {
                    Self.logger.error("視聴の記録を保存できない: \(Self.summary(error), privacy: .public)")
                }
            }
        }
    }

    /// 視聴の記録の鍵の列の値
    private struct ViewingColumns: Hashable {
        var titleID: String
        var recordedStart: Double
    }

    /// 鍵を表の列の値にする
    private static func viewingColumns(_ key: ViewingKey) -> ViewingColumns {
        ViewingColumns(titleID: key.titleID, recordedStart: key.recordedStart?.timeIntervalSince1970 ?? unknownRecordedStart)
    }

    private func readViewing(udn: String) -> [ViewingKey: ViewingRecord] {
        guard database.isOpen else { return [:] }
        var records: [ViewingKey: ViewingRecord] = [:]
        do {
            try database.query("SELECT title_id, recorded_start, completed, position, updated_at FROM viewing WHERE udn = ?", [.text(udn)]) { row in
                let start = sqlite3_column_double(row, 1)
                let key = ViewingKey(titleID: String(cString: sqlite3_column_text(row, 0)),
                                     recordedStart: start == Self.unknownRecordedStart ? nil : Date(timeIntervalSince1970: start))
                let state: ViewingState = sqlite3_column_int(row, 2) != 0 ? .completed : .interrupted(seconds: sqlite3_column_double(row, 3))
                records[key] = ViewingRecord(key: key, state: state, updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 4)))
            }
        } catch {
            Self.logger.error("視聴の記録を読めない: \(Self.summary(error), privacy: .public)")
            return [:]
        }
        return records
    }
}
