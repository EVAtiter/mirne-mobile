// torne mobile HB（MIT、© mar1mo-41414）の lib/core/models/device.dart・channel.dart・live_status.dart と
// services/device_info.dart を Swift へ移植したもの。

import Foundation

/// 本体の情報（`status/*Get` の読み取りをまとめたもの）
public struct DeviceInfo: Sendable, Equatable {
    public var name: String
    /// 生の版（例：`0260`）。表示は `displaySoftwareVersion`
    public var softwareVersion: String
    /// 生の時刻の文字列（ISO 形式）
    public var currentDate: String?
    public var areaIdentifierCode: Int?
    public var pref: Int?
    public var finishedSetup: Bool
    public var updateExists: Bool

    /// 公式の表示（「2.60」）に直した版。4 桁の数でなければ生のまま（plan.md §18.2）
    public var displaySoftwareVersion: String {
        guard softwareVersion.count == 4, let number = Int(softwareVersion) else { return softwareVersion }
        return String(format: "%d.%02d", number / 100, number % 100)
    }
}

/// `status/HDDListGet` の 1 台
public struct HDDEntry: Sendable, Equatable {
    public var id: Int
    public var isInternal: Bool
    public var isMounted: Bool
    public var isRegistered: Bool

    public init(id: Int, isInternal: Bool, isMounted: Bool, isRegistered: Bool) {
        self.id = id
        self.isInternal = isInternal
        self.isMounted = isMounted
        self.isRegistered = isRegistered
    }

    /// 使える状態か（マウントされていて登録されている）。そうでない HDD は `HDDInfoGet` が失敗するので、詳細を頼まない
    /// （torne mobile HB `c5b5881` の SIE 製の実測。公式の画面も「未接続」と出す）
    public var isConnected: Bool { isMounted && isRegistered }
}

/// HDD の番号の決まり
public enum HDDIdentity {
    /// 内蔵の HDD の番号（`status/HDDListGet` の `id`。ほかの番号は外付け）
    public static let internalID = 0
}

/// `status/HDDInfoGet`（大きさはバイト）。serialNumber は機器を特定できるので持たない
public struct HDDInfo: Sendable, Equatable {
    public var id: Int
    public var isInternal: Bool
    public var format: String
    public var name: String
    public var usedBytes: Int64
    public var freeBytes: Int64
    public var totalBytes: Int64
}

/// `status/channelListGet` の 1 局
public struct Channel: Sendable, Equatable, Hashable {
    /// WebAPI の数の broadcastingType（地上 = 2）
    public var broadcastingType: Int
    public var networkID: Int
    public var transportStreamID: Int
    public var serviceID: Int
    public var serviceType: Int
    public var channelNumber: Int
    public var serviceName: String
    public var remoteControlKeyID: Int?

    /// TV サービスの serviceType（ARIB）
    public static let televisionServiceType = 1

    /// リモコンキー（1〜12）。nasne はサブチャンネルなどキーの無い局を 0 で返すので、0 は nil にする
    public var remoteControlKey: Int? {
        guard let remoteControlKeyID, remoteControlKeyID > 0 else { return nil }
        return remoteControlKeyID
    }

    /// xsrs の書き方（`0x%04x`）
    public var serviceIDHex: String { String(format: "0x%04x", serviceID) }

    /// `source` は誤りの出どころ（読んだエンドポイント）
    init(json: JSONObject, broadcastingType: Int, source: String) throws {
        self.broadcastingType = broadcastingType
        networkID = try json.requiredInt("networkId", source: source)
        transportStreamID = try json.requiredInt("transportStreamId", source: source)
        serviceID = try json.requiredInt("serviceId", source: source)
        serviceType = try json.requiredInt("serviceType", source: source)
        channelNumber = try json.requiredInt("channelNumber", source: source)
        serviceName = BroadcastText.normalize(json.string("serviceName") ?? "")
        remoteControlKeyID = json.int("remoteControlKeyId")
    }

    public init(broadcastingType: Int, networkID: Int, transportStreamID: Int, serviceID: Int, serviceType: Int,
                channelNumber: Int, serviceName: String, remoteControlKeyID: Int? = nil) {
        self.broadcastingType = broadcastingType
        self.networkID = networkID
        self.transportStreamID = transportStreamID
        self.serviceID = serviceID
        self.serviceType = serviceType
        self.channelNumber = channelNumber
        self.serviceName = serviceName
        self.remoteControlKeyID = remoteControlKeyID
    }

