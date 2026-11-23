import Foundation
import Testing

// 機器への頼み方の表。

@Suite("機器への頼み方の表")
struct NasneProfileTests {
    /// 表の外に書いてはいけない頼み方の文字列（パス・SOAP のアクションと引数・サービスの URN・ポート・木の在りか・xsrs の値）
    static let requestPatterns = [
        #""/(status|recorded|chEpg|config|web|nasne_home)/"#,
        #""X_[A-Za-z]+""#,
        #""urn:schemas-(xsrs|s-bras|upnp-org:service)"#,
        #"\b(64210|64220|64230|58888|58890)\b"#,
        #""0/video/"#,
        #""(Browse|Elements|RecordScheduleID|TitleID|ObjectID|BrowseFlag|BrowseDirectChildren|StartingIndex|RequestedCount|SortCriteria|SearchCriteria|SI_PROGRAMID|DTTB|USBHDD|X-DTVToken|application/binary)""#,
    ]

    /// 頼み方を持ってよいファイル（アプリの表と、計測コマンドが試す確かめていない口の表）
    static let tableFiles: Set<String> = ["NasneKit/Endpoints.swift", "Probe/ExtrasProbe.swift"]

    @Test("頼み方の文字列は表の中にだけある（処理の中に直に書かない）")
    func requestsOnlyInTables() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
            .resolvingSymlinksInPath()
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(files.count > 50)
        let patterns = try Self.requestPatterns.map { try NSRegularExpression(pattern: $0) }
        var found: [String] = []
        for file in files {
            // リポジトリが /tmp（実体は /private/tmp）の下にあると、列挙の結果だけ /private が付くので、両方そろえてから外す
            let relative = file.resolvingSymlinksInPath().path.replacingOccurrences(of: sources.path + "/", with: "")
            guard !Self.tableFiles.contains(relative) else { continue }
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (number, line) in lines.enumerated() {
                // 注釈は説明なので数えない
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                let range = NSRange(code.startIndex..., in: code)
                if patterns.contains(where: { $0.firstMatch(in: code, range: range) != nil }) {
                    found.append("\(relative):\(number + 1)")
                }
            }
        }
        #expect(found.isEmpty, "表の外に頼み方がある: \(found)")
    }

    @Test("機種に合う表を選ぶ。合うものが無ければ標準の表")
    func selection() {
        #expect(NasneProfiles.profile(modelName: NasneDevice.nasneModelName).id == NasneProfiles.base.id)
        #expect(NasneProfiles.profile(modelName: NasneDevice.buffaloNasneModelName).id == NasneProfiles.base.id)
        #expect(NasneProfiles.profile(modelName: "unknown").id == NasneProfiles.standard.id)
        #expect(NasneProfiles.profile(for: NasneDevice.direct(host: NasneFixture.host)).id == NasneProfiles.base.id)
    }

    @Test("作る予約の文書は、表に移す前と同じバイト列（実機へ送って通った形）")
    func creationDocumentUnchanged() throws {
        let start = try #require(NasneDateTime.parse("2026-11-20T21:00:00+09:00"))
        let schedule = NewRecordSchedule(start: start, durationSeconds: 3600,
                                         channel: ScheduleChannel(broadcastingType: 2, channelType: 2, serviceID: 0x4010),
                                         networkID: 0x7E01, eventID: 0x1A2B)
        let gap = String(repeating: " ", count: 12)
        let expected = #"<?xml version="1.0"?><xsrs xmlns="urn:schemas-xsrs-org:metadata-1-0/x_srs/"><item id="">"#
            + gap + "<scheduledStartDateTime>2026-11-20T21:00:00+09:00</scheduledStartDateTime>"
            + gap + "<scheduledDuration>3600</scheduledDuration>"
            + gap + "<scheduledConditionID></scheduledConditionID>"
            + gap + #"<scheduledChannelID broadcastingType="2" channelType="2">0x4010</scheduledChannelID>"#
            + gap + "<desiredQualityMode>100</desiredQualityMode>"
            + gap + #"<desiredMatchingID type="SI_PROGRAMID">,,0x7e01,0x1a2b</desiredMatchingID>"#
            + gap + "<reservationCreatorID>2000</reservationCreatorID>"
            + gap + "<priorityFlag>0</priorityFlag>"
            + gap + "<recordDestinationID>HDD</recordDestinationID>"
            + gap + "</item></xsrs>"
        #expect(NasneProfiles.standard.xsrs.document(for: schedule) == expected)
    }

    @Test("組み立ては機器の表をサービスへ渡す（SOAP の頼みは表のアクション名と引数で送る）")
    func assembledServicesUseProfile() async throws {
        let soap = NasneProfiles.standard.soap
        let action = soap.deleteRecordSchedule
        let envelope = #"<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>"#
            + "<u:\(action.name)Response xmlns:u=\"\(action.service.serviceType)\"/></s:Body></s:Envelope>"
        let http = MockHTTP()
        http.reply(soap.scheduledRecording.fallbackControlPaths[0], method: "POST", body: Data(envelope.utf8))
        let catalog = RecordingCatalogService(soap: SOAPTransport(client: http), device: NasneDevice.direct(host: NasneFixture.host))
        try await catalog.delete(id: "7")
        let request = try #require(http.sentRequests.first)
        #expect(request.value(forHTTPHeaderField: "SOAPAction")
                == "\"\(soap.scheduledRecording.serviceType)#\(soap.deleteRecordSchedule.name)\"")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("<\(soap.arguments.recordScheduleID)>7</\(soap.arguments.recordScheduleID)>"))
    }
}
