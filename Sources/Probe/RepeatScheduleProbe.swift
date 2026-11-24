import Foundation

// 予約の繰り返しの値（scheduledConditionID）を、こちらの作成・変更で入れられるかを測る（2026-11-24）。
//
//   mirne-mobile-probe repeat-schedule --host <nasne> --at "yyyy-MM-dd HH:mm"                          （選んで形を見るだけ。何も送らない）
//   mirne-mobile-probe repeat-schedule --host <nasne> --at "yyyy-MM-dd HH:mm" --set d --send            （変更で繰り返しの値を入れる。1 回だけ送る）
//   mirne-mobile-probe repeat-schedule --host <nasne> --at "yyyy-MM-dd HH:mm" --recreate w15 --send     （消して、同じ番組で繰り返しの値を入れて作り直す。消す 1 回・作る 1 回）
//   mirne-mobile-probe repeat-schedule --host <nasne> --at "yyyy-MM-dd HH:mm" --set 1 --quality x3 --send  （繰り返しの値と画質を 1 回の変更で一緒に送る。録画先は今の値のまま）
//
// 守ること:
// - **使う人が作った試しの予約だけを、そのたび確かめてから書き換える。** 予約は始まる分（日本時間）で 1 件に決まり、
//   番組に紐付いていて、まだ始まっていないときだけ選ぶ。`--send` が無ければ、選んだ予約の形と送る値を出すだけで何も送らない
// - 送るのは NasneKit の予約の変更・削除・作成（アプリと同じ経路）だけ。自動で再試行しない
// - 繰り返しの値は読んだ形（1・d・w と曜日 1〜2 桁）だけを受け付ける
// - 番組名・予約の ID・局・eventId の値は出さない。出すのは繰り返しの値・長さ・画質・件数・応答の形だけ

@MainActor
enum RepeatScheduleCommand {
    /// 送った後に読み直すまでの間（すぐの読み直しに加えて、遅れて変わらないかを見る）
    static let recheckDelay: Duration = .seconds(2)
    /// 受け付ける繰り返しの値（公式のアプリで作った予約で読んだ形：d = 毎日・w + 曜日〔日曜 0〕1 桁 = 毎週・2 桁 = その曜日からその曜日まで。
    /// 1 = 一回録画〔こちらが空で作った予約は 1 で保存されていた〕。繰り返しから一回録画へ戻す変更を測るために足した）
    static let conditionPattern = "^(1|d|w[0-6]{1,2})$"