    /// サブチャンネルの serviceID の集合（plan.md §25.3）。
    /// 同じ (networkID, transportStreamID) の中で、TV サービスのうち最小の serviceID を本チャンネル、
    /// 残りの TV サービスをサブとする。`branchNumber` は全件 0、局名の末尾の数字は本とサブで同名の局があるので使えない。
    /// TV サービスでないもの（臨時・データなど）はどちらにも入れない
    public static func subchannelServiceIDs(_ channels: [Channel]) -> Set<Int> {
        var groups: [[Int]: [Int]] = [:]
        for channel in channels where channel.serviceType == televisionServiceType {
            groups[[channel.networkID, channel.transportStreamID], default: []].append(channel.serviceID)
        }
        var result = Set<Int>()
        for serviceIDs in groups.values {
            let main = serviceIDs.min()
            for id in serviceIDs where id != main { result.insert(id) }
        }
        return result
    }
}

/// 集約ステータス（`status/liveStreamStatusListGet`）の 1 項目。generation と生の中身を持つ
public struct LiveSection: Sendable {
    public var generation: Int?
    public var raw: JSONObject
}

/// 集約ステータス。中身の形が実測で固まっていない項目（EIT_PF など）は生のまま持つ
public struct LiveStatus: Sendable {
    public var sections: [String: LiveSection]

    init(json: JSONObject) {
        var sections: [String: LiveSection] = [:]
        for key in json.values.keys where key != "errorcode" {
            if let object = json.object(key) {
                sections[key] = LiveSection(generation: object.int("generation"), raw: object)
            }
        }
        self.sections = sections
    }

    /// 予約の一覧の世代（`tvTimerList.generation`）。予約を作る・変える・消すたびに 1 つ進む（2026-11-24・Buffalo 製で、作って消すと 2 つ進み、
    /// 録画の一覧・予約の失敗の一覧の世代は変わらなかった）。公式の torne® mobile は予約の画面でこの頼みを 2 秒ごとに読んでいる。無ければ nil
    public var scheduleListGeneration: Int? { sections["tvTimerList"]?.generation }

    /// 録画の一覧の世代（`recContentsList.generation`）。録画の保護を切り替えると進む（2026-11-24・Buffalo 製で、切り替えて戻すと
    /// 186 → 191。1 回の変化で 1 つとは限らない）。共有フォルダーのファイルを足す・消すでは変わらなかった。無ければ nil
    public var recordingListGeneration: Int? { sections["recContentsList"]?.generation }

    /// 予約の失敗の一覧の世代（`recNgList.generation`）。無ければ nil
    public var recNgListGeneration: Int? { sections["recNgList"]?.generation }
    /// 外付け HDD の状態の世代（`externalHDDStatus.generation`。つないだ・外したで進むと見ている〔測っていない〕）。無ければ nil
    public var externalHDDGeneration: Int? { sections["externalHDDStatus"]?.generation }
    /// CA のお知らせの世代（`CAMsg.generation`）。無ければ nil
    public var caMessageGeneration: Int? { sections["CAMsg"]?.generation }
    /// EMM のお知らせの世代（`EMMMsg.generation`）。無ければ nil
    public var emmMessageGeneration: Int? { sections["EMMMsg"]?.generation }

    /// チューナーが選局中か（`tuningStatus.status`）。値の意味は未確定なので、0 以外を選局中と読む（推測）
    public var tuningStatus: Int? { sections["tuningStatus"]?.raw.int("status") }

    /// CA のお知らせ（`CAMsg`。中身が無いときは generation だけなので空）
    public var caMessages: [String] { messages(of: "CAMsg") }
    /// EMM のお知らせ（`EMMMsg`）
    public var emmMessages: [String] { messages(of: "EMMMsg") }

    /// 項目の中の文字列を全部集める（generation を除く。中身の形が実測で固まっていないので、
    /// 入れ子の配列・オブジェクトもたどる。torne mobile HB の `_messagesOf` と同じ）
    func messages(of name: String) -> [String] {
        guard let raw = sections[name]?.raw else { return [] }
        var out: [String] = []
        func collect(_ value: Any) {
            switch value {
            case let text as String: if !text.isEmpty { out.append(BroadcastText.normalize(text)) }
            case let array as [Any]: array.forEach(collect)
            case let object as [String: Any]: object.keys.sorted().forEach { collect(object[$0]!) }
            default: break
            }
        }
        for key in raw.values.keys.sorted() where key != "generation" { collect(raw.values[key]!) }
        return out
    }
}

/// 録画の失敗（`status/recNgListGet`）の 1 件
public struct RecNgItem: Sendable, Equatable {
    public var id: String
    public var title: String
    public var start: Date?
    public var durationSeconds: Int?
    public var serviceID: Int?
}

/// 本体の情報を読む（WebAPI の GET。認証なし）
public struct WebAPIDeviceInfoService: Sendable {
    private let transport: WebAPITransport

