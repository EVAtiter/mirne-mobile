// torne mobile HB（MIT、© mar1mo-41414）の lib/core/endpoints.dart を Swift へ移植し、機器と版ごとの表に組み直したもの。
//
// 機器への頼み方（コマンド・URL・パス・ポート・SOAP のアクションと引数の名前・パラメータの名前と値・
// xsrs の頼みの文書の名前と値）は、処理の中に直に書かず、この表から引く。
// 表は機器と FW の版ごとに 1 組（`NasneProfile`）で持ち、組み立て（`NasneServices.live` など）で機器に合う組を選んで各サービスへ渡す。
// 載せるのは実機で確かめた範囲だけ（SIE 製の FW 2.60 は torne mobile HB の plan.md §11・§21・§24、Buffalo 製の FW 4.50 はこの開発の実測）。
// 応答の読み方（JSON・xsrs・DIDL の項目の名前）は、読む型（`DeviceInfo`・`XSRSItem`・`DIDLItem` など）が持つ。

import Foundation

// MARK: - 機器と版ごとの表

/// 1 つの機器（と FW の版）に対する頼み方の表
public struct NasneProfile: Sendable {
    /// 表の名前（ログに出す）
    public let id: String
    /// 当てはまる機器（デバイス記述の modelName）
    public let modelNames: Set<String>
    /// 確かめた FW の版（`softwareVersionGet` の値。選ぶときの手がかり・ログ）
    public let verifiedFirmwareVersions: [String]
    public let ports: NasnePorts
    public let webAPI: WebAPIEndpointTable
    public let soap: SOAPTable
    public let dlna: DLNATable
    public let xsrs: XSRSRequestVocabulary

    /// この機器に当てはまるか（modelName で見る）
    public func matches(modelName: String) -> Bool {
        modelNames.contains(modelName)
    }
}

/// 確かめた表の一覧と、機器に合う表の選び方
public enum NasneProfiles {
    /// 最初に確かめた表（SIE 製の FW 2.60〔torne mobile HB の実測〕と Buffalo 製の FW 4.50〔2026-11 の実測〕で、頼み方は同じだった）
    public static let base = NasneProfile(
        id: "nasne-base",
        modelNames: [NasneDevice.nasneModelName, NasneDevice.buffaloNasneModelName],
        verifiedFirmwareVersions: ["2.60", "4.50"],
        ports: NasnePorts(webAPI: 64210, recordingWrite: 64220, xsrs: 64230, dms: 58888, webVideo: 58890),
        webAPI: .base,
        soap: .base,
        dlna: .base,
        xsrs: .base)

    /// 確かめた表（新しい機種・版の表はここへ足す）
    public static let all: [NasneProfile] = [base]

    /// 機器に合う表が無いときに使う表（確かめた中で新しいもの）
    public static let standard = base

    /// 機器に合う表。modelName で選び、合うものが無ければ `standard`。
    /// FW の版で表が分かれたら、`firmwareVersion`（`softwareVersionGet`）でも選ぶ（今は 1 組なので見ていない）
    public static func profile(modelName: String, firmwareVersion: String? = nil) -> NasneProfile {
        all.first { $0.matches(modelName: modelName) } ?? standard
    }

    /// 機器の記述に合う表
    public static func profile(for device: NasneDevice) -> NasneProfile {
        profile(modelName: device.modelName)
    }
}

// MARK: - ポート

/// nasne の待ち受けるポート（実測。plan.md §11.3）
public struct NasnePorts: Sendable, Equatable {
    /// WebAPI（JSON・バイナリ）
    public let webAPI: Int
    /// 録画の書き込みの系統の WebAPI（再開位置の書き戻し。応答に `X-AV-Server-Info` の見出しが付く別のサービス。
    /// torne mobile HB 1.5.0 が SIE 製で測った。64210 では同じパスが 404）
    public let recordingWrite: Int
    /// UPnP SOAP（X_ScheduledRecording・X_PvrControl）
    public let xsrs: Int
    /// DMS（デバイス記述・ContentDirectory）
    public let dms: Int
    /// 録画の配信（`/web/video/pvr?id=…&quality=…`）
    public let webVideo: Int
}

