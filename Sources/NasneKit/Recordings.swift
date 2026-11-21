// torne mobile HB（MIT、© mar1mo-41414）の lib/core/parsing/xsrs.dart・parsing/didl.dart・models/schedule.dart・
// models/title.dart・models/didl.dart・services/title_catalog.dart・services/schedule_service.dart・
// services/metadata.dart の読み取りの部分を Swift へ移植したもの（予約の作成・変更・削除は Phase 2 で足す）。

import Foundation

// MARK: - xsrs

/// xsrs の `item` 1 つ（`id` 属性と、子の要素の文字・属性）
public struct XSRSItem: Sendable {
    public let id: String
    /// 子の要素の名前 → 文字
    public let fields: [String: String]
    /// 子の要素の名前 → 属性
    public let attributes: [String: [String: String]]

    public subscript(_ name: String) -> String? { fields[name] }

    public func attribute(_ element: String, _ name: String) -> String? { attributes[element]?[name] }

    /// xsrs の文書（SOAP の Result の文字列）を読む
    public static func parseDocument(_ text: String, source: String) throws -> [XSRSItem] {
        let root = try XMLTree.parse(text, source: source)
        guard root.name == "xsrs" else { throw NasneError.parse(source, "根の要素が <xsrs> でない") }
        return root.children(named: "item").map { item in
            var fields: [String: String] = [:]
            var attributes: [String: [String: String]] = [:]
            for child in item.children {
                fields[child.name] = child.text
                if !child.attributes.isEmpty { attributes[child.name] = child.attributes }
            }
            return XSRSItem(id: item.attributes["id"] ?? "", fields: fields, attributes: attributes)
        }
    }
}

/// xsrs の `scheduledChannelID`（属性 + serviceID の `0x%04x`）
public struct ScheduleChannel: Sendable, Equatable, Codable {
    public var broadcastingType: Int
    public var channelType: Int
    public var serviceID: Int

    public var serviceIDHex: String { String(format: "0x%04x", serviceID) }

    static func parse(_ item: XSRSItem, source: String) throws -> ScheduleChannel {
        guard let text = item["scheduledChannelID"]?.trimmingCharacters(in: .whitespaces) else {
            throw NasneError.parse(source, "scheduledChannelID が無い")
        }
        let serviceID: Int?
        if text.hasPrefix("0x") || text.hasPrefix("0X") {
            serviceID = Int(text.dropFirst(2), radix: 16)
        } else {
            serviceID = Int(text)
        }
        guard let serviceID else { throw NasneError.parse(source, "scheduledChannelID が数でない") }
        return ScheduleChannel(
            broadcastingType: Int(item.attribute("scheduledChannelID", "broadcastingType") ?? "") ?? BroadcastingType.terrestrial,
            channelType: Int(item.attribute("scheduledChannelID", "channelType") ?? "") ?? BroadcastingType.terrestrial,
            serviceID: serviceID)
    }
}

/// 画質（xsrs の desiredQualityMode。実測した値だけ。plan.md §28.6）
public enum QualityMode {
    public static let dr = 100
    public static let threeTimes = 230

    /// 公式の表記。知らない値は数のまま（呼び方を作らない）
    public static func label(_ value: Int) -> String {
        switch value {
        case dr: return "DR"
        case threeTimes: return "3倍"
        default: return String(value)
        }
    }
}

/// 予約 1 件（`X_GetRecordScheduleList`）
public struct RecordSchedule: Sendable, Equatable {
    /// 一覧の item id（10 進の文字列）。作成の応答の `0x` 付きの形は使わない（削除で 803 になる）
    public var id: String
    public var start: Date
    public var durationSeconds: Int
    public var conditionID: String
    public var channel: ScheduleChannel
    public var desiredQualityMode: Int
    public var desiredMatchingID: String
    public var reservationCreatorID: String
    public var priorityFlag: Int
    public var recordDestinationID: String
    /// nasne が番組名を引けたときだけある
    public var title: String?

    public var end: Date { start.addingTimeInterval(TimeInterval(durationSeconds)) }

