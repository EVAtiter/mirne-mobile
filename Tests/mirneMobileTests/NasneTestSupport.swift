import Foundation

/// 試験の素材（torne mobile HB の伏せた素材を写し、局名・放送局の ID・地域を架空の値に置き換えたもの）
enum NasneFixture {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func data(_ path: String) -> Data {
        // 素材が無いのは試験の書き間違いなので、止める
        try! Data(contentsOf: directory.appendingPathComponent(path))
    }

    static func text(_ path: String) -> String {
        String(decoding: data(path), as: UTF8.self)
    }

    /// 素材の nasne の IP アドレス（文書用の 192.0.2.0/24）
    static let host = "192.0.2.1"
}

/// HTTP のモック。パス（と方法）で応答を返し、送られた要求を覚える
final class MockHTTP: HTTPExchanging, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: Data
    }

    private let lock = NSLock()
    private var replies: [String: Reply] = [:]
    private var handlers: [String: @Sendable (URLRequest) -> Reply] = [:]
    private var failures: [String: Int] = [:]
    private(set) var requests: [URLRequest] = []

    /// `path` への要求に返す応答（`method` を付けると方法ごと）
    func reply(_ path: String, method: String = "GET", status: Int = 200, body: Data) {
        lock.withLock { replies["\(method) \(path)"] = Reply(status: status, body: body) }
    }

    /// `path` への要求に、要求の中身から作った応答を返す（頁送りの試験など）。`reply` より優先する
    func respond(_ path: String, method: String = "GET", with handler: @escaping @Sendable (URLRequest) -> Reply) {
        lock.withLock { handlers["\(method) \(path)"] = handler }
    }

    /// `path` への要求を `count` 回だけ「届かない」で失敗させる
    func failNext(_ path: String, method: String = "GET", count: Int) {
        lock.withLock { failures["\(method) \(path)"] = count }
    }

    var sentRequests: [URLRequest] { lock.withLock { requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let outcome: Result<Reply, URLError> = lock.withLock {
            requests.append(request)
            if let remaining = failures[key], remaining > 0 {
                failures[key] = remaining - 1
                return .failure(URLError(.timedOut))
            }
            if let handler = handlers[key] { return .success(handler(request)) }
            return .success(replies[key] ?? Reply(status: 404, body: Data()))
        }
        let reply = try outcome.get()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (reply.body, response)
    }
}

/// 番組表の合成素材（torne mobile HB の test/epg_test.dart の作り方を Swift にしたもの。実放送の番組は含まない）
enum SyntheticEPG {
    static let networkID: UInt16 = 0x1111
    static let transportStreamID: UInt16 = 0x2222
    static let serviceID: UInt16 = 0x3333

    /// 「テレビ」の ARIB の 8 単位符号（LS3R + GR のカタカナ）
    static let titleTV: [UInt8] = [0x1B, 0x7C, 0xC6, 0xEC, 0xD3]