// MARK: - 放送の種別

/// 放送の種別（アプリの中の値。モデルと控えに入る）。FW 2.60 では WebAPI の broadcastingType と xsrs の属性の値に等しい。
/// 実測したのは地上だけ（WebAPI の broadcastingType=2、SOAP の "DTT"）
public enum BroadcastingType {
    public static let terrestrial = 2
    /// BS（局のロゴを `channelLogoDataGet` で取れることを 2026-11-22 に Buffalo 製で確かめた）
    public static let bs = 3
    /// 110 度 CS（同上）
    public static let cs = 4
}

// MARK: - WebAPI

/// WebAPI の応答の形
public enum WebAPIResponseKind: Sendable {
    case json
    case binary
}

/// WebAPI のエンドポイントの待ち受けるポートの種類（番号は `NasnePorts`）
public enum WebAPIPort: Sendable, Equatable {
    case webAPI
    case recordingWrite
}

/// WebAPI のエンドポイント 1 つ
public struct WebAPIEndpoint: Sendable, Equatable, CustomStringConvertible {
    /// 先頭の / を含むパス（例：`/status/boxNameGet`）。トークンの計算にもこの文字列を使う
    public let path: String
    public let method: String
    /// 必ず要るパラメータ（実測）
    public let requiredParameters: [String]
    /// X-DTVToken が要るか（POST の Set 系と EPGGet・PINVerify）
    public let requiresToken: Bool
    public let responseKind: WebAPIResponseKind
    /// 待ち受けるポート（ほとんどは WebAPI の 64210）
    public let port: WebAPIPort

    init(_ path: String, method: String = "GET", requiredParameters: [String] = [], requiresToken: Bool = false,
         responseKind: WebAPIResponseKind = .json, port: WebAPIPort = .webAPI) {
        self.path = path
        self.method = method
        self.requiredParameters = requiredParameters
        self.requiresToken = requiresToken
        self.responseKind = responseKind
        self.port = port
    }

    public var description: String { "\(method) \(path)" }
}

/// WebAPI のパラメータの名前
public struct WebAPIParameterNames: Sendable {
    /// 放送の種別（`channelListGet`・`EPGVersionInfoGet`・`channelLogoDataGet`）
    public let broadcastingType: String
    /// HDD の番号（`HDDInfoGet`）
    public let hddID: String
    /// 録画の ID（`recordedContentResumePositionSet`。一覧の ID のまま）
    public let titleID: String
    /// 再開位置（`recordedContentResumePositionSet`。ミリ秒）
    public let resumePosition: String
}

/// WebAPI のエンドポイントの表
public struct WebAPIEndpointTable: Sendable {
    public let parameters: WebAPIParameterNames
    /// トークンを載せる見出しの名前
    public let tokenHeader: String
    /// バイナリの本文の Content-Type（`EPGGet`。正確にこの値でないと nasne のフレームワークが 400 で弾く。plan.md §21.1）
    public let binaryContentType: String

    // ── status：読み取り（GET・認証なし） ──
    public let softwareVersionGet: WebAPIEndpoint
    public let updateCheck: WebAPIEndpoint
    public let isFinishSetup: WebAPIEndpoint
    public let boxNameGet: WebAPIEndpoint
    public let currDateGet: WebAPIEndpoint
    public let areaInfoGet: WebAPIEndpoint
    public let channelListGet: WebAPIEndpoint
    public let hddListGet: WebAPIEndpoint
    public let hddInfoGet: WebAPIEndpoint
    public let bcasInfoGet: WebAPIEndpoint
    public let networkIfInfoGet: WebAPIEndpoint
    public let recNgListGet: WebAPIEndpoint
    public let liveStreamStatusListGet: WebAPIEndpoint
    public let requestClientInfoGet: WebAPIEndpoint
    public let epgVersionInfoGet: WebAPIEndpoint

    // ── recorded：件数（GET・認証なし） ──
    public let recordedContentCountGet: WebAPIEndpoint
    public let recordedContentMaxCountGet: WebAPIEndpoint