    /// 番組の eventId（`desiredMatchingID` の 4 つの値の最後。0 は時刻を指定した手動の予約）。読めなければ nil
    public var eventID: Int? {
        guard let last = desiredMatchingID.split(separator: ",").last?.trimmingCharacters(in: .whitespaces) else { return nil }
        if last.hasPrefix("0x") || last.hasPrefix("0X") { return Int(last.dropFirst(2), radix: 16) }
        return Int(last)
    }

    /// 番組に紐付けた予約か（eventId が 0 でない）。手動の予約は終わった後も一覧に残る
    public var isLinkedToProgram: Bool { (eventID ?? 0) != 0 }

    init(item: XSRSItem, source: String) throws {
        guard let start = NasneDateTime.parse(item["scheduledStartDateTime"]) else {
            throw NasneError.parse(source, "scheduledStartDateTime が読めない")
        }
        func integer(_ name: String) throws -> Int {
            guard let text = item[name] else { return 0 }
            guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else {
                throw NasneError.parse(source, "\"\(name)\" が数でない")
            }
            return value
        }
        id = item.id
        self.start = start
        durationSeconds = try integer("scheduledDuration")
        conditionID = item["scheduledConditionID"] ?? ""
        channel = try ScheduleChannel.parse(item, source: source)
        desiredQualityMode = try integer("desiredQualityMode")
        desiredMatchingID = item["desiredMatchingID"] ?? ""
        reservationCreatorID = item["reservationCreatorID"] ?? ""
        priorityFlag = try integer("priorityFlag")
        recordDestinationID = item["recordDestinationID"] ?? ""
        title = item["title"].map(BroadcastText.normalize)
    }
}

/// 予約の疎な更新（torne mobile HB §13.7 の実機行列）。
///
/// `priorityFlag` は必須で、ほかに変える項目が 1 つ以上要る（priorityFlag だけは Fault 853、priorityFlag が無いと 402）。
/// 受け付けられても値が変わらないことがある（priorityFlag 0→1・画質 100→101 は変わらなかった）ので、送った後は読み直した値を正とする。
/// 開始時刻・長さはこの更新では変えられない（作り直す）
public struct ScheduleUpdate: Sendable, Equatable {
    /// 一覧の item id
    public var id: String
    /// 今の値をそのまま送る（必須）
    public var priorityFlag: Int
    public var conditionID: String?
    /// 画質。変えるときは、作成と同じ組の録画先も一緒に送る（2026-11-19。組は `XSRSRequestVocabulary` が持つ）
    public var desiredQualityMode: Int?

    public init(id: String, priorityFlag: Int, conditionID: String? = nil, desiredQualityMode: Int? = nil) {
        self.id = id
        self.priorityFlag = priorityFlag
        self.conditionID = conditionID
        self.desiredQualityMode = desiredQualityMode
    }

    /// priorityFlag のほかに変える項目があるか
    public var hasChange: Bool { conditionID != nil || desiredQualityMode != nil }

    /// 画質の変更
    public static func quality(_ mode: Int, of schedule: RecordSchedule) -> ScheduleUpdate {
        ScheduleUpdate(id: schedule.id, priorityFlag: schedule.priorityFlag, desiredQualityMode: mode)
    }
}

/// 予約の数の上限（101 件目は Fault 836。torne mobile HB §74.7）
public enum ScheduleLimits {
    public static let maximumCount = 100
}

/// 作る予約（torne の全項目のひな形で送る。plan.md §11.7・§12.5）
public struct NewRecordSchedule: Sendable, Equatable {
    public var start: Date
    public var durationSeconds: Int
    public var channel: ScheduleChannel
    /// 局のネットワーク ID（desiredMatchingID に入れる）
    public var networkID: Int
    /// 番組の eventId。0 は時刻を指定した手動の予約
    public var eventID: Int
    public var desiredQualityMode: Int
    /// 空は nasne の既定（"1" に直して保存される）
    public var conditionID = ""
    /// 作り手。nil は torne のひな形の作り手（値は `XSRSRequestVocabulary` が持つ）
    public var reservationCreatorID: String?
    public var priorityFlag = 0

