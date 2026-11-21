import Foundation

// 資格情報の要らない読み取りの計測：録画の配信 URL への HEAD（シークの下調べ）と、
// ライブの局の一覧の Browse（ライブ視聴の下調べ）。
//
// 守ること:
// - nasne には読み取り（SOAP の一覧・Browse・HEAD）しか送らない。ライブの res には HEAD も送らない
//   （チューナーが動くかが分かっていないため。受信は合意を取ってから で）
// - 番組名・局名・アドレス・ポート・nid / tsid / sid の値を出さない。出すのは件数・形・DLNA の申告だけ

// MARK: - contentFeatures の表示

enum ContentFeaturesReport {
    /// contentFeatures を 1 行に（プロファイル・OP の解釈・主なフラグ）
    static func line(_ features: DLNAContentFeatures) -> String {
        var parts: [String] = []
        if let profile = features.profile { parts.append("PN \(profile)") }
        if let op = features.fields[DLNAContentFeatures.operationsField] {
            let time = features.supportsTimeSeek.map { $0 ? "可" : "不可" } ?? "?"
            let bytes = features.supportsByteRange.map { $0 ? "可" : "不可" } ?? "?"
            parts.append("OP \(op)（時間指定 \(time)・バイト範囲 \(bytes)）")
        } else {
            parts.append("OP なし")
        }
        if let ps = features.fields[DLNAContentFeatures.playSpeedsField] { parts.append("PS \(ps)") }
        if let ci = features.fields[DLNAContentFeatures.conversionField] { parts.append("CI \(ci)") }
        if let raw = features.fields[DLNAContentFeatures.flagsField] {
            let flags = features.flags.map { $0.isEmpty ? "なし" : $0.map(\.label).joined(separator: ",") } ?? "読めない"
            parts.append("FLAGS \(raw.prefix(8))…（\(flags)）")
        }
        let known: Set = [DLNAContentFeatures.profileField, DLNAContentFeatures.operationsField,
                          DLNAContentFeatures.playSpeedsField, DLNAContentFeatures.conversionField,
                          DLNAContentFeatures.flagsField]
        let others = features.fields.keys.filter { !known.contains($0) }.sorted()
        // ほかの項目（DTCP.COM_FLAGS・ARIB.OR.JP_PN など）も申告の値で、機器の固有値は含まない
        if !others.isEmpty { parts.append("ほか \(others.map { "\($0)=\(features.fields[$0] ?? "")" }.joined(separator: ","))") }
        return parts.joined(separator: "・")
    }

    /// protocolInfo の 4 番目のフィールド（最後の `:` の後ろ）
    static func fourthField(_ protocolInfo: String) -> String {
        protocolInfo.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    }
}

// MARK: - HEAD

@MainActor
enum HeadCommand {
    /// 値を出してよい応答の見出し（数・申告だけで、アドレスや機器の固有値を含まないもの）
    static let printableHeaders = [
        "Content-Length", "Accept-Ranges", "Content-Range", "Connection",
        "transferMode.dlna.org", "contentFeatures.dlna.org", "TimeSeekRange.dlna.org",
        "availableSeekRange.dlna.org", "realTimeInfo.dlna.org", "Range.dtcp.com", "Content-Range.dtcp.com",
        "PRAGMA", "Cache-Control",
    ]
    /// 時間指定・バイト範囲の要求の見出し
    static let timeSeekHeader = "TimeSeekRange.dlna.org"
    static let rangeHeader = "Range"
    static let dtcpRangeHeader = "Range.dtcp.com"

    static func run() async throws {
        let host = requiredHost()
        let (picked, all) = try await RecordingPicker.pick()
        say("録画: \(all.count) 件・再開位置あり \(all.filter { ($0.resumePointSeconds ?? 0) > 0 }.count) 件"
            + "・前回の再生の時刻あり \(all.filter { $0.lastPlaybackTime != nil }.count) 件")
        // 日時は出してよい（番組名・局名は出さない）
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = NasneDateTime.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        say("選んだ録画: \(picked.start.map(formatter.string) ?? "日時なし")・長さ \(picked.durationSeconds ?? 0) 秒・再開位置 \(picked.resumePointSeconds.map { "\($0) 秒" } ?? "なし")"
            + "・res \(picked.resources.count) 本")

        let wanted = option("--quality")
        let resources = picked.playableResources.filter { wanted == nil || $0.quality == wanted }
        guard !resources.isEmpty else {
            fail("その画質の res がない（ある画質: \(picked.resources.compactMap(\.quality).joined(separator: "・"))）")
        }
        for resource in resources {
            guard let url = URL(string: resource.url) else { continue }
            say("")
            say("res \(resource.quality ?? "なし"): \(url.path)・cleartextSize \(resource.cleartextSize.map { "\($0) バイト" } ?? "なし")")
            say("  protocolInfo の申告: \(ContentFeaturesReport.line(DLNAContentFeatures(ContentFeaturesReport.fourthField(resource.protocolInfo))))")
            try await head(url, extra: nil, host: host, cleartextSize: resource.cleartextSize)
            if let seek = option("--seek").flatMap(Int.init) {
                try await head(url, extra: (timeSeekHeader, "npt=\(seek)-"), host: host, cleartextSize: nil)
            }
            if let offset = option("--range").flatMap(Int64.init) {
                try await head(url, extra: (rangeHeader, "bytes=\(offset)-"), host: host, cleartextSize: nil)
                try await head(url, extra: (dtcpRangeHeader, "bytes=\(offset)-"), host: host, cleartextSize: nil)
            }
        }
    }