    static func run() async throws {
        guard let at = option("--at") else { fail("--at \"yyyy-MM-dd HH:mm\"（日本時間で予約の始まる分）で試しの予約を指定する") }
        let set = option("--set")
        let recreate = option("--recreate")
        if set != nil && recreate != nil { fail("--set と --recreate はどちらか 1 つ") }
        // 画質も一緒に変える（--set と組で使う）
        let quality: Int? = switch option("--quality") {
        case nil: nil
        case "dr": QualityMode.dr
        case "x3": QualityMode.threeTimes
        case let other?: fail("--quality \(other) は受け付けない（dr か x3）")
        }
        if quality != nil && set == nil { fail("--quality は --set と一緒に使う") }
        for value in [set, recreate].compactMap({ $0 }) where value.range(of: conditionPattern, options: .regularExpression) == nil {
            fail("繰り返しの値 \(value) は受け付けない（1・d・w と曜日 1〜2 桁だけ）")
        }

        let (device, _) = try await connect(requiredHost())
        let catalog = RecordingCatalogService(soap: SOAPTransport(client: client), device: device)
        let before = try await catalog.schedules()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = NasneDateTime.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let matched = before.filter { formatter.string(from: $0.start) == at }
        guard matched.count == 1, let schedule = matched.first else { fail("--at \(at) に始まる予約が \(matched.count) 件（1 件のときだけ選ぶ）") }
        say("選んだ予約: 長さ \(schedule.durationSeconds / 60) 分・画質 \(QualityMode.label(schedule.desiredQualityMode))・繰り返しの値 \(show(schedule.conditionID))"
            + "・priorityFlag \(schedule.priorityFlag)・番組に紐付き \(schedule.isLinkedToProgram ? "はい" : "いいえ")（番組名・ID は出さない）・一覧 \(before.count) 件")
        guard schedule.isLinkedToProgram else { fail("番組に紐付いた予約だけを選ぶ（手動の予約は対象にしない）") }
        guard schedule.start > Date() else { fail("始まった予約には送らない") }

        if let set {
            say("送る値: 変更で繰り返しの値を \(show(schedule.conditionID)) → \(set)"
                + (quality.map { "・画質を \(QualityMode.label(schedule.desiredQualityMode)) → \(QualityMode.label($0))（録画先は今の値のまま）" } ?? ""))
        } else if let recreate {
            say("送る値: 消してから、同じ番組・長さ・画質で繰り返しの値 \(recreate) の予約を作る")
        } else {
            say("（--set か --recreate が無いので、形を見るだけ）")
            return
        }
        guard flag("--send") else {
            say("（--send が無いので何も送らない）")
            return
        }

        if let set {
            let start = Date()
            do {
                try await catalog.update(ScheduleUpdate(id: schedule.id, priorityFlag: schedule.priorityFlag,
                                                        repeatMode: repeatMode(set, catalog: catalog),
                                                        desiredQualityMode: quality, recordDestinationID: schedule.recordDestinationID))
                say("\(catalog.profile.soap.updateRecordSchedule.name): 通った（\(elapsed(start))）")
            } catch {
                say("\(catalog.profile.soap.updateRecordSchedule.name): 断られた（\(elapsed(start))）・\(error)")
            }
            try await report("送った直後", catalog: catalog, id: schedule.id, before: schedule)
            try await Task.sleep(for: recheckDelay)
            try await report("\(recheckDelay) 後", catalog: catalog, id: schedule.id, before: schedule)
        } else if let recreate {
            guard let eventID = schedule.eventID else { fail("eventId が読めない") }
            // 局のネットワーク ID はアプリの作成と同じく局の一覧から引く
            let channels = try await WebAPIDeviceInfoService(transport: WebAPITransport(host: device.host, client: client))
                .channels(broadcastingType: schedule.channel.broadcastingType)
            guard let channel = channels.first(where: { $0.serviceID == schedule.channel.serviceID }) else { fail("局の一覧に予約の局が無い") }
            var draft = NewRecordSchedule(start: schedule.start, durationSeconds: schedule.durationSeconds, channel: schedule.channel,
                                          networkID: channel.networkID, eventID: eventID, desiredQualityMode: schedule.desiredQualityMode)
            draft.repeatMode = repeatMode(recreate, catalog: catalog)
            // 録画先は元の予約のまま
            draft.recordDestination = schedule.recordDestinationID == catalog.profile.xsrs.externalRecordDestination
                ? .externalHDD : .internalHDD

            var start = Date()
            do {
                try await catalog.delete(id: schedule.id)
                say("\(catalog.profile.soap.deleteRecordSchedule.name): 通った（\(elapsed(start))）")
            } catch {
                say("\(catalog.profile.soap.deleteRecordSchedule.name): 断られた（\(elapsed(start))）・\(error)。作らずに止める")
                return
            }
            start = Date()
            let newID: String
            do {
                newID = try await catalog.create(draft)
                say("\(catalog.profile.soap.createRecordSchedule.name): 通った（\(elapsed(start))）・ID の形 \(newID.allSatisfy(\.isNumber) ? "10 進" : "そのほか")")
            } catch {
                say("\(catalog.profile.soap.createRecordSchedule.name): 断られた（\(elapsed(start))）・\(error)")
                let after = try await catalog.schedules()
                say("一覧 \(after.count) 件（消す前 \(before.count) 件）")
                return
            }
            try await report("作った直後", catalog: catalog, id: newID, before: schedule)
            try await Task.sleep(for: recheckDelay)
            try await report("\(recheckDelay) 後", catalog: catalog, id: newID, before: schedule)
        }
    }

    /// 読み直して、繰り返しの値・件数・選んだ予約と違う項目の名前を出す（値は出さない。繰り返しの値だけは出す）
    static func report(_ label: String, catalog: RecordingCatalogService, id: String, before: RecordSchedule) async throws {
        let schedules = try await catalog.schedules()
        guard let now = schedules.first(where: { $0.id == id }) else {
            say("\(label): 一覧 \(schedules.count) 件・予約が一覧に無い")
            return
        }
        var changed: [String] = []
        if now.start != before.start { changed.append("開始") }
        if now.durationSeconds != before.durationSeconds { changed.append("長さ") }
        if now.channel != before.channel { changed.append("局") }
        if now.desiredQualityMode != before.desiredQualityMode { changed.append("画質") }
        if now.desiredMatchingID != before.desiredMatchingID { changed.append("matchingID") }
        if now.reservationCreatorID != before.reservationCreatorID { changed.append("作り手") }
        if now.priorityFlag != before.priorityFlag { changed.append("priorityFlag") }
        if now.recordDestinationID != before.recordDestinationID { changed.append("録画先") }
        if (now.title == nil) != (before.title == nil) { changed.append("番組名の有無") }
        say("\(label): 一覧 \(schedules.count) 件・繰り返しの値 \(show(now.conditionID))・画質 \(QualityMode.label(now.desiredQualityMode))・ほかに元の予約と違う項目 \(changed.isEmpty ? "なし" : changed.joined(separator: " "))")
    }

    static func show(_ conditionID: String) -> String { conditionID.isEmpty ? "（空）" : conditionID }

    /// 繰り返しの値を、アプリと同じ表で繰り返しの種類にする（表で読めない値は送らない）
    static func repeatMode(_ value: String, catalog: RecordingCatalogService) -> ScheduleRepeat {
        guard let mode = catalog.profile.xsrs.scheduleRepeat(conditionID: value) else { fail("繰り返しの値 \(value) は表に無い") }
        return mode
    }
}