    public init(start: Date, durationSeconds: Int, channel: ScheduleChannel, networkID: Int, eventID: Int = 0,
                desiredQualityMode: Int = QualityMode.dr) {
        self.start = start
        self.durationSeconds = durationSeconds
        self.channel = channel
        self.networkID = networkID
        self.eventID = eventID
        self.desiredQualityMode = desiredQualityMode
    }

    /// 送る形の desiredMatchingID（`,,0x<networkID>,0x<eventID>`。保存されると 4 つの値の形に直る）
    public var desiredMatchingID: String {
        String(format: ",,0x%04x,0x%04x", networkID, eventID)
    }

    /// 作成の応答の ID（`0x` + 一覧の 10 進の ID）を一覧の形に直す（`0x` のままだと削除が 803 になる）
    public static func normalizedID(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        return text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
    }
}

// MARK: - DIDL

/// DIDL の `res` 1 つ（再生の在りか）。再生に使うので捨てずに持つ（録画一覧のキャッシュにも入る）
public struct TitleResource: Sendable, Equatable, Codable {
    public var url: String
    public var protocolInfo: String
    /// protocolInfo の DTCP1HOST（AKE の相手）
    public var dtcpHost: String?
    /// protocolInfo の DTCP1PORT（毎回変わる。plan.md §11.8）
    public var dtcpPort: Int?
    public var durationSeconds: Double?
    /// `dlna:cleartextSize`（暗号化前の大きさ・バイト）
    public var cleartextSize: Int64?
    /// URL の `quality`（dr・x3・mobile など）
    public var quality: String?

    /// URL に `cp` の引数が付いた res（ムーブ専用）。再生に使わない
    public var isMoveOnly = false

    /// モバイル（低ビットレート版）の quality の値
    public static let mobileQuality = "mobile"
    /// ムーブ専用の res を示す URL の引数の名前（pydtcpip の `profiles/nasne.py`。値は見ず、あるかだけを見る）
    public static let moveOnlyParameter = "cp"

    init(element: XMLTreeElement) {
        url = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        protocolInfo = element.attributes["protocolInfo"] ?? ""
        func parameter(_ name: String) -> String? {
            guard let range = protocolInfo.range(of: "\(name)=") else { return nil }
            let rest = protocolInfo[range.upperBound...]
            return String(rest.prefix { $0 != ";" && $0 != ":" })
        }
        dtcpHost = parameter("DTCP1HOST")
        dtcpPort = parameter("DTCP1PORT").flatMap { Int($0) }
        if let text = element.attributes["duration"] {
            let parts = text.split(separator: ":")
            if parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]) {
                durationSeconds = hours * 3600 + minutes * 60 + seconds
            }
        }
        cleartextSize = (element.attributes["cleartextSize"]).flatMap { Int64($0) }
        let queryItems = URLComponents(string: url)?.queryItems ?? []
        quality = queryItems.first { $0.name == "quality" }?.value
        isMoveOnly = queryItems.contains { $0.name == Self.moveOnlyParameter }
    }
}

/// DIDL の `container` 1 つ（ライブの帯域など、子を持つ入れ物）
public struct DIDLContainer: Sendable, Equatable {
    /// 例：`0/video/LiveTuner/DTTB`
    public var id: String
    public var parentID: String
    public var title: String
    /// `childCount` 属性（nasne は付けないことがある）
    public var childCount: Int?
}

/// DIDL の 1 件（container か item）。頁送りで件数を数えるために、両方を 1 列に並べる
public enum DIDLEntry: Sendable {
    case container(DIDLContainer)
    case item(DIDLItem)

    /// DIDL-Lite の文書（Browse の Result）を、文書の順に読む
    public static func parseDocument(_ text: String, source: String) throws -> [DIDLEntry] {
        let root = try XMLTree.parse(text, source: source)
        guard root.name == "DIDL-Lite" else { throw NasneError.parse(source, "根の要素が <DIDL-Lite> でない") }
        return root.children.compactMap { element in
            switch element.name {
            case "container":
                return .container(DIDLContainer(id: element.attributes["id"] ?? "",
                                                parentID: element.attributes["parentID"] ?? "",
                                                title: BroadcastText.normalize(element.childText("title") ?? ""),
                                                childCount: element.attributes["childCount"].flatMap { Int($0) }))
            case "item":
                return .item(DIDLItem(element: element))
            default:
                return nil
            }
        }
    }
}

