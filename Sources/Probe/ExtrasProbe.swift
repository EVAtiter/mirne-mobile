import Foundation

// pydtcpip（MIT、Copyright (c) 2026 tsukumi）の nasne の拡張（`dlna/extensions/nasne.py`）が使う読み取りの口を、
// こちらの nasne で、読み取りだけで試す。
//
//   - 録画の詳細の一覧 `recorded/titleListGet`（JSON。pydtcpip はポート 64220。torne mobile HB は SIE 製で 64220 が全部 400 と実測）
//   - サムネイルの位置の表 `recorded/thumbnailMapGet`（64210。4 バイトの件数 + 4 バイトずつの項目。約 15 秒ごと）
//   - サムネイル `recorded/recordedContentThumbnailGet`（64210。`thumbnailEntryId` は表の 0 から数えた番号）
//   - チャプター `recorded/recordedContentChpDataGet`（pydtcpip は 64220。16 バイトの記録）
//
// 守ること:
// - GET しか送らない（どれも読み取り。torne mobile HB の §11.4 でも GET は状態を変えない）
// - 番組名・タイトル ID・アドレス・本文の値を出さない。出すのは HTTP の状態・長さ・形・件数・JSON の項目名だけ
// - サムネイルの画像は放送の素材なので、ディスクに書かない（形を見て捨てる）

/// 試す口の表（アプリの表 `NasneProfile` には載せない。確かめていない口なので、この計測コマンドの中だけで持つ）
enum ExtrasEndpoints {
    /// pydtcpip が録画の詳細とチャプターに使うポート（WANProxySrv。torne mobile HB §11.3）
    static let remoteAPIPort = 64220
    /// WebAPI のポート（アプリの表から引く）
    static var webAPIPort: Int { NasneProfiles.standard.ports.webAPI }
    static let titleListPath = "/recorded/titleListGet"
    static let titleListQuery = [("searchCriteria", "0"), ("filter", "0"), ("startingIndex", "0"), ("requestedCount", "1"),
                                 ("sortCriteria", "0"), ("withDescriptionLong", "0"), ("withUserData", "0")]
    static let thumbnailMapPath = "/recorded/thumbnailMapGet"
    static let thumbnailPath = "/recorded/recordedContentThumbnailGet"
    static let chapterPath = "/recorded/recordedContentChpDataGet"
    /// 録画を指すパラメータの名前
    static let titleIDParameter = "id"
    /// 録画 1 件だけの DIDL を読む Browse の値（`p6` で確かめる口。アプリの表にはまだ載せない）
    static let browseMetadataFlag = "BrowseMetadata"
    /// チャプターを読む X_PvrControl のアクション（`p6` で確かめる口。引数はアプリの表の録画の ID の名前）
    static let getTitleInfoAction = "X_GetTitleInfo"
    static let thumbnailEntryParameter = "thumbnailEntryId"
    static let chapterQuery = [("offset", "0"), ("length", "0")]
}

@MainActor
enum ExtrasCommand {
    /// 試すポート（pydtcpip の 64220 と、WebAPI の 64210）
    static var titleListPorts: [Int] { [ExtrasEndpoints.remoteAPIPort, ExtrasEndpoints.webAPIPort] }
    /// サムネイルの位置の表の見出し（件数）の長さと、1 項目の長さ
    static let thumbnailMapHeaderSize = 4
    static let thumbnailMapEntrySize = 4
    /// チャプターの 1 記録の長さと、位置を取り出すために右へずらすビット数（pydtcpip の値）
    static let chapterRecordSize = 16
    static let chapterPositionShift = 11
    /// サムネイルの 1 項目が表す時間（pydtcpip の見積もりの前提。ミリ秒）
    static let thumbnailIntervalMilliseconds = 15_000

