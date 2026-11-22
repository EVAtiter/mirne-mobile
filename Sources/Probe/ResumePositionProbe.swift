import Foundation

// 録画の再開位置を 1 回書き戻して、nasne の振る舞いを測る。
//
//   mirne-mobile-probe resume-position --host <nasne> --survey                                       （一覧全体の新着・前回の再生・再開位置の組を数えるだけ）
//   mirne-mobile-probe resume-position --host <nasne> --at "yyyy-MM-dd HH:mm"                      （選んで今の値を見るだけ。何も送らない）
//   mirne-mobile-probe resume-position --host <nasne> --at "yyyy-MM-dd HH:mm" --send --seconds <秒>   （再開位置を 1 回だけ書く。0 は消す）
//
// 守ること:
// - **使う人が指定した試しの録画だけに、そのたび確かめてから書く。** 録画は始まった分（日本時間）で 1 件に決まるときだけ選ぶ。
//   `--send` が無ければ、選んだ録画の今の値を出すだけで何も送らない
// - 送るのは 1 回だけで、自動で再試行しない。送るのはアプリと同じ作り（`WebAPIResumePositionService`）
// - 番組名・タイトル ID・アドレスは出さない。出すのは長さ・再開位置・前回の再生の時刻・新着・応答の形・変わった要素の名前だけ

@MainActor
enum ResumePositionCommand {
    /// 送った後に読み直すまでの間（すぐの読み直しに加えて、遅れて変わらないかを見る）
    static let recheckDelay: Duration = .seconds(2)

    static func run() async throws {
        if flag("--survey") { return try await survey() }
        guard let at = option("--at") else { fail("--at \"yyyy-MM-dd HH:mm\"（日本時間で録画の始まった分）で試しの録画を指定する") }
        let (device, registration) = try await connect(requiredHost())
        let catalog = RecordingCatalogService(soap: SOAPTransport(client: client), device: device)
        let writer = WebAPIResumePositionService(transport: WebAPITransport(host: registration.host, client: client, profile: catalog.profile))

        let before = try await catalog.titles(withMetadata: false)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = NasneDateTime.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let matched = before.filter { $0.start.map(formatter.string) == at }
        guard matched.count == 1, let title = matched.first else { fail("--at \(at) に始まった録画が \(matched.count) 件（1 件のときだけ選ぶ）") }
        say("選んだ録画: 長さ \(title.durationSeconds ?? 0) 秒・録画中 \(title.isRecording ? "はい" : "いいえ")（番組名・タイトル ID は出さない）")
        guard let item = try await listedItem(catalog, id: title.id) else { fail("一覧から item を切り出せなかった") }
        sayValues("今の値", item)

        guard flag("--send") else {
            say("（--send が無いので何も送らない）")
            return
        }
        guard let text = option("--seconds"), let seconds = Double(text), seconds >= 0 else { fail("--send には --seconds <0 以上の秒> を付ける") }
        guard !title.isRecording else { fail("録画中の録画には送らない") }

        let start = Date()
        do {
            try await writer.setResumePosition(id: title.id, seconds: seconds)
            say("recordedContentResumePositionSet（\(Int(seconds)) 秒）: 通った（\(elapsed(start))）")
        } catch {
            say("recordedContentResumePositionSet（\(Int(seconds)) 秒）: 断られた（\(elapsed(start))）・\(error)")
        }

        try await report("送った直後", catalog: catalog, id: title.id, before: item)
        try await Task.sleep(for: recheckDelay)
        try await report("\(recheckDelay) 後", catalog: catalog, id: title.id, before: item)
    }

    /// 一覧全体の新着の印・前回の再生の時刻・再開位置の組み合わせを数える（読み取りだけ。件数だけを出す）
    static func survey() async throws {
        let (device, _) = try await connect(requiredHost())
        let catalog = RecordingCatalogService(soap: SOAPTransport(client: client), device: device)
        let titles = try await catalog.titles(withMetadata: false)
        var counts: [String: Int] = [:]
        for title in titles {
            let key = "新着 \(title.isNew ? 1 : 0)・前回の再生 \(title.lastPlaybackTime == nil ? "なし" : "あり")・"
                + "再開位置 \((title.resumePointSeconds ?? 0) > 0 ? "あり" : "0")\(title.isRecording ? "・録画中" : "")"
            counts[key, default: 0] += 1
        }
        say("一覧 \(titles.count) 件")
        for (key, count) in counts.sorted(by: { $0.key < $1.key }) { say("  \(key): \(count) 件") }
        // 前回の再生の時刻が録り始めより前（再生されたことの無い録画に入る既定の値か）を数える
        let beforeStart = titles.filter { title in
            guard let last = title.lastPlaybackTime, let start = title.start else { return false }
            return last < start
        }.count
        say("前回の再生の時刻が録り始めより前: \(beforeStart) 件")
    }

    /// 一覧の item（受け取ったまま切り出して読む）
    static func listedItem(_ catalog: RecordingCatalogService, id: String) async throws -> XSRSItem? {
        guard let xml = try await catalog.listedTitleXML(id: id) else { return nil }
        return try XSRSItem.parseDocument("<xsrs>\(xml)</xsrs>", source: "probe").first
    }

    /// 再開位置・前回の再生の時刻・新着の印
    static func sayValues(_ label: String, _ item: XSRSItem) {
        say("\(label): 再開位置 \(item.attribute("lastPlaybackTime", "resumePoint") ?? "なし") 秒・"
            + "前回の再生 \(item["lastPlaybackTime"] ?? "なし")・新着 \(item["titleNewFlag"] ?? "なし")")
    }

    /// 読み直して、値と変わった要素の名前を出す
    static func report(_ label: String, catalog: RecordingCatalogService, id: String, before: XSRSItem) async throws {
        guard let after = try await listedItem(catalog, id: id) else {
            say("\(label): 選んだ録画が一覧に無い")
            return
        }
        sayValues(label, after)
        let names = Set(before.fields.keys).union(after.fields.keys).union(before.attributes.keys).union(after.attributes.keys)
        let changed = names.sorted().filter { before.fields[$0] != after.fields[$0] || before.attributes[$0] != after.attributes[$0] }
        say("  値が変わった要素: \(changed.isEmpty ? "なし" : changed.joined(separator: " "))")
    }
}