/// DIDL の `item` 1 つ（録画 1 件、またはライブの局 1 つのメタデータ）
public struct DIDLItem: Sendable {
    /// 例：`0/video/all/pvr?id=…`・`0/video/LiveTuner/DTTB/ch?nid=…&tsid=…&svid=…`
    public var id: String
    public var parentID: String = ""
    public var title: String
    public var description: String?
    public var longDescription: String?
    public var channelName: String?
    /// `av:COGCount`（残りのコピー回数）
    public var copyCountRemaining: Int?
    /// `upnp:channelNr`（DIDL の番号。リモコンの番号ではない。ライブの item にある）
    public var channelNumber: Int?
    /// `upnp:genre`（公式の表記のまま。1 つの番組に複数ありうる）
    public var genres: [String] = []
    /// `arib:audioComponentType`（ARIB の音声の component_type。2 = 二重音声（1/0+1/0）、3 = ステレオ）
    public var audioComponentType: Int?
    /// `arib:multiESInfo`（1 なら音声などの ES が複数ある番組）
    public var multiESInfo: Int?
    /// `upnp:scheduledStartTime`・`scheduledEndTime`（ライブの item では、いま放送中の番組の時刻）
    public var scheduledStart: Date?
    public var scheduledEnd: Date?
    public var resources: [TitleResource]

    /// id の末尾のタイトル ID（xsrs との結合の鍵。plan.md §12.5）
    public var titleID: String? {
        guard let range = id.range(of: "pvr?id=") else { return nil }
        return String(id[range.upperBound...].prefix { $0 != "&" })
    }

    init(id: String, title: String, resources: [TitleResource]) {
        self.id = id
        self.title = title
        self.resources = resources
    }

    init(element: XMLTreeElement) {
        self.init(id: element.attributes["id"] ?? "",
                  title: BroadcastText.normalize(element.childText("title") ?? ""),
                  resources: [])
        parentID = element.attributes["parentID"] ?? ""
        for child in element.children {
            let text = child.text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch child.name {
            case "res": resources.append(TitleResource(element: child))
            case "description": description = BroadcastText.normalize(child.text)
            case "longDescription":
                // あらすじと出演者の 2 つがある。両方をつなげて持つ
                let normalized = BroadcastText.normalize(child.text)
                longDescription = longDescription.map { "\($0)\n\(normalized)" } ?? normalized
            case "channelName": channelName = BroadcastText.normalize(child.text)
            case "channelNr": channelNumber = Int(text)
            case "genre": if !text.isEmpty { genres.append(BroadcastText.normalize(text)) }
            case "audioComponentType": audioComponentType = Int(text)
            case "multiESInfo": multiESInfo = Int(text)
            case "COGCount": copyCountRemaining = Int(text)
            case "scheduledStartTime": scheduledStart = DIDLDateTime.parse(text)
            case "scheduledEndTime": scheduledEnd = DIDLDateTime.parse(text)
            default: break
            }
        }
    }

    /// DIDL-Lite の文書（Browse の Result）の item だけを読む
    public static func parseDocument(_ text: String, source: String) throws -> [DIDLItem] {
        try DIDLEntry.parseDocument(text, source: source).compactMap {
            if case .item(let item) = $0 { return item }
            return nil
        }
    }
}