    // ── chEpg（バイナリ） ──
    public let channelLogoDataGet: WebAPIEndpoint
    /// 番組表（plan.md §24）。本文は専用のバイナリ形式、Content-Type は正確に `application/binary`、トークン必須
    public let epgGet: WebAPIEndpoint

    // ── recorded：再開位置の書き戻し（POST・ポート 64220） ──
    /// 録画の再開位置を書く。form で録画の ID と位置（ミリ秒）。nasne は秒に切り捨てて xsrs の `lastPlaybackTime` の
    /// `resumePoint` に置き、受け付けるたびに `lastPlaybackTime` を打ち直す。負の位置は errorcode 803。
    /// この口はトークンを検めない（torne mobile HB 1.5.0 が SIE 製で測った）ので付けない
    public let recordedContentResumePositionSet: WebAPIEndpoint

    // ── config：検証（POST・トークン必須） ──
    /// 本文なしで送る。トークンが正しいこと自体が検証になる（PIN そのものは送らない）
    public let pinVerify: WebAPIEndpoint

    /// 最初に確かめた表
    static let base: WebAPIEndpointTable = {
        let parameters = WebAPIParameterNames(broadcastingType: "broadcastingType", hddID: "id", titleID: "id", resumePosition: "position")
        let byType = [parameters.broadcastingType]
        return WebAPIEndpointTable(
            parameters: parameters,
            tokenHeader: "X-DTVToken",
            binaryContentType: "application/binary",
            softwareVersionGet: WebAPIEndpoint("/status/softwareVersionGet"),
            updateCheck: WebAPIEndpoint("/status/updateCheck"),
            isFinishSetup: WebAPIEndpoint("/status/isFinishSetup"),
            boxNameGet: WebAPIEndpoint("/status/boxNameGet"),
            currDateGet: WebAPIEndpoint("/status/currDateGet"),
            areaInfoGet: WebAPIEndpoint("/status/areaInfoGet"),
            channelListGet: WebAPIEndpoint("/status/channelListGet", requiredParameters: byType),
            hddListGet: WebAPIEndpoint("/status/HDDListGet"),
            hddInfoGet: WebAPIEndpoint("/status/HDDInfoGet", requiredParameters: [parameters.hddID]),
            bcasInfoGet: WebAPIEndpoint("/status/BCASInfoGet"),
            networkIfInfoGet: WebAPIEndpoint("/status/networkIfInfoGet"),
            recNgListGet: WebAPIEndpoint("/status/recNgListGet"),
            liveStreamStatusListGet: WebAPIEndpoint("/status/liveStreamStatusListGet"),
            requestClientInfoGet: WebAPIEndpoint("/status/requestClientInfoGet"),
            epgVersionInfoGet: WebAPIEndpoint("/status/EPGVersionInfoGet", requiredParameters: byType, responseKind: .binary),
            recordedContentCountGet: WebAPIEndpoint("/recorded/recordedContentCountGet"),
            recordedContentMaxCountGet: WebAPIEndpoint("/recorded/recordedContentMaxCountGet"),
            channelLogoDataGet: WebAPIEndpoint("/chEpg/channelLogoDataGet", requiredParameters: byType, responseKind: .binary),
            epgGet: WebAPIEndpoint("/chEpg/EPGGet", method: "POST", requiresToken: true, responseKind: .binary),
            recordedContentResumePositionSet: WebAPIEndpoint("/recorded/recordedContentResumePositionSet", method: "POST",
                                                             requiredParameters: [parameters.titleID, parameters.resumePosition],
                                                             port: .recordingWrite),
            pinVerify: WebAPIEndpoint("/config/PINVerify", method: "POST", requiresToken: true))
    }()
}

// MARK: - SOAP

/// UPnP のサービス 1 つ
public struct SOAPService: Sendable {
    /// serviceType の URN（デバイス記述を引く鍵であり、SOAPAction の名前空間）
    public let serviceType: String
    /// デバイス記述から control URL を解けなかったときに試す既定のポート
    public let defaultPort: Int
    /// デバイス記述から解けなかったときに試すパス（実測した形）
    public let fallbackControlPaths: [String]
}

