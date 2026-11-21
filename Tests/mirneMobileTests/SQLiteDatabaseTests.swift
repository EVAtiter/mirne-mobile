import Foundation
import SQLite3
import Testing

// 番組表と録画一覧で共通の SQLite の接続（2026-11-21 にまとめた）
struct SQLiteDatabaseTests {
    private struct TestError: Error { let message: String }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mirne-mobile-sqlite-\(UUID().uuidString).sqlite")
    }

    @Test("値を結び付けて読み、使い回す文でも同じ結果になる")
    func bindAndReuse() throws {
        let url = temporaryURL()
        defer { for path in SQLiteFiles.paths(of: url) { try? FileManager.default.removeItem(atPath: path) } }
        let database = try SQLiteDatabase(fileURL: url) { TestError(message: $0) }
        try database.execute("CREATE TABLE t (i INTEGER, d REAL, s TEXT, b BLOB, n INTEGER)", [])
        for value in 1...3 {
            try database.execute("INSERT INTO t VALUES (?, ?, ?, ?, ?)",
                                 [.integer(UInt16(value)), .double(Double(value) / 2), .text("文字\(value)"), .blob(Data([UInt8(value)])), .null],
                                 reuse: true)
        }
        var rows: [String] = []
        try database.query("SELECT i, d, s, length(b), n IS NULL FROM t ORDER BY i", [], reuse: true) { row in
            rows.append("\(sqlite3_column_int(row, 0)) \(sqlite3_column_double(row, 1)) \(SQLiteDatabase.text(row, 2)) \(sqlite3_column_int(row, 3)) \(sqlite3_column_int(row, 4))")
        }
        #expect(rows == ["1 0.5 文字1 1 1", "2 1.0 文字2 1 1", "3 1.5 文字3 1 1"])
    }

    @Test("トランザクションの中で誤りが出たら取り消す。閉じた後は使う側の誤りで「閉じています」")
    func rollbackAndClose() throws {
        let url = temporaryURL()
        defer { for path in SQLiteFiles.paths(of: url) { try? FileManager.default.removeItem(atPath: path) } }
        let database = try SQLiteDatabase(fileURL: url) { TestError(message: $0) }
        try database.execute("CREATE TABLE t (i INTEGER PRIMARY KEY)", [])
        #expect(throws: TestError.self) {
            try database.transaction(begin: "BEGIN IMMEDIATE") {
                try database.execute("INSERT INTO t VALUES (1)", [])
                try database.execute("INSERT INTO t VALUES (1)", [])   // 主キーが重なる
            }
        }
        var count: Int32 = -1
        try database.query("SELECT count(*) FROM t", []) { count = sqlite3_column_int($0, 0) }
        #expect(count == 0)
        database.close()
        #expect(!database.isOpen)
        #expect(throws: TestError.self) { try database.execute("SELECT 1", []) }
        do {
            try database.execute("SELECT 1", [])
        } catch let error as TestError {
            #expect(error.message == "閉じています")
        }
    }
}