    public init(transport: WebAPITransport) {
        self.transport = transport
    }

    /// エンドポイントの表（転送層の機器の表）
    private var endpoints: WebAPIEndpointTable { transport.endpoints }

    public func deviceInfo() async throws -> DeviceInfo {
        let name = try await transport.getJSON(endpoints.boxNameGet)
        let version = try await transport.getJSON(endpoints.softwareVersionGet)
        let date = try await transport.getJSON(endpoints.currDateGet)
        let area = try await transport.getJSON(endpoints.areaInfoGet)
        let setup = try await transport.getJSON(endpoints.isFinishSetup)
        let update = try await transport.getJSON(endpoints.updateCheck)
        return DeviceInfo(name: name.string("name") ?? "", softwareVersion: version.string("softwareVersion") ?? "",
                          currentDate: date.string("currDate"), areaIdentifierCode: area.int("areaIdentifierCode"),
                          pref: area.int("pref"), finishedSetup: setup.flag("finishSetUpFlag"),
                          updateExists: update.flag("existFlag"))
    }

    /// 内蔵の HDD か。**`id` で見分ける（0 が内蔵・ほかは外付け）**。`internalFlag` は名前と逆（内蔵が 0・外付けが 1）なので使わない
    /// （torne mobile HB §89.8 の SIE 製の実測〔内蔵 id 0 が 0・外付け id 1 が 1〕と、こちらの Buffalo 製〔内蔵だけで 0。2026-11-21 に
    /// 「情報」の画面が「外付け HDD」と出て分かった〕。作者も 2026-11-22 に `id` で見分ける形に改めた〔`c5b5881`〕）
    static func isInternalDisk(id: Int) -> Bool {
        id == HDDIdentity.internalID
    }

    public func hddList() async throws -> [HDDEntry] {
        let json = try await transport.getJSON(endpoints.hddListGet)
        let source = "webapi:\(endpoints.hddListGet.path)"
        return try json.objects("HDD").map {
            let id = try $0.requiredInt("id", source: source)
            return HDDEntry(id: id, isInternal: Self.isInternalDisk(id: id),
                            isMounted: ($0.int("mountStatus") ?? 0) != 0, isRegistered: $0.flag("registerFlag"))
        }
    }

    public func hddInfo(id: Int) async throws -> HDDInfo {
        let json = try await transport.getJSON(endpoints.hddInfoGet, parameters: [endpoints.parameters.hddID: String(id)])
        let source = "webapi:\(endpoints.hddInfoGet.path)"
        guard let hdd = json.object("HDD") else { throw NasneError.parse(source, "\"HDD\" が無い") }
        func bytes(_ key: String) throws -> Int64 {
            guard let number = hdd.values[key] as? NSNumber else { throw NasneError.parse(source, "\"\(key)\" が無い") }
            return number.int64Value
        }
        let id = try hdd.requiredInt("id", source: source)
        return HDDInfo(id: id, isInternal: Self.isInternalDisk(id: id),
                       format: hdd.string("format") ?? "", name: hdd.string("name") ?? "",
                       usedBytes: try bytes("usedVolumeSize"), freeBytes: try bytes("freeVolumeSize"),
                       totalBytes: try bytes("totalVolumeSize"))
    }

    public func channels(broadcastingType: Int = BroadcastingType.terrestrial) async throws -> [Channel] {
        let endpoint = endpoints.channelListGet
        let json = try await transport.getJSON(endpoint, parameters: [endpoints.parameters.broadcastingType: String(broadcastingType)])
        return try json.objects("channel").map {
            try Channel(json: $0, broadcastingType: broadcastingType, source: "webapi:\(endpoint.path)")
        }
    }

    public func liveStatus() async throws -> LiveStatus {
        LiveStatus(json: try await transport.getJSON(endpoints.liveStreamStatusListGet))
    }

    public func recNgList() async throws -> [RecNgItem] {
        let json = try await transport.getJSON(endpoints.recNgListGet)
        return json.objects("item").map {
            RecNgItem(id: $0.string("id") ?? "", title: BroadcastText.normalize($0.string("title") ?? ""),
                      start: NasneDateTime.parse($0.string("scheduledStartDateTime")),
                      durationSeconds: $0.int("scheduledDuration"), serviceID: $0.int("scheduledChannelID"))
        }
    }

    /// 録画の件数と上限
    public func titleCounts() async throws -> (count: Int, max: Int) {
        let count = try await transport.getJSON(endpoints.recordedContentCountGet)
        let max = try await transport.getJSON(endpoints.recordedContentMaxCountGet)
        let source = "webapi:/recorded"
        return (try count.requiredInt("count", source: source), try max.requiredInt("count", source: source))
    }
}
