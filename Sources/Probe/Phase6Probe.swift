import CryptoKit
import Foundation
import ImageIO

// 1.1.0 で足す機能の前に、nasne の振る舞いを読み取りだけでまとめて測る。
//
//   mirne-mobile-probe p6 --host <nasne> [--chapter-limit 60] [--metadata-samples 5]
//
// 測るもの（どれも読み取り。nasne の状態は変えない）：
// 1. 局のロゴ（`chEpg/channelLogoDataGet`）が地上・BS・CS で取れるか
// 2. Browse（録画のコンテナ）が返す順と、新しい録画が何頁目に来るか
// 3. Browse の BrowseMetadata で録画 1 件だけの DIDL を読めるか
// 4. 手元のキャッシュ（library.sqlite）に保存した res の URL・DTCP のポートが、今の一覧と同じか
// 5. チャプター（`X_PvrControl` の `X_GetTitleInfo`）が読めて、検証を通るか
//
// 出力は件数・形・時間だけ。アドレス・URL・局名・番組名・ID の値は出さない。

enum Phase6Command {
    /// 放送の種類（nasne の broadcastingType）。地上 2・BS 3 は torne mobile HB と同じ。CS は 4 と見込んで試す
    static let bands: [(name: String, type: Int)] = [("地上", 2), ("BS", 3), ("CS", 4)]
    /// Browse が 1 回に返す件数（実測の上限）
    static let browsePageSize = 50
    static func run() async throws {
        let host = requiredHost()
        let (device, registration) = try await connect(host)
        let soap = SOAPTransport(client: client)
        let catalog = RecordingCatalogService(soap: soap, device: device)
        let profile = catalog.profile

        if flag("--object-ids") {
            // Browse の item の id が「全録画の入れ物/pvr?id=<一覧の ID>」の形かを数える（一覧の ID から 1 件だけの DIDL を頼めるか）
            let didl = try await catalog.browse(profile.dlna.allRecordingsContainer)
            let prefix = profile.dlna.allRecordingsContainer + "/pvr?id="
            let exact = didl.filter { item in item.titleID.map { item.id == prefix + $0 } ?? false }.count
            say("Browse の item \(didl.count) 件・「入れ物/pvr?id=<一覧の ID>」とちょうど同じ \(exact) 件・違う \(didl.count - exact) 件")
            return
        }

        // ── 1. 局のロゴ ──
        say("")
        say("── 1. 局のロゴ ──")
        let guide = WebAPIProgramGuideService(transport: WebAPITransport(host: registration.host, client: client),
                                              tokens: try registration.tokenProvider())
        for band in bands {
            let start = Date()
            do {
                let logos = try await guide.logos(broadcastingType: band.type)
                var sizes: [String: Int] = [:]
                for png in logos.values { sizes[pngSize(png), default: 0] += 1 }
                // 絵として読めるか（共通固定色の PLTE を足した後。ImageIO で 1 枚目を作れるか）
                let decodable = logos.values.filter { png in
                    CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil
                }.count
                say("\(band.name)（\(band.type)）: \(logos.count) 件・絵として読める \(decodable) 件（\(elapsed(start))）・大きさ \(sizes.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: "・"))")
            } catch {
                say("\(band.name)（\(band.type)）: 取れない（\(kind(error))・\(elapsed(start))）")
            }
        }

        // ── 録画の一覧（xsrs）と Browse ──
        var start = Date()
        let titles = try await catalog.titles(withMetadata: false)
        say("")
        say("xsrs の一覧: \(titles.count) 件（\(elapsed(start))）")
        start = Date()
        let didl = try await catalog.browse(profile.dlna.allRecordingsContainer)
        say("Browse: \(didl.count) 件・\((didl.count + browsePageSize - 1) / browsePageSize) 頁（\(elapsed(start))）")

        // ── 2. Browse の順 ──
        say("")
        say("── 2. Browse が返す順 ──")
        let startByID = Dictionary(titles.compactMap { t in t.start.map { (t.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let xsrsIndex = Dictionary(titles.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let didlStarts = didl.map { item in item.titleID.flatMap { startByID[$0] } }
        let known = didlStarts.compactMap { $0 }
        say("Browse の録画のうち xsrs と結べた: \(known.count) / \(didl.count)")
        say("Browse の順 × 録画の開始日時: \(trend(known.map(\.timeIntervalSince1970)))")
        let didlXsrs = didl.compactMap { $0.titleID.flatMap { xsrsIndex[$0] } }
        say("Browse の順 × xsrs の順: \(trend(didlXsrs.map(Double.init)))")
        say("xsrs の順 × 録画の開始日時: \(trend(titles.compactMap { $0.start?.timeIntervalSince1970 }))")
        // 新しい録画（開始日時の新しい順に 10 件）が Browse の何番目・何頁目に来るか
        let newest = titles.filter { $0.start != nil }.sorted { $0.start! > $1.start! }.prefix(10).map(\.id)
        let didlPosition = Dictionary(didl.enumerated().compactMap { i, item in item.titleID.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
        let pages = newest.compactMap { didlPosition[$0] }.map { $0 / browsePageSize + 1 }
        say("新しい 10 件の Browse の頁: \(pages.map(String.init).joined(separator: "・"))（全 \((didl.count + browsePageSize - 1) / browsePageSize) 頁）")
        let xsrsPages = newest.compactMap { xsrsIndex[$0] }
        say("新しい 10 件の xsrs の位置: \(xsrsPages.map(String.init).joined(separator: "・"))（全 \(titles.count) 件）")

        // ── 3. BrowseMetadata ──
        say("")
        say("── 3. BrowseMetadata（1 件だけ） ──")
        let samples = Int(option("--metadata-samples") ?? "") ?? 5
        let names = profile.soap.arguments
        for id in newest.prefix(samples) {
            guard let position = didlPosition[id] else { continue }
            let listed = didl[position]
            let started = Date()
            do {
                let response = try await soap.call(
                    controlURL: device.controlURL(for: profile.soap.contentDirectory),
                    serviceType: profile.soap.contentDirectory.serviceType, action: profile.soap.browse.name,
                    arguments: [(names.objectID, listed.id), (names.browseFlag, ExtrasEndpoints.browseMetadataFlag),
                                (names.filter, names.allProperties), (names.startingIndex, "0"),
                                (names.requestedCount, "0"), (names.sortCriteria, "")])
                guard let result = response.result else { say("結果なし（\(elapsed(started))）"); continue }
                let items = try DIDLItem.parseDocument(result, source: "soap:Browse")
                guard let one = items.first else { say("item なし（\(elapsed(started))）"); continue }
                let sameRes = one.resources.map(\.url) == listed.resources.map(\.url)
                let sameTitle = one.title == listed.title && one.description == listed.description
                say("item \(items.count) 件・res \(one.resources.count)（一覧と\(sameRes ? "同じ" : "違う")）・題名と説明は一覧と\(sameTitle ? "同じ" : "違う")・ジャンル \(one.genres.count)（\(elapsed(started))）")
            } catch {
                say("読めない（\(kind(error))・\(elapsed(started))）")
            }
        }

        // ── 4. 保存した res と今の res ──
        say("")
        say("── 4. 保存した res の URL・DTCP のポート ──")
        do {
            let store = try LibraryStore(fileURL: LibraryStore.defaultFileURL())
            defer { Task { await store.close() } }
            if let saved = await store.titleList(udn: device.udn) {
                let hours = Date().timeIntervalSince(saved.fetchedAt) / 3600
                say("保存した一覧: \(saved.titles.count) 件・取ってから \(String(format: "%.1f", hours)) 時間")
                let fresh = Dictionary(didl.compactMap { item in item.titleID.map { ($0, item) } }, uniquingKeysWith: { a, _ in a })
                var compared = 0, sameAll = 0, gone = 0
                var differ: [String: Int] = [:]
                for title in saved.titles {
                    guard let now = fresh[title.id] else { gone += 1; continue }
                    compared += 1
                    let before = title.resources, after = now.resources
                    if before.map(\.url) == after.map(\.url),
                       before.map(\.dtcpHost) == after.map(\.dtcpHost), before.map(\.dtcpPort) == after.map(\.dtcpPort) {
                        sameAll += 1
                        continue
                    }
                    for (b, a) in zip(before, after) {
                        let bu = URLComponents(string: b.url), au = URLComponents(string: a.url)
                        if bu?.host != au?.host { differ["URL のホスト", default: 0] += 1 }
                        if bu?.port != au?.port { differ["URL のポート", default: 0] += 1 }
                        if bu?.path != au?.path { differ["URL のパス", default: 0] += 1 }
                        if bu?.query != au?.query { differ["URL の問い合わせ", default: 0] += 1 }
                        if b.dtcpHost != a.dtcpHost { differ["DTCP1HOST", default: 0] += 1 }
                        if b.dtcpPort != a.dtcpPort { differ["DTCP1PORT", default: 0] += 1 }
                    }
                    if before.count != after.count { differ["res の数", default: 0] += 1 }
                }
                say("比べた: \(compared) 件・すべて同じ \(sameAll) 件・違う \(compared - sameAll) 件・nasne から消えた \(gone) 件")
                if !differ.isEmpty { say("違った所: \(differ.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "・"))") }
            } else {
                say("保存した一覧が無い（この nasne のもの）")
            }
        } catch {
            say("キャッシュを開けない（\(kind(error))）")
        }
        // 時間を置いて比べるための控え（録画の ID と res の URL・DTCP のホストとポートの SHA-256 だけ。値は書かない）。
        // build/ は git に入らない。前の控えがあれば先に比べる
        let snapshotURL = URL(fileURLWithPath: "build/p6-res-snapshot.json")
        var current: [String: String] = [:]
        for item in didl {
            guard let id = item.titleID else { continue }
            let material = item.resources.map { "\($0.url)|\($0.dtcpHost ?? "")|\($0.dtcpPort.map(String.init) ?? "")" }.joined(separator: "\n")
            current[sha(id)] = sha(material)
        }
        if let data = try? Data(contentsOf: snapshotURL),
           let previous = try? JSONDecoder().decode(ResSnapshot.self, from: data) {
            let hours = Date().timeIntervalSince(previous.takenAt) / 3600
            let common = Set(previous.res.keys).intersection(current.keys)
            let same = common.filter { previous.res[$0] == current[$0] }.count
            say("前の控え（\(String(format: "%.1f", hours)) 時間前）と比べた: 両方にある \(common.count) 件・同じ \(same) 件・違う \(common.count - same) 件")
        } else {
            say("前の控えは無い")
        }
        if flag("--save-snapshot") {
            if let data = try? JSONEncoder().encode(ResSnapshot(takenAt: Date(), res: current)) {
                try? data.write(to: snapshotURL, options: .atomic)
                say("控えを build/ に書いた（\(current.count) 件・ハッシュだけ）")
            }
        }

        // ── 5. チャプター ──
        say("")
        say("── 5. チャプター（X_GetTitleInfo） ──")
        let pvrType = profile.soap.pvrControl.serviceType
        guard device.services[pvrType] != nil else {
            say("デバイス記述に X_PvrControl が無い")
            return
        }
        let pvr = device.controlURL(for: profile.soap.pvrControl)
        let limit = Int(option("--chapter-limit") ?? "") ?? 60
        let targets = titles.filter { $0.start != nil && !$0.isRecording }.sorted { $0.start! > $1.start! }.prefix(limit)
        var valid = 0, noChapters = 0, faults: [String: Int] = [:], reasons: [String: Int] = [:]
        var pointCounts: [Int] = [], times: [Double] = []
        for title in targets {
            let started = Date()
            do {
                let response = try await soap.call(controlURL: pvr, serviceType: pvrType, action: ExtrasEndpoints.getTitleInfoAction,
                                                   arguments: [(profile.soap.arguments.titleID, title.id)])
                times.append(Date().timeIntervalSince(started) * 1000)
                guard let result = response.result, let root = try? XMLTree.parse(Data(result.utf8), source: "soap:X_GetTitleInfo") else {
                    reasons["Result が読めない", default: 0] += 1; continue
                }
                _ = root
                switch TitleChapters.points(result: result, durationSeconds: title.durationSeconds ?? 0) {
                case .success(let points):
                    if points.count >= 2 { valid += 1; pointCounts.append(points.count) } else { noChapters += 1 }
                case .failure(let reason):
                    reasons[String(describing: reason), default: 0] += 1
                }
            } catch {
                times.append(Date().timeIntervalSince(started) * 1000)
                faults[kind(error), default: 0] += 1
            }
        }
        say("頼んだ: \(targets.count) 件（新しい順・録画中を除く）・検証を通り 2 点以上: \(valid) 件・点が 2 未満: \(noChapters) 件")
        if !reasons.isEmpty { say("検証で外れた理由: \(reasons.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "・"))") }
        if !faults.isEmpty { say("誤り: \(faults.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "・"))") }
        if !pointCounts.isEmpty {
            let sorted = pointCounts.sorted()
            say("点の数（間引いた後）: 最小 \(sorted.first!)・中央 \(sorted[sorted.count / 2])・最大 \(sorted.last!)")
        }
        if !times.isEmpty {
            let sorted = times.sorted()
            say("1 件の時間: 中央 \(Int(sorted[sorted.count / 2])) ms・最大 \(Int(sorted.last!)) ms")
        }
    }

    // MARK: - 補助

    struct ResSnapshot: Codable {
        let takenAt: Date
        let res: [String: String]
    }

    static func sha(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 文字の種類だけで形を表す（数字 9・符号 -・空白 _・そのほか ?。長さは 12 文字まで）
    static func shape(_ token: String) -> String {
        let mapped = token.prefix(12).map { c -> Character in
            if c.isNumber { return "9" }
            if c == "-" { return "-" }
            if c.isWhitespace { return "_" }
            return "?"
        }
        return token.isEmpty ? "空" : String(mapped) + (token.count > 12 ? "…" : "")
    }

    /// 並びが増えるか減るか（隣どうしの比較の数）
    static func trend(_ values: [Double]) -> String {
        guard values.count > 1 else { return "比べられない" }
        var up = 0, down = 0, equal = 0
        for (a, b) in zip(values, values.dropFirst()) {
            if b > a { up += 1 } else if b < a { down += 1 } else { equal += 1 }
        }
        return "増える \(up)・減る \(down)・同じ \(equal)"
    }

    /// PNG の IHDR の幅と高さ
    static func pngSize(_ png: Data) -> String {
        guard png.count >= 24 else { return "不明" }
        func u32(_ offset: Int) -> Int { png[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) } }
        return "\(u32(16))×\(u32(20))"
    }

    /// 誤りの種類（文面にアドレスが入りうるので、種類だけ）
    static func kind(_ error: any Error) -> String {
        if let error = error as? NasneError { return "\(error.category)\(error.code.map { " \($0)" } ?? "")" }
        return String(describing: type(of: error))
    }
}