    /// HEAD を 1 回送り、形を出す
    private static func head(_ url: URL, extra: (String, String)?, host: String, cleartextSize: Int64?) async throws {
        var request = DTCPContentHTTP.request(url, method: "HEAD")
        if let extra { request.setValue(extra.1, forHTTPHeaderField: extra.0) }
        let start = Date()
        let response: HTTPURLResponse
        do {
            (_, response) = try await client.send(request)
        } catch {
            say("  HEAD\(extra.map { "（\($0.0): \($0.1)）" } ?? ""): 失敗（\(error)）")
            return
        }
        say("  HEAD\(extra.map { "（\($0.0): \($0.1)）" } ?? ""): HTTP \(response.statusCode)（\(elapsed(start))）")
        let (mediaType, parameters) = DTCPContentHTTP.parseContentType(response.value(forHTTPHeaderField: "Content-Type") ?? "")
        var typeLine = "    Content-Type: \(mediaType.isEmpty ? "なし" : mediaType)・パラメータ \(parameters.keys.sorted().joined(separator: ","))"
        if let format = parameters["contentformat"] { typeLine += "・CONTENTFORMAT \(format)" }
        if let akeHost = parameters["dtcp1host"] { typeLine += "・DTCP1HOST は nasne と\(akeHost == host ? "同じ" : "別")" }
        say(typeLine)
        let names = response.allHeaderFields.keys.compactMap { $0 as? String }.sorted { $0.lowercased() < $1.lowercased() }
        say("    見出し: \(names.joined(separator: ","))")
        for name in printableHeaders {
            guard let value = response.value(forHTTPHeaderField: name) else { continue }
            if name == "contentFeatures.dlna.org" {
                say("    \(name): \(ContentFeaturesReport.line(DLNAContentFeatures(value)))")
            } else {
                say("    \(name): \(value)")
            }
        }
        if let cleartextSize, let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) {
            say("    Content-Length − cleartextSize: \(length - cleartextSize) バイト")
        }
    }
}

// MARK: - ライブの局の一覧

@MainActor
enum LiveCommand {
    static func run() async throws {
        let host = requiredHost()
        let (device, registration) = try await connect(host)
        let catalog = RecordingCatalogService(soap: SOAPTransport(client: client), device: device)
        let start = Date()
        let bands = try await DLNALiveCatalogService(catalog: catalog).bands()
        say("LiveTuner: 帯域 \(bands.count) 個（\(elapsed(start))）")
        // 地上の局が channelListGet と同じ (nid, tsid, sid) の空間かを確かめる（値は出さない）
        let terrestrial = try await WebAPIDeviceInfoService(transport: WebAPITransport(host: registration.host, client: client)).channels()
        let terrestrialKeys = Set(terrestrial.map { [$0.networkID, $0.transportStreamID, $0.serviceID] })

        for band in bands {
            let channels = band.channels
            say("")
            say("帯域 \(band.containerID.split(separator: "/").last.map(String.init) ?? "?")（\(band.title)）: 局 \(channels.count) 件")
            let identified = channels.filter { $0.networkID != nil && $0.transportStreamID != nil && $0.serviceID != nil }
            let matched = identified.filter {
                terrestrialKeys.contains([$0.networkID!, $0.transportStreamID!, $0.serviceID!])
            }
            say("  item id から nid・tsid・svid が読めた \(identified.count) 件・channelListGet（地上）と一致 \(matched.count) 件")
            say("  channelNr あり \(channels.filter { $0.channelNumber != nil }.count) 件・局名あり \(channels.filter { $0.channelName != nil }.count) 件"
                + "・番組の時刻あり \(channels.filter { $0.programStart != nil && $0.programEnd != nil }.count) 件")
            var qualities: [String: Int] = [:]
            var paths: [String: Int] = [:]
            var profiles: [String: Int] = [:]
            var dtcpPorts = Set<Int>()
            var sameHost = 0
            var otherHost = 0
            for resource in channels.flatMap(\.resources) {
                qualities[resource.quality ?? "なし", default: 0] += 1
                if let components = URLComponents(string: resource.url) {
                    let keys = components.queryItems?.map(\.name).joined(separator: "&") ?? ""
                    paths["\(components.port.map { ":\($0)" } ?? "")\(components.path)?\(keys)", default: 0] += 1
                }
                let features = DLNAContentFeatures(ContentFeaturesReport.fourthField(resource.protocolInfo))
                profiles[ContentFeaturesReport.line(features), default: 0] += 1
                if let port = resource.dtcpPort { dtcpPorts.insert(port) }
                if let akeHost = resource.dtcpHost { if akeHost == host { sameHost += 1 } else { otherHost += 1 } }
            }
            say("  res の quality: \(qualities.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "・"))")
            for (path, count) in paths.sorted(by: { $0.key < $1.key }) { say("  URL の形: \(path)（\(count) 本）") }
            say("  DTCP1HOST: nasne と同じ \(sameHost) 本・別 \(otherHost) 本・DTCP1PORT の種類 \(dtcpPorts.count) 個")
            for (line, count) in profiles.sorted(by: { $0.key < $1.key }) { say("  申告（\(count) 本）: \(line)") }
        }
        say("")
        say("（ライブの res には HEAD も GET も送っていない）")
    }
}
