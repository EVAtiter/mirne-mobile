import Foundation

// 録画を 1 件消して、nasne の振る舞いを測る。
//
//   mirne-mobile-probe delete-title --host <nasne> --at "yyyy-MM-dd HH:mm"            （選ぶだけ。何も送らない）
//   mirne-mobile-probe delete-title --host <nasne> --at "yyyy-MM-dd HH:mm" --send     （X_DeleteTitle を 1 回だけ送る）
//
// 守ること:
// - **使う人が指定した試しの録画だけを、そのたび確かめてから消す。** 録画は始まった分（日本時間）で
//   1 件に決まるときだけ選ぶ。`--send` が無ければ、選んだ録画の形と件数を出すだけで何も送らない
// - 送るのは 1 回だけで、自動で再試行しない
// - 番組名・タイトル ID・アドレスは出さない。出すのは長さ・保護・録画中・応答の形・件数だけ

@MainActor
enum DeleteTitleCommand {
    static func run() async throws {
        guard let at = option("--at") else { fail("--at \"yyyy-MM-dd HH:mm\"（日本時間で録画の始まった分）で試しの録画を指定する") }
        let (device, registration) = try await connect(requiredHost())
        let catalog = RecordingCatalogService(soap: SOAPTransport(client: client), device: device)
        let info = WebAPIDeviceInfoService(transport: WebAPITransport(host: registration.host, client: client))

        let before = try await catalog.titles()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = NasneDateTime.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let matched = before.filter { $0.start.map(formatter.string) == at }
        guard matched.count == 1, let title = matched.first else { fail("--at \(at) に始まった録画が \(matched.count) 件（1 件のときだけ選ぶ）") }
        say("選んだ録画: 長さ \(title.durationSeconds ?? 0) 秒・保護 \(title.isProtected ? "あり" : "なし")・録画中 \(title.isRecording ? "はい" : "いいえ")"
            + "・res \(title.resources.count) 件（番組名・タイトル ID は出さない）")
        try await sayCounts("送る前", catalog: catalog, info: info, titles: before)

        guard flag("--send") else {
            say("（--send が無いので何も送らない）")
            return
        }
        let start = Date()
        do {
            let soap = catalog.profile.soap
            let action = soap.deleteTitle
            let response = try await SOAPTransport(client: client).call(
                controlURL: device.controlURL(for: action.service), serviceType: action.service.serviceType,
                action: action.name, arguments: [(soap.arguments.titleID, title.id)])
            say("\(action.name): 通った（\(elapsed(start))）・応答の項目 \(response.values.keys.sorted())")
        } catch {
            say("\(catalog.profile.soap.deleteTitle.name): 断られた（\(elapsed(start))）・\(error)")
        }

        let after = try await catalog.titles()
        try await sayCounts("送った後", catalog: catalog, info: info, titles: after)
        say("選んだ録画: \(after.contains { $0.id == title.id } ? "一覧に残っている" : "一覧から消えた")")
    }

    /// 3 つの件数（X_GetTitleList・Browse の 0/video/all・recordedContentCountGet）
    static func sayCounts(_ label: String, catalog: RecordingCatalogService, info: WebAPIDeviceInfoService,
                          titles: [RecordedTitle]) async throws {
        let browsed = try await catalog.browse(catalog.profile.dlna.allRecordingsContainer).count
        let counted = try await info.titleCounts().count
        say("\(label): X_GetTitleList \(titles.count) 件・Browse \(browsed) 件・件数 API \(counted) 件")
    }
}
