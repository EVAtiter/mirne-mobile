import Foundation

// 外付けの容量の試験（小さい USB ドライブで外付けを一杯にする）の読み取り。nasne には読み取りしか送らない。
//
//   mirne-mobile-probe hdd       --host <nasne>   HDD の一覧・詳細と、録画先ごとの状態（X_GetMediaInfo）の数値
//   mirne-mobile-probe schedules --host <nasne> --fields   予約の項目の名前と値（番組名などは文字数だけ）
//   mirne-mobile-probe info      --host <nasne> --recng    録画の失敗の項目の名前と値（番組名などは文字数だけ）
//
// HDD のシリアル・名前、番組名、局（サービス ID・ネットワーク ID）は出さない。

/// 項目の値を、出してよい形にする
enum ProbeFieldValue {
    /// 値を出さず文字数だけにする項目（番組名・説明・名前）
    static let textOnlyKeys: Set<String> = ["title", "description", "name", "channelName", "serialNumber"]

    /// 数字を伏せて形だけにする項目の名前の一部（局・番組を指す ID。地域が分かりうる）
    static let shapeOnlyKeyParts = ["Channel", "Matching", "serviceId", "serviceID", "networkId", "eventId"]

    /// そのまま出してよい値の形（数・16 進・時刻・短い記号）
    static let plainPattern = #"^[0-9A-Za-z_.:+\-]{0,32}$"#

    static func describe(key: String, value: String) -> String {
        if textOnlyKeys.contains(key) { return "<文字 \(value.count) 字>" }
        // 0 は局も番組も指さない（手動の予約の eventId など）ので、そのまま出す
        if shapeOnlyKeyParts.contains(where: { key.contains($0) }), value != "0" {
            return value.replacingOccurrences(of: "[0-9a-fA-F]", with: "9", options: .regularExpression)
        }
        if value.range(of: plainPattern, options: .regularExpression) != nil { return value.isEmpty ? "（空）" : value }
        return "<文字 \(value.count) 字>"
    }

    /// `名前=値` を名前の順に並べる
    static func line(_ fields: [String: String]) -> String {
        fields.keys.sorted().map { "\($0)=\(describe(key: $0, value: fields[$0]!))" }.joined(separator: "・")
    }
}

enum HDDCommand {
    static func run() async throws {
        let (device, registration) = try await connect(requiredHost())
        let info = WebAPIDeviceInfoService(transport: WebAPITransport(host: registration.host, client: client))
        for hdd in try await info.hddList() {
            say("HDD \(hdd.id): \(hdd.isInternal ? "内蔵" : "外付け")・マウント \(hdd.isMounted ? "済み" : "なし")・登録 \(hdd.isRegistered ? "済み" : "なし")")
            guard hdd.isConnected else { continue }
            do {
                let detail = try await info.hddInfo(id: hdd.id)
                say("  形式 \(detail.format)・全体 \(detail.totalBytes) バイト・使用 \(detail.usedBytes) バイト・空き \(detail.freeBytes) バイト")
            } catch {
                say("  詳細は読めなかった（\(NasneDiagnostics.summary(error))）")
            }
        }
        let catalog = RecordingCatalogService(soap: SOAPTransport(client: client), device: device)
        for (label, destination) in [("内蔵", RecordDestination.internalHDD), ("外付け", .externalHDD)] {
            let start = Date()
            do {
                var values = try await catalog.mediaInfo(destination: destination)
                // Buffalo 製は値を Result の文書に包んで返す（2026-11-25 に実測）。中の要素を名前と値に開く
                if let result = values.removeValue(forKey: "Result") {
                    let root = try XMLTree.parse(Data(result.utf8), source: "soap:X_GetMediaInfo")
                    say("  Result の根: <\(root.name)>・子 \(root.children.count) 個")
                    for element in [root] + root.children { for child in element.children where child.children.isEmpty {
                        values["\(element.name)/\(child.name)"] = child.text
                    } }
                }
                say("X_GetMediaInfo \(label)（\(catalog.profile.xsrs.destinationID(destination))）: \(ProbeFieldValue.line(values))（\(elapsed(start))）")
            } catch {
                say("X_GetMediaInfo \(label): 失敗（\(NasneDiagnostics.summary(error))・\(elapsed(start))）")
            }
        }
    }
}

/// `schedules --fields`：予約の 1 件ずつの項目の名前と値
func printScheduleFields(_ items: [XSRSItem]) {
    for (index, item) in items.enumerated() {
        var fields = item.fields
        for (element, attributes) in item.attributes {
            for (name, value) in attributes { fields["\(element)@\(name)"] = value }
        }
        say("予約 \(index + 1): \(ProbeFieldValue.line(fields))")
    }
}

/// `info --recng`：録画の失敗の 1 件ずつの項目の名前と値
func printRecNgFields(transport: WebAPITransport) async throws {
    let json = try await transport.getJSON(transport.endpoints.recNgListGet)
    let top = json.values.keys.filter { $0 != "item" }.sorted()
    say("録画の失敗の一覧の項目: \(top.map { "\($0)=\(ProbeFieldValue.describe(key: $0, value: "\(json.values[$0]!)"))" }.joined(separator: "・"))")
    for (index, item) in json.objects("item").enumerated() {
        // 入れ子の辞書（desiredMatchingID など）は「親.子」の名前に開く
        var fields: [String: String] = [:]
        for (key, value) in item.values {
            if let nested = value as? [String: Any] {
                for (child, childValue) in nested { fields["\(key).\(child)"] = "\(childValue)" }
            } else {
                fields[key] = "\(value)"
            }
        }
        say("録画の失敗 \(index + 1): \(ProbeFieldValue.line(fields))")
    }
}
