import Foundation
import SQLite3

/// SQLite のファイルの扱い（番組表と録画一覧で同じ）
enum SQLiteFiles {
    /// SQLite が本体の隣に作るファイル（書き込みの途中の記録）
    static let sidecarSuffixes = ["-wal", "-shm", "-journal"]

    /// 本体と隣のファイル
    static func paths(of fileURL: URL) -> [String] {
        [fileURL.path] + sidecarSuffixes.map { fileURL.path + $0 }
    }
}

/// SQLite の 1 つの接続（番組表 `EPGStore` と録画一覧 `LibraryStore` で共通。2026-11-21 にまとめた。
/// 前は両方に、開く・値を結び付ける・行を読む・トランザクションの同じ下請けを書いていた）。
///
/// 直列にしか使わない（`SQLITE_OPEN_NOMUTEX`）。使う側が自分の直列のキューの中だけで呼ぶ。
/// 誤りは使う側の型で投げる（画面に出す文面が「番組表を〜」「録画一覧を〜」で違うため）
final class SQLiteDatabase {
    /// 文に結び付ける値
    enum Value {
        case int(Int)
        case double(Double)
        case text(String)
        case blob(Data)
        case null

        static func integer<T: BinaryInteger>(_ value: T) -> Value { .int(Int(value)) }
    }

    /// 閉じたら nil
    private var handle: OpaquePointer?
    /// 準備した文（SQL の文字列ごと）。何度も流す文を準備し直さないように使い回す（`reuse`）
    private var statements: [String: OpaquePointer] = [:]
    private let makeError: (String) -> any Error
    /// 文字と BLOB を SQLite に写させる指定（SQLITE_TRANSIENT）
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// 開く（無ければ作る）。開けなければ `makeError` の誤りを投げる
    init(fileURL: URL, makeError: @escaping (String) -> any Error) throws {
        self.makeError = makeError
        guard sqlite3_open_v2(fileURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "開けません"
            sqlite3_close(handle)
            handle = nil
            throw makeError(message)
        }
    }

    deinit {
        close()
    }

    var isOpen: Bool { handle != nil }

    /// 閉じる。その後の読み書きは「閉じています」の誤りになる
    func close() {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements.removeAll()
        sqlite3_close(handle)
        handle = nil
    }

    /// `body` を 1 つのトランザクションで行う（誤りなら取り消す）。`begin` は始める文（`BEGIN`・`BEGIN IMMEDIATE`）
    func transaction(begin: String = "BEGIN", _ body: () throws -> Void) throws {
        try execute(begin, [])
        do {
            try body()
            try execute("COMMIT", [])
        } catch {
            try? execute("ROLLBACK", [])
            throw error
        }
    }

    func execute(_ sql: String, _ values: [Value], reuse: Bool = false) throws {
        try query(sql, values, reuse: reuse) { _ in }
    }

    /// 文を実行し、行ごとに `row` を呼ぶ。`reuse` なら準備した文を覚えて使い回す
    /// （番組の保存・読み出しのように何度も流す文だけ。表の作りを変える文は使い回さない）
    func query(_ sql: String, _ values: [Value], reuse: Bool = false, row: (OpaquePointer) -> Void) throws {
        guard let handle else { throw makeError("閉じています") }
        let statement: OpaquePointer
        if reuse, let cached = statements[sql] {
            statement = cached
        } else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
                throw makeError(String(cString: sqlite3_errmsg(handle)))
            }
            statement = prepared
            if reuse { statements[sql] = prepared }
        }
        defer {
            if reuse {
                // 次に使うときのために、実行の途中の状態と前の値を消しておく
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            } else {
                sqlite3_finalize(statement)
            }
        }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let .int(number): sqlite3_bind_int64(statement, position, Int64(number))
            case let .double(number): sqlite3_bind_double(statement, position, number)
            case let .text(string): sqlite3_bind_text(statement, position, string, -1, Self.transient)
            case let .blob(data):
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), Self.transient) }
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(statement)
            case SQLITE_DONE: return
            default: throw makeError(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    /// 文字の列（NULL なら空）
    static func text(_ row: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
    }
}