/// SOAP のアクション 1 つ（どのサービスのどの名前か）
public struct SOAPAction: Sendable {
    public let service: SOAPService
    public let name: String
}

/// SOAP の引数の名前（入るものと出るもの）と、決まった値
public struct SOAPArgumentNames: Sendable {
    /// xsrs の文書を渡す引数（作成・変更・競合の確認）
    public let elements: String
    /// 予約の ID（削除で入り、作成で出る）
    public let recordScheduleID: String
    /// 録画の ID（`X_DeleteTitle`）
    public let titleID: String
    // 一覧（`X_GetRecordScheduleList`・`X_GetTitleList`・`Browse`）
    public let objectID: String
    public let browseFlag: String
    public let searchCriteria: String
    public let filter: String
    public let startingIndex: String
    public let requestedCount: String
    public let sortCriteria: String
    /// `Browse` で直下の子を読む値
    public let browseDirectChildren: String
    /// `Browse` で 1 件だけ（ObjectID の item そのもの）を読む値（2026-11-22 に Buffalo 製で確かめた。1 件 約 30 ms）
    public let browseMetadata: String
    /// すべての項目を返させる `Filter` の値
    public let allProperties: String
    /// あるだけ返させる `RequestedCount` の値（ただし 1 回に返す件数には上限がある）
    public let requestAll: Int
    /// 録画一覧（`X_GetTitleList`）で 1 回に頼む件数。0 だと既定の頁（200 件）しか返らないが、件数を指定すると 1 回でそこまで返る
    /// （SIE 製は 203・500、Buffalo 製は 647・1000 を指定して全件が返った。2026-11-21）。
    /// 頼む回数が減り、起動したときの読み込みが短くなる。全件に足りなければ頁を送る
    public let titleListRequestCount: Int
}

/// SOAP のサービスとアクションの表
public struct SOAPTable: Sendable {
    public let scheduledRecording: SOAPService
    public let pvrControl: SOAPService
    public let contentDirectory: SOAPService
    public let connectionManager: SOAPService
    public let arguments: SOAPArgumentNames

    // ── X_ScheduledRecording ──
    public var getRecordScheduleList: SOAPAction { SOAPAction(service: scheduledRecording, name: "X_GetRecordScheduleList") }
    public var getTitleList: SOAPAction { SOAPAction(service: scheduledRecording, name: "X_GetTitleList") }
    public var getConflictList: SOAPAction { SOAPAction(service: scheduledRecording, name: "X_GetConflictList") }
    public var createRecordSchedule: SOAPAction { SOAPAction(service: scheduledRecording, name: "X_CreateRecordSchedule") }
    public var updateRecordSchedule: SOAPAction { SOAPAction(service: scheduledRecording, name: "X_UpdateRecordSchedule") }
    public var deleteRecordSchedule: SOAPAction { SOAPAction(service: scheduledRecording, name: "X_DeleteRecordSchedule") }
    /// 録画の削除（2026-11-21 に Buffalo 製で確かめた。入る引数は TitleID だけ・出る値なし）
    public var deleteTitle: SOAPAction { SOAPAction(service: scheduledRecording, name: "X_DeleteTitle") }
    /// 録画の変更（保護の切り替えに使う。入る引数は Elements〔一覧の item を丸ごと〕・出る値は Result。torne mobile HB 1.5.0 が SIE 製で測った）
    public var updateTitle: SOAPAction { SOAPAction(service: scheduledRecording, name: "X_UpdateTitle") }

    // ── X_PvrControl ──
    /// 録画のチャプター（入る引数は TitleID〔一覧の ID〕。2026-11-22 に Buffalo 製で確かめた）
    public var getTitleInfo: SOAPAction { SOAPAction(service: pvrControl, name: "X_GetTitleInfo") }

    // ── ContentDirectory ──
    public var browse: SOAPAction { SOAPAction(service: contentDirectory, name: "Browse") }

    /// 記述が取れなかったときに、既定の control URL で作っておくサービス
    public var knownServices: [SOAPService] { [scheduledRecording, pvrControl, contentDirectory, connectionManager] }