/// DIDL の時刻（`2026-11-17T14:05:00+09:00` の形。torne mobile HB の実測）
enum DIDLDateTime {
    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

// MARK: - 録画タイトル

/// 録画 1 件（xsrs を主に、DIDL で補う。画面は出所を知らない）。
/// 録画一覧のキャッシュ（`LibraryStore`）は、この形を JSON にして保存する
public struct RecordedTitle: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var title: String
    public var start: Date?
    public var durationSeconds: Int?
    public var channel: ScheduleChannel?
    public var desiredQualityMode: Int?
    public var isProtected: Bool
    public var isNew: Bool
    public var isRecording: Bool
    /// 前回の再生の時刻
    public var lastPlaybackTime: Date?
    /// 再開位置（秒）。`lastPlaybackTime` の `resumePoint` 属性
    public var resumePointSeconds: Int?
    // ── DIDL から ──
    public var description: String?
    public var longDescription: String?
    public var channelName: String?
    public var copyCountRemaining: Int?
    /// ジャンル（DIDL の `upnp:genre`。公式の表記のまま）
    public var genres: [String] = []
    /// DIDL の音声の申告（`arib:audioComponentType`・`arib:multiESInfo`）。実際の TS の ES の数とは限らない
    public var audioComponentType: Int?
    public var multiESInfo: Int?
    public var resources: [TitleResource] = []
    /// 番組の開始・終わり（DIDL の `upnp:scheduledStartTime`・`scheduledEndTime`）。
    /// `start`（xsrs の `scheduledStartDateTime`）は実際に録り始めた時刻で、番組の開始より十数秒前になることがある
    public var programStart: Date?
    public var programEnd: Date?