    static func run() async throws {
        let host = requiredHost()
        let picked = try await RecordingPicker.pick().title
        guard let titleID = titleID(of: picked) else { fail("選んだ録画のタイトル ID が読めない") }
        say("選んだ録画: 長さ \(picked.durationSeconds ?? 0) 秒（タイトル ID は出さない）")

        // 録画の詳細の一覧（件数を 1 にして、本文の値は出さない）
        for port in titleListPorts {
            let result = await get(host: host, port: port, path: ExtrasEndpoints.titleListPath,
                                   query: ExtrasEndpoints.titleListQuery)
            say("titleListGet（\(port)）: \(result.summary)\(result.status == 200 ? "・" + titleListShape(result.body) : "")")
        }

        // サムネイルの位置の表
        let webAPIPort = ExtrasEndpoints.webAPIPort
        let idParameter = ExtrasEndpoints.titleIDParameter
        let entryParameter = ExtrasEndpoints.thumbnailEntryParameter
        let map = await get(host: host, port: webAPIPort, path: ExtrasEndpoints.thumbnailMapPath, query: [(idParameter, titleID)])
        let positions = thumbnailPositions(map.body)
        say("thumbnailMapGet（\(webAPIPort)）: \(map.summary)\(map.status == 200 ? "・" + mapShape(map.body, positions) : "")")

        // サムネイル（0 番目。画像は捨てる）
        let thumbnail = await get(host: host, port: webAPIPort, path: ExtrasEndpoints.thumbnailPath,
                                  query: [(idParameter, titleID), (entryParameter, "0")])
        say("recordedContentThumbnailGet（\(webAPIPort)・0 番目）: \(thumbnail.summary)"
            + (thumbnail.status == 200 ? "・形 \(imageKind(thumbnail.body))" : ""))
        // --format：画素の並び方を数値だけで調べる（絵はディスクに書かず、表示もしない）
        if flag("--format"), let positions, !positions.isEmpty {
            for entry in Set([0, positions.count / 2, positions.count - 1]).sorted() {
                let picture = await get(host: host, port: webAPIPort, path: ExtrasEndpoints.thumbnailPath,
                                        query: [(idParameter, titleID), (entryParameter, String(entry))])
                say("  \(entry) 番目: \(picture.summary)")
                if picture.status == 200 { say(layoutReport(picture.body)) }
            }
        }
        // id だけ（torne mobile HB は「id では 400」と記録している）
        let thumbnailByID = await get(host: host, port: webAPIPort, path: ExtrasEndpoints.thumbnailPath,
                                      query: [(idParameter, titleID)])
        say("recordedContentThumbnailGet（\(webAPIPort)・id だけ）: \(thumbnailByID.summary)")

        // チャプター
        for port in titleListPorts {
            let chapters = await get(host: host, port: port, path: ExtrasEndpoints.chapterPath,
                                     query: [(idParameter, titleID)] + ExtrasEndpoints.chapterQuery)
            say("recordedContentChpDataGet（\(port)）: \(chapters.summary)"
                + (chapters.status == 200 ? "・" + chapterShape(chapters.body, positions) : ""))
        }
    }

    /// タイトル ID（再生に使える res の URL の `id`。無ければ一覧の ID）。pydtcpip の `_title_id` と同じく数字だけを受ける
    static func titleID(of title: RecordedTitle) -> String? {
        let fromURL = title.playableResources.lazy
            .compactMap { URLComponents(string: $0.url)?.queryItems?.first { $0.name == "id" }?.value }.first
        return [fromURL, title.id].compactMap { $0 }.first { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    struct Result {
        var status: Int?
        var body = Data()
        var contentType: String?
        var errorCode: Int?
        var milliseconds = 0

        var summary: String {
            guard let status else { return "届かない（URLError \(errorCode.map(String.init) ?? "?")・\(milliseconds) ms）" }
            return "HTTP \(status)・\(body.count) バイト・\(contentType ?? "Content-Type なし")・\(milliseconds) ms"
        }
    }

    /// GET を 1 回送る。誤りはコードだけを持つ（URL を含む説明を出さないため）
    static func get(host: String, port: Int, path: String, query: [(String, String)]) async -> Result {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        var result = Result()
        let start = Date()
        guard let url = components.url else { return result }
        do {
            let (data, response) = try await client.send(URLRequest(url: url))
            result.status = response.statusCode
            result.body = data
            result.contentType = response.value(forHTTPHeaderField: "Content-Type")
        } catch let error as URLError {
            result.errorCode = error.code.rawValue
        } catch {
            result.errorCode = -1
        }
        result.milliseconds = Int(Date().timeIntervalSince(start) * 1000)
        return result
    }

    /// titleListGet の JSON の形（errorcode・件数・最初の項目の名前。値は出さない）
    static func titleListShape(_ body: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "JSON でない" }
        let items = object["item"] as? [[String: Any]] ?? []
        let keys = items.first.map { $0.keys.sorted().joined(separator: ",") } ?? "なし"
        return "errorcode \(object["errorcode"].map { "\($0)" } ?? "なし")・totalMatches \(object["totalMatches"].map { "\($0)" } ?? "なし")"
            + "・numberReturned \(object["numberReturned"].map { "\($0)" } ?? "なし")・項目の名前 \(keys)"
    }

    /// サムネイルの位置の表を読む（形が合わなければ nil）。項目の下位 3 バイトが位置（pydtcpip）
    static func thumbnailPositions(_ body: Data) -> [Int]? {
        let bytes = [UInt8](body)
        guard bytes.count >= thumbnailMapHeaderSize else { return nil }
        let count = bytes[0..<thumbnailMapHeaderSize].reduce(0) { $0 << 8 | Int($1) }
        guard bytes.count == thumbnailMapHeaderSize + count * thumbnailMapEntrySize else { return nil }
        return stride(from: thumbnailMapHeaderSize, to: bytes.count, by: thumbnailMapEntrySize).map { offset in
            bytes[(offset + 1)..<(offset + thumbnailMapEntrySize)].reduce(0) { $0 << 8 | Int($1) }
        }
    }

    static func mapShape(_ body: Data, _ positions: [Int]?) -> String {
        guard let positions else { return "形が合わない（4 + 4 × 件数でない）" }
        let increasing = zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 }
        let span = TimeInterval(positions.count * thumbnailIntervalMilliseconds) / 1000
        return "項目 \(positions.count) 件・位置は\(increasing ? "増える一方" : "増える一方でない")"
            + "・15 秒ごととすると \(Int(span)) 秒ぶん"
    }