    static func descriptor(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag, UInt8(body.count)] + body }

    static func shortEvent(_ name: [UInt8], _ text: [UInt8] = []) -> [UInt8] {
        descriptor(0x4D, [0x6A, 0x70, 0x6E, UInt8(name.count)] + name + [UInt8(text.count)] + text)
    }

    static func event(id: UInt16, mjd: UInt16, time: [UInt8], duration: [UInt8], descriptors: [UInt8] = []) -> [UInt8] {
        [UInt8(id >> 8), UInt8(id & 0xFF), UInt8(mjd >> 8), UInt8(mjd & 0xFF)] + time + duration
            + [UInt8(descriptors.count >> 8), UInt8(descriptors.count & 0xFF)] + descriptors
    }

    /// CRC-32/MPEG-2（パーサの写しとは別に書いて、互いに確かめ合う）
    static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        }
        return crc
    }

    static func section(tableID: UInt8, sectionNumber: UInt8, events: [UInt8], breakCRC: Bool = false) -> [UInt8] {
        let length = 11 + events.count + 4
        var out: [UInt8] = [tableID, 0xB0 | UInt8((length >> 8) & 0x0F), UInt8(length & 0xFF),
                            UInt8(serviceID >> 8), UInt8(serviceID & 0xFF), 0xC1, sectionNumber, 0x3F,
                            UInt8(transportStreamID >> 8), UInt8(transportStreamID & 0xFF),
                            UInt8(networkID >> 8), UInt8(networkID & 0xFF), 0x3F, 0x50]
        out += events
        var crc = crc32(out)
        if breakCRC { crc ^= 1 }
        out += [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
        return out
    }

    /// 2026-11-16（MJD 61360）の番組 2 つ：番組名のある 09:55〜10:25 と、情報の無い 10:25 の番組
    static let titledEvent = event(id: 0x101, mjd: 61360, time: [0x09, 0x55, 0x00], duration: [0x00, 0x30, 0x00],
                                   descriptors: shortEvent(titleTV) + descriptor(0x54, [0x70, 0xEE]))
    static let untitledEvent = event(id: 0x102, mjd: 61360, time: [0x10, 0x25, 0x00], duration: [0x00, 0x05, 0x00])

    /// 平文（nasne の形：4 バイトの接頭辞 + セクションの連結）
    static func plaintext(breakSecondCRC: Bool = false) -> [UInt8] {
        [0x01, 0x04, 0x00, 0x00]
            + section(tableID: 0x50, sectionNumber: 32, events: titledEvent + untitledEvent)
            + section(tableID: 0x58, sectionNumber: 32, events: untitledEvent, breakCRC: breakSecondCRC)
    }

    /// zlib で包んで XOR する（nasne の応答の形）
    static func wrap(_ plain: [UInt8]) -> Data {
        Data(zlib(plain).map { $0 ^ EPGFormat.xorKey })
    }

    /// zlib（RFC 1950）。Compression の生の deflate に見出しと Adler-32 を付ける
    static func zlib(_ plain: [UInt8]) -> [UInt8] {
        let deflated: Data = try! (Data(plain) as NSData).compressed(using: .zlib) as Data
        let adler: UInt32 = ZlibStream.adler32(plain)
        let header: [UInt8] = [0x78, 0x9C]
        let trailer: [UInt8] = [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)]
        return header + [UInt8](deflated) + trailer
    }

    /// 版数表（12 バイトの見出し + 144 バイトのレコード + 8 バイトの末尾）
    static func versionTable(_ services: [EPGServiceRef]) -> Data {
        var out = [UInt8](repeating: 0, count: 12)
        for service in services {
            out += [UInt8(service.networkID >> 8), UInt8(service.networkID & 0xFF),
                    UInt8(service.transportStreamID >> 8), UInt8(service.transportStreamID & 0xFF),
                    UInt8(service.serviceID >> 8), UInt8(service.serviceID & 0xFF), 0xC0, 0x00]
            out += [UInt8](repeating: 0, count: 136)
        }
        out += [UInt8](repeating: 0, count: 8)
        return Data(out)
    }

    /// flags を局ごとに指定した版数表（見出しに件数を書く。flags で版数のブロックの数が変わる：0xC000 は 2 つ、0x8000 は 1 つ、0 は無し）
    static func versionTable(records: [(nid: Int, tsid: Int, sid: Int, flags: UInt16)]) -> Data {
        var out = [UInt8](repeating: 0, count: 12)
        out[8] = UInt8(records.count >> 8)
        out[9] = UInt8(records.count & 0xFF)
        for record in records {
            out += [UInt8(record.nid >> 8), UInt8(record.nid & 0xFF), UInt8(record.tsid >> 8), UInt8(record.tsid & 0xFF),
                    UInt8(record.sid >> 8), UInt8(record.sid & 0xFF), UInt8(record.flags >> 8), UInt8(record.flags & 0xFF)]
            let blocks = (record.flags & 0x8000 != 0 ? 1 : 0) + (record.flags & 0x4000 != 0 ? 1 : 0)
            for _ in 0..<blocks { out += [8, 0, 0, 0] + [UInt8](repeating: 0, count: 64) }
        }
        return Data(out)
    }

    /// ロゴのファイル（見出しのレコード・PNG のあるレコード・PNG の無いレコード）
    static func logoFile() -> Data {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]
        func record(_ serviceID: Int, _ png: [UInt8]?) -> [UInt8] {
            let total = 20 + (png?.count ?? 0)
            return [0, 0, UInt8(total >> 8), UInt8(total & 0xFF), 0, 0, 1, 0, 0, 0x2A, 0, 0, 0, 0,
                    UInt8(serviceID >> 8), UInt8(serviceID & 0xFF), 0, 0,
                    UInt8((png?.count ?? 0) >> 8), UInt8((png?.count ?? 0) & 0xFF)] + (png ?? [])
        }
        let bytes = zlib([7, 225, 10, 24, 11, 10, 28, 0]) + zlib(record(0x3333, png)) + zlib(record(0x4444, nil))
        return Data(bytes.map { $0 ^ EPGFormat.xorKey })
    }
}