    /// 最初に確かめた表（X_PvrControl の X_GetFirmwareVersion・X_GetLiveChList・X_GetTitleDetail もあると分かっているが、
    /// 使っていないのでアクションは載せない）
    static let base = SOAPTable(
        scheduledRecording: SOAPService(serviceType: "urn:schemas-xsrs-org:service:X_ScheduledRecording:2",
                                        defaultPort: 64230,
                                        fallbackControlPaths: ["/XSRS", "/xsrs/control/X_ScheduledRecording"]),
        pvrControl: SOAPService(serviceType: "urn:schemas-s-bras-org:service:X_PvrControl:1",
                                defaultPort: 64230, fallbackControlPaths: ["/X_PvrControl"]),
        contentDirectory: SOAPService(serviceType: "urn:schemas-upnp-org:service:ContentDirectory:1",
                                      defaultPort: 58888, fallbackControlPaths: ["/MediaServer_ContentDirectory/control"]),
        connectionManager: SOAPService(serviceType: "urn:schemas-upnp-org:service:ConnectionManager:1",
                                       defaultPort: 58888, fallbackControlPaths: ["/MediaServer_ConnectionManager/control"]),
        arguments: SOAPArgumentNames(
            elements: "Elements", recordScheduleID: "RecordScheduleID", titleID: "TitleID",
            objectID: "ObjectID", browseFlag: "BrowseFlag", searchCriteria: "SearchCriteria", filter: "Filter",
            startingIndex: "StartingIndex", requestedCount: "RequestedCount", sortCriteria: "SortCriteria",
            browseDirectChildren: "BrowseDirectChildren", browseMetadata: "BrowseMetadata", allProperties: "*", requestAll: 0,
            titleListRequestCount: 1000))
}

// MARK: - DLNA

/// DMS（ContentDirectory）の木の在りか
public struct DLNATable: Sendable {
    /// 全録画の入れ物
    public let allRecordingsContainer: String
    /// 入れ物の中の録画 1 件の item の id の、録画の ID の前に付く部分（`0/video/all/pvr?id=<一覧の ID>`。
    /// 2026-11-22 に Buffalo 製の 651 件すべてがこの形だった）
    public var recordingItemPrefix: String { allRecordingsContainer + recordingItemSeparator }
    /// 入れ物と録画の ID の間の部分
    public let recordingItemSeparator: String
    /// ライブの木の根（直下が帯域の container）
    public let liveTunerContainer: String
    /// 放送の種別 → 帯域の container id の末尾（例：地上は `DTTB`）
    public let liveBandSuffixes: [Int: String]

    /// 最初に確かめた表（地上の帯域は SIE 製・Buffalo 製とも `DTTB`）
    static let base = DLNATable(
        allRecordingsContainer: "0/video/all",
        recordingItemSeparator: "/pvr?id=",
        liveTunerContainer: "0/video/LiveTuner",
        liveBandSuffixes: [BroadcastingType.terrestrial: "DTTB"])
}

// MARK: - xsrs の頼みの文書

/// 予約の作成・変更で `Elements` に渡す xsrs の文書の名前と値（torne のひな形。plan.md §11.7・§12.5・§13.7）
public struct XSRSRequestVocabulary: Sendable {
    /// 文書の名前空間
    public let namespace: String
    /// 番組を指す desiredMatchingID の type 属性
    public let programMatchingType: String
    /// torne のひな形の作り手の値
    public let torneCreatorID: String
    /// 予約で送る録画先（画質によらず内蔵の HDD）。録画はこの値の HDD に入る（torne mobile HB 1.4.4 の実測）。
    /// torne のひな形は 3 倍で外付け（USBHDD）を送るが、外付けに入った録画は一覧に出ない・再生できないことがあるので送らない
    public let recordDestination: String
    /// 録画の保護の印の要素（一覧の item の子。0 = 保護なし・1 = 保護）
    public let titleProtectElement: String
    static let flagOn = "1"
    static let flagOff = "0"