    /// 生の画素の並びの見当（数値だけ）：隣のバイトとの差（1〜4 バイト先）と、行の長さの候補（その長さ先のバイトとの差が小さいもの）、
    /// 位置の剰余ごとの平均・ばらつき、前・中・後ろの 1/6 ごとの平均・ばらつき
    static func layoutReport(_ body: Data) -> String {
        let bytes = [UInt8](body)
        guard bytes.count > 4096 else { return "    短すぎる" }
        func meanDiff(_ step: Int, limit: Int? = nil) -> Double {
            let end = min(bytes.count, limit ?? bytes.count) - step
            guard end > 0 else { return .nan }
            var total = 0
            for index in 0..<end { total += abs(Int(bytes[index]) - Int(bytes[index + step])) }
            return Double(total) / Double(end)
        }
        func stats(_ values: [UInt8]) -> String {
            let mean = Double(values.reduce(0) { $0 + Int($1) }) / Double(values.count)
            let variance = values.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(values.count)
            return String(format: "%.0f±%.0f", mean, variance.squareRoot())
        }
        var lines: [String] = []
        lines.append("    隣との差: " + (1...6).map { String(format: "%d 先 %.1f", $0, meanDiff($0)) }.joined(separator: "・"))
        let rows = (160...2400).map { ($0, meanDiff($0, limit: bytes.count / 2)) }.sorted { $0.1 < $1.1 }.prefix(6)
        lines.append("    行の長さの候補（バイト）: " + rows.map { String(format: "%d（%.1f）", $0.0, $0.1) }.joined(separator: "・"))
        for modulus in [2, 3, 4] {
            let parts = (0..<modulus).map { residue in stats(stride(from: residue, to: bytes.count, by: modulus).map { bytes[$0] }) }
            lines.append("    \(modulus) バイトごとの平均±ばらつき: " + parts.joined(separator: "・"))
        }
        let sixth = bytes.count / 6
        // 同じ 16 バイトの塊がくり返すか（ECB で暗号化した無地の絵なら、くり返す）
        var blocks: [Data: Int] = [:]
        for offset in stride(from: 0, to: bytes.count - 15, by: 16) { blocks[Data(bytes[offset..<(offset + 16)]), default: 0] += 1 }
        let repeated = blocks.values.filter { $0 > 1 }.reduce(0, +)
        lines.append("    16 バイトの塊: \(bytes.count / 16) 個・違うもの \(blocks.count) 個・くり返した塊 \(repeated) 個")
        lines.append("    1/6 ごと: " + (0..<6).map { stats(Array(bytes[($0 * sixth)..<(($0 + 1) * sixth)])) }.joined(separator: "・"))
        return lines.joined(separator: "\n")
    }

    /// 画像の形（先頭の数バイトだけを見る）
    static func imageKind(_ body: Data) -> String {
        let bytes = [UInt8](body.prefix(4))
        if bytes.starts(with: [0xFF, 0xD8]) { return "JPEG" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "PNG" }
        return "画像でない（\(bytes.map { String(format: "%02x", $0) }.joined())…）"
    }

    /// チャプターの記録の形と、位置の表の中に収まる件数
    static func chapterShape(_ body: Data, _ positions: [Int]?) -> String {
        guard body.count % chapterRecordSize == 0 else { return "形が合わない（16 の倍数でない）" }
        let bytes = [UInt8](body)
        let points = stride(from: 0, to: bytes.count, by: chapterRecordSize).map { offset in
            bytes[offset..<(offset + 8)].reversed().reduce(0) { $0 << 8 | Int($1) } >> chapterPositionShift
        }
        guard let positions, let first = positions.first, let last = positions.last else {
            return "記録 \(points.count) 件"
        }
        let inside = points.filter { first <= $0 && $0 < last }.count
        return "記録 \(points.count) 件・サムネイルの表の範囲に入るもの \(inside) 件"
    }
}