    init(item: XSRSItem, source: String) throws {
        id = item.id
        title = BroadcastText.normalize(item["title"] ?? "")
        start = NasneDateTime.parse(item["scheduledStartDateTime"])
        durationSeconds = item["scheduledDuration"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        channel = item["scheduledChannelID"] == nil ? nil : try ScheduleChannel.parse(item, source: source)
        desiredQualityMode = item["desiredQualityMode"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        isProtected = item["titleProtectFlag"] == "1"
        isNew = item["titleNewFlag"] == "1"
        isRecording = item["recordingFlag"] == "1"
        lastPlaybackTime = NasneDateTime.parse(item["lastPlaybackTime"])
        resumePointSeconds = item.attribute("lastPlaybackTime", "resumePoint").flatMap { Int($0) }
    }

    mutating func merge(_ didl: DIDLItem) {
        description = didl.description ?? description
        longDescription = didl.longDescription ?? longDescription
        channelName = didl.channelName ?? channelName
        copyCountRemaining = didl.copyCountRemaining ?? copyCountRemaining
        if !didl.genres.isEmpty { genres = didl.genres }
        audioComponentType = didl.audioComponentType ?? audioComponentType
        multiESInfo = didl.multiESInfo ?? multiESInfo
        programStart = didl.scheduledStart ?? programStart
        programEnd = didl.scheduledEnd ?? programEnd
        resources = didl.resources
    }

    /// 録り始めから番組の開始までの秒（番組の開始が分からない・録り始めより前・録画の長さを超えるなら nil）。
    /// nasne はほとんどの録画を番組の 12〜15 秒前から録る（2026-11-20 実測・648 件中 645 件）
    public var programStartOffsetSeconds: Double? {
        guard let start, let programStart, programStart > start else { return nil }
        let offset = programStart.timeIntervalSince(start)
        if let durationSeconds, offset >= Double(durationSeconds) { return nil }
        return offset
    }

    /// 一覧と詳細に出す日時：番組の開始（分からなければ録り始め）。番組表・予約・公式のアプリと同じ時刻になる
    public var displayStart: Date? { programStart ?? start }

    /// 「再生」で始める位置（秒）：番組の開始。番組の開始が分からない・録り始めより前なら録画の頭（0）。
    /// 頭の十数秒は前の番組の終わりで、そこから始めると音が崩れる録画があった（2026-11-20・DR）
    public var playbackStartSeconds: Double { programStartOffsetSeconds ?? 0 }

    /// 再生に使える res（ムーブ専用を除く。ムーブは 1.0 の対象外なので、ムーブ専用の res には GET を送らない）
    public var playableResources: [TitleResource] {
        resources.filter { !$0.isMoveOnly }
    }

    /// 元画質の在りか（ムーブ専用を除いて、モバイルでない最初の res。全部モバイルなら先頭。plan.md §33）
    public var originalResource: TitleResource? {
        playableResources.first { $0.quality != TitleResource.mobileQuality } ?? playableResources.first
    }

    /// モバイルの在りか（ムーブ専用を除く）。無ければ画質を選ばせない
    public var mobileResource: TitleResource? {
        playableResources.first { $0.quality == TitleResource.mobileQuality }
    }

    /// 元画質とモバイルを選ばせるか。モバイルの版が無ければ選ばせない。
    /// 再生できる res がモバイルだけのとき（元画質の在りかもモバイルになる）も、同じものを 2 つ並べないので選ばせない
    public var offersQualityChoice: Bool {
        guard let originalResource, let mobileResource else { return false }
        return originalResource != mobileResource
    }
}

// MARK: - サービス

/// 予約と録画一覧を読む（UPnP SOAP。認証なし）。頼み方は機器の表（`NasneProfile`）から引く
public struct RecordingCatalogService: Sendable {
    /// 予約の一覧で一度に頼む件数
    public static let scheduleRequestCount = 50
    /// 一覧の頁送りの回数の上限（応答が壊れていて終わらないときの歯止め。1 頁 50 件でも 5 万件ぶん）
    static let maxListPages = 1000

    /// 頼み方の表
    public let profile: NasneProfile
    private let soap: SOAPTransport
    private let device: NasneDevice

    /// `profile` を省くと、機器の記述に合う表を使う
    public init(soap: SOAPTransport, device: NasneDevice, profile: NasneProfile? = nil) {
        self.soap = soap
        self.device = device
        self.profile = profile ?? NasneProfiles.profile(for: device)
    }

    private var actions: SOAPTable { profile.soap }
    private var names: SOAPArgumentNames { profile.soap.arguments }

    /// アクションを呼ぶ（control URL は機器の記述から解く）
    private func call(_ action: SOAPAction, _ arguments: [(String, String)]) async throws -> SOAPResponse {
        try await soap.call(controlURL: device.controlURL(for: action.service), serviceType: action.service.serviceType,
                            action: action.name, arguments: arguments)
    }

    private func listArguments(startingIndex: Int, requestedCount: Int) -> [(String, String)] {
        [(names.searchCriteria, ""), (names.filter, names.allProperties), (names.startingIndex, String(startingIndex)),
         (names.requestedCount, String(requestedCount)), (names.sortCriteria, "")]
    }

    /// 予約の一覧。50 件ずつ頁を送る（予約は 100 件まで入る。torne mobile HB は 50 件を 1 回だけ頼む）
    public func schedules() async throws -> [RecordSchedule] {
        let source = "soap:\(actions.getRecordScheduleList.name)"
        return try await scheduleItems().map { try RecordSchedule(item: $0, source: source) }
    }

    /// 作る前に、重なる予約を読む（何も書かない）
    public func conflicts(for schedule: NewRecordSchedule) async throws -> [RecordSchedule] {
        let action = actions.getConflictList
        let source = "soap:\(action.name)"
        let response = try await call(action, [(names.elements, profile.xsrs.document(for: schedule))])
        guard let result = response.result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return try XSRSItem.parseDocument(result, source: source).map { try RecordSchedule(item: $0, source: source) }
    }

    /// 予約を作る。自動で再試行しない（届かなくても、作られていることがある）
    public func create(_ schedule: NewRecordSchedule) async throws -> String {
        let action = actions.createRecordSchedule
        let response = try await call(action, [(names.elements, profile.xsrs.document(for: schedule))])
        guard let raw = response.values[names.recordScheduleID], !raw.isEmpty else {
            throw NasneError.parse("soap:\(action.name)", "\(names.recordScheduleID) が無い")
        }
        return NewRecordSchedule.normalizedID(raw)
    }

    /// 疎な更新を送る。変える項目が無ければ送らない。自動で再試行しない
    public func update(_ update: ScheduleUpdate) async throws {
        let action = actions.updateRecordSchedule
        guard update.hasChange else { throw NasneError.validation("soap:\(action.name)", "変える項目が無い") }
        _ = try await call(action, [(names.elements, profile.xsrs.document(for: update))])
    }

    /// 予約を消す。自動で再試行しない
    public func delete(id: String) async throws {
        _ = try await call(actions.deleteRecordSchedule, [(names.recordScheduleID, id)])
    }

    /// 予約の一覧の item（読んだまま。計測コマンドが項目の形を数える）
    public func scheduleItems() async throws -> [XSRSItem] {
        try await pagedList(
            actions.getRecordScheduleList,
            arguments: { listArguments(startingIndex: $0, requestedCount: Self.scheduleRequestCount) },
            parse: { try XSRSItem.parseDocument($0, source: $1) })
    }

    /// 頁を送りながら一覧を集める。`StartingIndex` を `NumberReturned` ずつ進め、`TotalMatches` に届くまで頼む。
    ///
    /// nasne は `RequestedCount` 0（あるだけ）でも 1 回に返す件数に上限がある（実測：`X_GetTitleList` は 200、
    /// `Browse` は 50）。`TotalMatches` の無い応答は 1 頁で終える
    private func pagedList<Item>(_ action: SOAPAction,
                                 arguments: (Int) -> [(String, String)],
                                 parse: (String, String) throws -> [Item]) async throws -> [Item] {
        let source = "soap:\(action.name)"
        var items: [Item] = []
        var startingIndex = 0
        for _ in 0..<Self.maxListPages {
            let response = try await call(action, arguments(startingIndex))
            guard let result = response.result else { throw NasneError.parse(source, "Result が無い") }
            let page = try parse(result, source)
            items += page
            let returned = response.numberReturned ?? page.count
            startingIndex += returned
            guard returned > 0, let total = response.totalMatches, startingIndex < total else { break }
        }
        return items
    }

    /// 録画の一覧。`withMetadata` なら DIDL を取り、タイトル ID で結合する
    public func titles(withMetadata: Bool = true) async throws -> [RecordedTitle] {
        // 件数を指定して頼む（0 だと既定の頁の 200 件ずつになる。足りなければ頁を送る）
        let items = try await pagedList(
            actions.getTitleList,
            arguments: { listArguments(startingIndex: $0, requestedCount: names.titleListRequestCount) },
            parse: { try XSRSItem.parseDocument($0, source: $1) })
        let source = "soap:\(actions.getTitleList.name)"
        var titles = try items.map { try RecordedTitle(item: $0, source: source) }
        guard withMetadata, !titles.isEmpty else { return titles }
        var byID: [String: DIDLItem] = [:]
        for item in try await browse(profile.dlna.allRecordingsContainer) {
            if let titleID = item.titleID { byID[titleID] = item }
        }
        for index in titles.indices {
            if let didl = byID[titles[index].id] { titles[index].merge(didl) }
        }
        return titles
    }

    /// 録画を消す（`X_DeleteTitle`。入る引数は `TitleID` だけで、出る値は無い）。自動で再試行しない。
    /// 2026-11-21 に Buffalo 製で、一覧の ID のまま送ると消え、3 つの件数がすぐ 1 減ることを確かめた
    /// 保護した録画なら nasne は Fault 877 で断るので、その誤りは保護の文言の鍵に直す
    public func deleteTitle(id: String) async throws {
        do {
            _ = try await call(actions.deleteTitle, [(names.titleID, id)])
        } catch let error as NasneError where error.category == .soapFault && error.code == NasneError.titleProtectedFault {
            throw NasneError.titleProtected(from: error)
        }
    }

    /// ContentDirectory の Browse（直下の子の item。1 回に 50 件までなので頁を送る）
    public func browse(_ objectID: String) async throws -> [DIDLItem] {
        try await browseEntries(objectID).compactMap {
            if case .item(let item) = $0 { return item }
            return nil
        }
    }

    /// ContentDirectory の Browse（直下の子の container と item を文書の順に）
    public func browseEntries(_ objectID: String) async throws -> [DIDLEntry] {
        try await pagedList(
            actions.browse,
            arguments: { [(names.objectID, objectID), (names.browseFlag, names.browseDirectChildren),
                          (names.filter, names.allProperties), (names.startingIndex, String($0)),
                          (names.requestedCount, String(names.requestAll)), (names.sortCriteria, "")] },
            parse: { try DIDLEntry.parseDocument($0, source: $1) })
    }
}
