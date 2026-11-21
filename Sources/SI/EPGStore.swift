import Foundation
import os
import SQLite3

/// 番組表の保存の決まり。
public enum EPGRetention {
    /// 終わってからこれだけたった番組を消す。番組表で、その日のすでに終わった番組も見られるように 1 日残す
    public static let keepAfterEnd: TimeInterval = 24 * 3600
    /// 終わった番組の掃除をこの間隔より詰めて行わない（掃除は表全体を調べるので、セクションを保存するたびには行わない）
    public static let pruneInterval: TimeInterval = 10 * 60
}

/// 番組表が届いた範囲（番組表に取得時刻を出すのに使う）。
public struct EPGCoverage: Sendable, Equatable {
    /// 最後に番組表を受け取った時刻（Mac の時刻）
    public var lastReceived: Date
    /// 持っている番組の最後の終了時刻
    public var latestEnd: Date?
    public var eventCount: Int
}

/// 番組表の保存先が使えない。
public struct EPGStoreError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { "番組表を保存できません: \(message)" }
}

/// 番組表（EIT[schedule]）を SQLite に保存する。
///
/// 番組はネットワーク・TS・サービス・イベントの ID の組で一意に決まる。届いたセクションの版が変わったら、
/// そのセクションに載っていた番組を消してから入れ直す（時間が動いた番組は別のセクションへ移ることがある）。
/// 書き込みは自分の直列のキューで行い、呼び出し側（受信の道筋・画面）を待たせない。読み出しは同じキューで待って返す。
public final class EPGStore: @unchecked Sendable {
    /// 番組表の場所（`~/Library/Application Support/mirne-mobile/epg.sqlite`）
    public static func defaultFileURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return support.appendingPathComponent("mirne-mobile", isDirectory: true).appendingPathComponent("epg.sqlite")
    }

    /// 表の作りの版。変えたら作り直す（1 → 2 はジャンルの列を足すだけなので、集めた番組を残して列を足す）
    static let schemaVersion: Int32 = 2
    /// ジャンルの列が無い版
    static let schemaVersionWithoutGenre: Int32 = 1

    private let queue = DispatchQueue(label: "com.slack-kingdom.mirne-mobile.epg")
    /// SQLite の接続。何度も流す文は準備した文を使い回す（`reuse: true`。番組 1 つごとに準備し直さない）。`queue` の中だけで触る
    private let database: SQLiteDatabase
    /// 最後に終わった番組を掃除した時刻（届いた時刻の基準）。`queue` の中だけで触る
    private var lastPrune: Date?
    private static let logger = Logger(subsystem: AppLog.subsystem, category: "epg")

    public init(fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try SQLiteDatabase(fileURL: fileURL) { EPGStoreError(message: $0) }
        try createSchema()
    }

    /// EIT[schedule] のセクションを保存する（版が変わるたびに呼ぶ）。終わった番組もここで消す
    public func save(_ sections: [EITSection], receivedAt: Date) {
        let schedule = sections.filter(\.isSchedule)
        guard !schedule.isEmpty else { return }
        queue.async { [self] in
            do {
                try database.transaction {
                    for section in schedule {
                        try database.execute("DELETE FROM events WHERE network_id = ? AND transport_stream_id = ? AND service_id = ? AND table_id = ? AND section_number = ?",
                                    [.integer(section.originalNetworkID), .integer(section.transportStreamID), .integer(section.serviceID),
                                     .integer(section.tableID), .integer(section.sectionNumber)], reuse: true)
                        for event in section.events {
                            try database.execute("""
                                INSERT OR REPLACE INTO events
                                (network_id, transport_stream_id, service_id, event_id, table_id, section_number, start, duration, title, text, lossless, received, genre)
                                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                                """,
                                [.integer(event.originalNetworkID), .integer(event.transportStreamID), .integer(event.serviceID), .integer(event.eventID),
                                 .integer(section.tableID), .integer(section.sectionNumber),
                                 event.start.map { .double($0.timeIntervalSince1970) } ?? .null,
                                 event.duration.map { .integer($0) } ?? .null,
                                 .text(event.title), .text(event.text), .integer(event.lossless ? 1 : 0),
                                 .double(receivedAt.timeIntervalSince1970),
                                 event.genre.map { .integer($0.byte) } ?? .null], reuse: true)
                        }
                        try database.execute("INSERT OR REPLACE INTO services (network_id, transport_stream_id, service_id, last_received) VALUES (?, ?, ?, ?)",
                                    [.integer(section.originalNetworkID), .integer(section.transportStreamID), .integer(section.serviceID),
                                     .double(receivedAt.timeIntervalSince1970)], reuse: true)
                    }
                    if lastPrune.map({ receivedAt.timeIntervalSince($0) >= EPGRetention.pruneInterval || receivedAt < $0 }) ?? true {
                        try database.execute("DELETE FROM events WHERE start IS NOT NULL AND duration IS NOT NULL AND start + duration < ?",
                                    [.double(receivedAt.timeIntervalSince1970 - EPGRetention.keepAfterEnd)], reuse: true)
                        lastPrune = receivedAt
                    }
                }
            } catch {
                Self.logger.error("番組表を保存できない: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 番組表の 1 つのサービス（ネットワーク・TS・サービスの ID）
    public struct ServiceKey: Sendable, Hashable {
        public var networkID: Int
        public var transportStreamID: Int
        public var serviceID: Int

        public init(networkID: Int, transportStreamID: Int, serviceID: Int) {
            self.networkID = networkID
            self.transportStreamID = transportStreamID
            self.serviceID = serviceID
        }
    }

    /// 1 つのサービスの、番組表が届いた範囲と時間帯にかかる番組（番組表の画面の読み込み）
    public struct ServiceSchedule: Sendable {
        public var coverage: EPGCoverage?
        public var events: [BroadcastEvent]
    }

    /// サービスの、時間帯 `range` にかかる番組（開始時刻の順）
    public func events(networkID: Int, transportStreamID: Int, serviceID: Int, overlapping range: Range<Date>) -> [BroadcastEvent] {
        queue.sync {
            fetchEvents(ServiceKey(networkID: networkID, transportStreamID: transportStreamID, serviceID: serviceID), overlapping: range)
        }
    }

    /// サービスの番組表が届いた範囲。一度も届いていなければ nil
    public func coverage(networkID: Int, transportStreamID: Int, serviceID: Int) -> EPGCoverage? {
        queue.sync {
            fetchCoverage(ServiceKey(networkID: networkID, transportStreamID: transportStreamID, serviceID: serviceID))
        }
    }

    /// 複数のサービスの、番組表が届いた範囲と時間帯 `range` にかかる番組を、呼び出し側を止めずに読む（番組表の画面）。
    /// 先に頼まれた保存を済ませてから読む（保存と同じ順で並ぶので、届いた番組は読める）。
    /// 番組表がまだ届いていないサービスは、番組を読まない
    public func schedules(of services: [ServiceKey], overlapping range: Range<Date>) async -> [ServiceSchedule] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let schedules = services.map { service in
                    let coverage = fetchCoverage(service)
                    return ServiceSchedule(coverage: coverage, events: coverage == nil ? [] : fetchEvents(service, overlapping: range))
                }
                continuation.resume(returning: schedules)
            }
        }
    }

    private func fetchEvents(_ service: ServiceKey, overlapping range: Range<Date>) -> [BroadcastEvent] {
        var events: [BroadcastEvent] = []
        try? database.query("""
            SELECT event_id, table_id, start, duration, title, text, lossless, genre FROM events
            WHERE network_id = ? AND transport_stream_id = ? AND service_id = ?
              AND start < ? AND start + COALESCE(duration, 0) > ?
            ORDER BY start
            """,
            [.integer(service.networkID), .integer(service.transportStreamID), .integer(service.serviceID),
             .double(range.upperBound.timeIntervalSince1970), .double(range.lowerBound.timeIntervalSince1970)], reuse: true) { row in
            events.append(BroadcastEvent(
                tableID: UInt8(sqlite3_column_int(row, 1)), serviceID: UInt16(service.serviceID), eventID: UInt16(sqlite3_column_int(row, 0)),
                transportStreamID: UInt16(service.transportStreamID), originalNetworkID: UInt16(service.networkID),
                start: Date(timeIntervalSince1970: sqlite3_column_double(row, 2)),
                duration: sqlite3_column_type(row, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(row, 3)),
                title: SQLiteDatabase.text(row, 4), text: SQLiteDatabase.text(row, 5),
                lossless: sqlite3_column_int(row, 6) != 0,
                genre: sqlite3_column_type(row, 7) == SQLITE_NULL ? nil : ProgramGenre(byte: UInt8(truncatingIfNeeded: sqlite3_column_int(row, 7)))))
        }
        return events
    }

    private func fetchCoverage(_ service: ServiceKey) -> EPGCoverage? {
        var coverage: EPGCoverage?
        try? database.query("""
            SELECT s.last_received, MAX(e.start + e.duration), COUNT(e.event_id) FROM services s
            LEFT JOIN events e ON e.network_id = s.network_id AND e.transport_stream_id = s.transport_stream_id AND e.service_id = s.service_id
            WHERE s.network_id = ? AND s.transport_stream_id = ? AND s.service_id = ?
            GROUP BY s.service_id
            """, [.integer(service.networkID), .integer(service.transportStreamID), .integer(service.serviceID)], reuse: true) { row in
            coverage = EPGCoverage(
                lastReceived: Date(timeIntervalSince1970: sqlite3_column_double(row, 0)),
                latestEnd: sqlite3_column_type(row, 1) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(row, 1)),
                eventCount: Int(sqlite3_column_int(row, 2)))
        }
        return coverage
    }

    /// 番組表を持っているサービス（ネットワーク・TS・サービスの ID）
    public func storedServices() -> [(networkID: Int, transportStreamID: Int, serviceID: Int)] {
        queue.sync {
            var services: [(Int, Int, Int)] = []
            try? database.query("SELECT network_id, transport_stream_id, service_id FROM services ORDER BY network_id, transport_stream_id, service_id", []) { row in
                services.append((Int(sqlite3_column_int(row, 0)), Int(sqlite3_column_int(row, 1)), Int(sqlite3_column_int(row, 2))))
            }
            return services.map { (networkID: $0.0, transportStreamID: $0.1, serviceID: $0.2) }
        }
    }

    /// 書き込みが終わるまで待つ（試験と終了時）
    public func flush() {
        queue.sync {}
    }

    /// 書き込みが終わるまで、呼び出し側（メインスレッド）を止めずに待つ（番組表の巡回の終わり）
    public func flushed() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    // MARK: - 下請け

    private func createSchema() throws {
        try queue.sync {
            var version: Int32 = 0
            try database.query("PRAGMA user_version", []) { version = sqlite3_column_int($0, 0) }
            if version == Self.schemaVersionWithoutGenre {
                // ジャンルの列を足す。集めた番組はジャンル無し（NULL）のまま残り、巡回で集め直すと埋まる
                try database.execute("ALTER TABLE events ADD COLUMN genre INTEGER", [])
            } else if version != Self.schemaVersion {
                // 作りが違えば捨てて作り直す（番組表は放送からまた集められる）
                try database.execute("DROP TABLE IF EXISTS events", [])
                try database.execute("DROP TABLE IF EXISTS services", [])
            }
            try database.execute("PRAGMA journal_mode = WAL", [])
            try database.execute("""
                CREATE TABLE IF NOT EXISTS events (
                    network_id INTEGER NOT NULL, transport_stream_id INTEGER NOT NULL, service_id INTEGER NOT NULL, event_id INTEGER NOT NULL,
                    table_id INTEGER NOT NULL, section_number INTEGER NOT NULL,
                    start REAL, duration INTEGER, title TEXT NOT NULL, text TEXT NOT NULL, lossless INTEGER NOT NULL, received REAL NOT NULL,
                    genre INTEGER,
                    PRIMARY KEY (network_id, transport_stream_id, service_id, event_id))
                """, [])
            try database.execute("CREATE INDEX IF NOT EXISTS events_by_section ON events (network_id, transport_stream_id, service_id, table_id, section_number)", [])
            try database.execute("CREATE INDEX IF NOT EXISTS events_by_start ON events (network_id, transport_stream_id, service_id, start)", [])
            try database.execute("""
                CREATE TABLE IF NOT EXISTS services (
                    network_id INTEGER NOT NULL, transport_stream_id INTEGER NOT NULL, service_id INTEGER NOT NULL, last_received REAL NOT NULL,
                    PRIMARY KEY (network_id, transport_stream_id, service_id))
                """, [])
            try database.execute("PRAGMA user_version = \(Self.schemaVersion)", [])
        }
    }
}