    /// 作る予約の文書（item の id は空。日時は `+09:00` のコロン形。番組名の要素は無い）
    public func document(for schedule: NewRecordSchedule) -> String {
        let channel = schedule.channel
        let elements = [
            #"<item id="">"#,
            "<scheduledStartDateTime>\(NasneDateTime.format(schedule.start))</scheduledStartDateTime>",
            "<scheduledDuration>\(schedule.durationSeconds)</scheduledDuration>",
            "<scheduledConditionID>\(XMLTree.escapeText(schedule.conditionID))</scheduledConditionID>",
            #"<scheduledChannelID broadcastingType="\#(channel.broadcastingType)" channelType="\#(channel.channelType)">"#
                + "\(channel.serviceIDHex)</scheduledChannelID>",
            "<desiredQualityMode>\(schedule.desiredQualityMode)</desiredQualityMode>",
            #"<desiredMatchingID type="\#(programMatchingType)">"# + "\(schedule.desiredMatchingID)</desiredMatchingID>",
            "<reservationCreatorID>\(XMLTree.escapeText(schedule.reservationCreatorID ?? torneCreatorID))</reservationCreatorID>",
            "<priorityFlag>\(schedule.priorityFlag)</priorityFlag>",
            "<recordDestinationID>\(XMLTree.escapeText(recordDestination))</recordDestinationID>",
            "</item>",
        ]
        return wrap(elements.joined(separator: Self.creationElementSeparator))
    }

    /// 疎な更新の文書（変える項目と priorityFlag だけ。並びは torne mobile HB と同じ。画質を変えるときは録画先も送る）
    public func document(for update: ScheduleUpdate) -> String {
        var item = #"<item id="\#(XMLTree.escapeAttribute(update.id))">"#
        if let conditionID = update.conditionID {
            item += "<scheduledConditionID>\(XMLTree.escapeText(conditionID))</scheduledConditionID>"
        }
        if let mode = update.desiredQualityMode { item += "<desiredQualityMode>\(mode)</desiredQualityMode>" }
        item += "<priorityFlag>\(update.priorityFlag)</priorityFlag>"
        if update.desiredQualityMode != nil {
            item += "<recordDestinationID>\(XMLTree.escapeText(recordDestination))</recordDestinationID>"
        }
        item += "</item>"
        return wrap(item)
    }

    /// 録画の保護を切り替える文書：一覧で受け取った item の要素を受け取ったまま入れ、保護の印の値だけを変える
    /// （torne mobile HB 1.5.0 が SIE 製で測った形。録画は item の id 属性で決まり、ほかの引数は無い）。
    /// 保護の印の要素が無い item は、`</item>` の直前に足す
    public func protectionDocument(itemXML: String, protect: Bool) -> String {
        let flag = "<\(titleProtectElement)>\(protect ? Self.flagOn : Self.flagOff)</\(titleProtectElement)>"
        let pattern = "<\(titleProtectElement)\\s*/>|<\(titleProtectElement)>[^<]*</\(titleProtectElement)>"
        let updated: String
        if let range = itemXML.range(of: pattern, options: .regularExpression) {
            updated = itemXML.replacingCharacters(in: range, with: flag)
        } else if let end = itemXML.range(of: "</item>", options: .backwards) {
            updated = itemXML.replacingCharacters(in: end, with: flag + "</item>")
        } else {
            updated = itemXML
        }
        return wrap(updated)
    }

    /// 作成の文書の要素の間に入れる空白。これまで実機へ送って通った文書の形のまま（XML としては意味を持たない）
    static let creationElementSeparator = String(repeating: " ", count: 12)

    private func wrap(_ item: String) -> String {
        #"<?xml version="1.0"?><xsrs xmlns="\#(namespace)">"# + item + "</xsrs>"
    }

    /// 最初に確かめた値
    static let base = XSRSRequestVocabulary(
        namespace: "urn:schemas-xsrs-org:metadata-1-0/x_srs/",
        programMatchingType: "SI_PROGRAMID",
        torneCreatorID: "2000",
        recordDestination: "HDD",
        titleProtectElement: "titleProtectFlag")
}
