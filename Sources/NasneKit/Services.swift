// 領域ごとのプロトコルと、その組み立て。
//
// torne mobile HB（MIT、© mar1mo-41414）の lib/core/services/interfaces.dart の考え方を移したもの。
// 画面は下のプロトコルだけを知り、SOAP か WebAPI か DLNA かを知らない（実測で経路が逆転したことがあるので、
// 差し替えられる形にしておく）。中身の型は経路の名前を付けて分ける（`WebAPIDeviceInfoService` など）。

import Foundation

// MARK: - 領域のプロトコル

// 発見は `DiscoveryService`（Discovery.swift）。SSDP と /24 の走査の 2 つの中身がある

/// 登録（記述 → MAC アドレス → PIN の導出 → PINVerify）
public protocol RegistrationService: Sendable {
    /// 登録を通して、保存する記録を返す。確かめられなければ NasneError を投げる
    func register(_ device: NasneDevice, now: Date) async throws -> RegisteredNasne
    /// 登録し直さずに確かめる（PINVerify だけ）
    func verify(_ registration: RegisteredNasne) async throws -> Bool
}

extension RegistrationService {
    public func register(_ device: NasneDevice) async throws -> RegisteredNasne {
        try await register(device, now: Date())
    }
}

/// 本体の情報（WebAPI の `status/*`）
public protocol DeviceInfoService: Sendable {
    func deviceInfo() async throws -> DeviceInfo
    func hddList() async throws -> [HDDEntry]
    func hddInfo(id: Int) async throws -> HDDInfo
    func channels(broadcastingType: Int) async throws -> [Channel]
    func liveStatus() async throws -> LiveStatus
    func recNgList() async throws -> [RecNgItem]
    /// 録画の件数と上限
    func titleCounts() async throws -> (count: Int, max: Int)
}

/// 予約（読み取り・競合の確認・作成・変更・削除）。書き込みは自動で再試行しない
public protocol ScheduleService: Sendable {
    func schedules() async throws -> [RecordSchedule]
    /// 作る前に、重なる予約を読む（`X_GetConflictList`。何も書かない）。重ならなければ空
    func conflicts(for schedule: NewRecordSchedule) async throws -> [RecordSchedule]
    /// 予約を作り、一覧の形の ID（10 進。応答の `0x` を外したもの）を返す
    func create(_ schedule: NewRecordSchedule) async throws -> String
    /// 疎な更新（priorityFlag と、変える項目を 1 つ以上）。受け付けられても値が変わらないことがあるので、送った後は読み直す
    func update(_ update: ScheduleUpdate) async throws
    /// 予約を消す。ID は一覧の item id
    func delete(id: String) async throws
}

/// 録画の一覧（xsrs を主に、DIDL で補う。画面は結合した形だけを見る）と、録画の削除・保護の切り替え
public protocol TitleCatalogService: Sendable {
    func titles(withMetadata: Bool) async throws -> [RecordedTitle]
    /// 録画を消す。ID は一覧の ID（xsrs の item id）。自動で再試行しない。送るとすぐ一覧から消える（2026-11-21 実機）
    func deleteTitle(id: String) async throws
    /// 録画の保護を切り替える。送る直前に一覧を読み直し、その録画の item を受け取ったまま保護の印だけ変えて送り返す。
    /// 一覧に無ければ送らない。自動で再試行しない
    func setProtection(id: String, protect: Bool) async throws
    /// 録画 1 件の番組の情報（DIDL）。返らなければ nil
    func titleMetadata(id: String) async throws -> DIDLItem?
    /// 録画のチャプターの点（録画の頭からの秒）。確かめを通らない・2 点に満たなければ空
    func chapters(id: String, durationSeconds: Int) async throws -> [Double]
}

extension TitleCatalogService {
    public func titles() async throws -> [RecordedTitle] {
        try await titles(withMetadata: true)
    }
}

/// 番組表（EPGGet）とロゴ
public protocol ProgramGuideService: Sendable {
    /// 版数表（`status/EPGVersionInfoGet` の応答）。前と同じなら EPGGet を送らなくてよい
    func versionTable(broadcastingType: Int) async throws -> Data
    /// 読んだ版数表のサービスで EPGGet を送り、EIT のセクションにする
    func fetch(versionTable: Data) async throws -> EPGFetchResult
    func logos(broadcastingType: Int) async throws -> [Int: Data]
}

extension ProgramGuideService {
    public func versionTable() async throws -> Data {
        try await versionTable(broadcastingType: BroadcastingType.terrestrial)
    }

    /// 版数表を読んでから EPGGet を送る
    public func fetch(broadcastingType: Int = BroadcastingType.terrestrial) async throws -> EPGFetchResult {
        try await fetch(versionTable: versionTable(broadcastingType: broadcastingType))
    }

    public func logos() async throws -> [Int: Data] {
        try await logos(broadcastingType: BroadcastingType.terrestrial)
    }
}

/// ライブの局の一覧（DLNA の LiveTuner の木）
public protocol LiveCatalogService: Sendable {
    func bands() async throws -> [LiveBand]
    /// 1 つの放送の種別の帯域の局（`BroadcastingType`）
    func channels(broadcastingType: Int) async throws -> [LiveChannel]
}

/// 共有フォルダーのメディア（動画・音楽・写真）の一覧（DLNA の Browse。読むだけ）
public protocol MediaLibraryService: Sendable {
    /// 種類の木の根の中身（共有フォルダー）
    func root(kind: MediaKind) async throws -> MediaListing
    /// フォルダー 1 つの中身
    func listing(folderID: String, kind: MediaKind) async throws -> MediaListing
    /// 中身の版（共有フォルダーのファイルを足す・消す、録画が変わると進む。ContentDirectory の SystemUpdateID）
    func updateID() async throws -> Int
}

/// 録画の再開位置の書き戻し（書き込み。自動で再試行しない）
public protocol ResumePositionService: Sendable {
    /// 再開位置を書く（録画の頭からの秒。0 は再開位置を消す）
    func setResumePosition(id: String, seconds: Double) async throws
}

// MARK: - 中身の型の適合

extension WebAPIRegistrationService: RegistrationService {}
extension WebAPIDeviceInfoService: DeviceInfoService {}
extension RecordingCatalogService: ScheduleService, TitleCatalogService {}
extension WebAPIProgramGuideService: ProgramGuideService {}
extension DLNALiveCatalogService: LiveCatalogService {}
extension DLNAMediaLibraryService: MediaLibraryService {}
extension WebAPIResumePositionService: ResumePositionService {}

// MARK: - 組み立て（起動時の 1 か所。試験ではモックに差し替える）

/// 登録の前に使う部品（発見・記述・登録）
public struct DeviceSetupServices: Sendable {
    /// 順に試す発見の方法（SSDP を先に。だめなら /24 の走査）
    public let discovery: [any DiscoveryService]
    /// 手で入れたアドレスから記述を取る
    public let describe: @Sendable (String) async throws -> NasneDevice
    public let registration: any RegistrationService
    /// 記述の UDN が同じ nasne を探し直す（アドレスが変わったとき）。見つからなければ nil。
    /// SSDP で探す（macOS では /24 の走査は利用者が選んだときだけの決まりなので、自動の探し直しでは使わない）。
    /// SSDP を使わない組み立て（iPad）では、/24 を走査して探す
    public let relocate: @Sendable (String) async throws -> NasneDevice?
    /// 今のアドレスに届くかの確かめ（PINVerify）。ふだんの頼みより短い時間切れで、届かないと早く分かるようにする
    public let checkConnection: any RegistrationService

    /// 届くかの確かめの時間切れ（nasne の PINVerify はふだん数十 ms。ふだんの頼みの 15 秒を待つと、起動してから探し始めるまでが長い）
    public static let connectionCheckTimeout: TimeInterval = 5

    public init(discovery: [any DiscoveryService], describe: @escaping @Sendable (String) async throws -> NasneDevice,
                registration: any RegistrationService,
                relocate: @escaping @Sendable (String) async throws -> NasneDevice? = { _ in nil },
                checkConnection: (any RegistrationService)? = nil) {
        self.discovery = discovery
        self.describe = describe
        self.registration = registration
        self.relocate = relocate
        self.checkConnection = checkConnection ?? registration
    }

    /// 実機に向けた組み立て。
    /// `usesSSDP` が false なら SSDP を使わず、/24 の走査だけで探す（iOS はマルチキャストのエンタイトルメントが無いと
    /// SSDP を送れない。そのとき自動で探す方法も、アドレスが変わったときの探し直しも走査になる）
    public static func live(client: any HTTPExchanging,
                            scanClient: any HTTPExchanging = URLSessionHTTPClient(timeout: SubnetScanDiscoveryService.probeTimeout),
                            usesSSDP: Bool = true)
        -> DeviceSetupServices {
        // 登録の前は機種が分からないので、走査・記述・届くかの確かめは標準の表で頼む。登録は記述の機種に合う表で頼む
        let profile = NasneProfiles.standard
        let describer = DeviceDescriber(client: client, profile: profile)
        let ssdp = SSDPDiscoveryService(client: client)
        let scan = SubnetScanDiscoveryService(client: scanClient, describeClient: client, profile: profile)
        return DeviceSetupServices(
            discovery: usesSSDP ? [ssdp, scan] : [scan],
            describe: { try await describer.describe(host: $0) },
            registration: WebAPIRegistrationService(client: client),
            relocate: { udn in
                if usesSSDP { return try await ssdp.discover(udn: udn).first }
                // SSDP を送れない（iPad）ときは /24 を走査して、記述の UDN が同じ nasne を探す
                return try await scan.discover().first { $0.udn == udn }
            },
            checkConnection: WebAPIRegistrationService(client: URLSessionHTTPClient(timeout: connectionCheckTimeout),
                                                       profile: profile))
    }
}

/// 登録した nasne に対する領域サービスの組。画面はこれだけを受け取る
public struct NasneServices: Sendable {
    public let registration: RegisteredNasne
    public let deviceInfo: any DeviceInfoService
    public let schedules: any ScheduleService
    public let titles: any TitleCatalogService
    public let programGuide: any ProgramGuideService
    public let liveCatalog: any LiveCatalogService
    /// 共有フォルダーのメディア
    public let media: any MediaLibraryService
    /// 再開位置の書き戻し（無ければ書き戻さない。試験）
    public let resumePositions: (any ResumePositionService)?
    /// nasne の設定画面（nasne HOME）の URL。ブラウザで開く
    public let nasneHomeURL: URL

    public init(registration: RegisteredNasne, deviceInfo: any DeviceInfoService, schedules: any ScheduleService,
                titles: any TitleCatalogService, programGuide: any ProgramGuideService, liveCatalog: any LiveCatalogService,
                media: any MediaLibraryService, nasneHomeURL: URL, resumePositions: (any ResumePositionService)? = nil) {
        self.registration = registration
        self.deviceInfo = deviceInfo
        self.schedules = schedules
        self.titles = titles
        self.programGuide = programGuide
        self.liveCatalog = liveCatalog
        self.media = media
        self.nasneHomeURL = nasneHomeURL
        self.resumePositions = resumePositions
    }

    /// 実機に向けた組み立て。control URL は記述（`device`）から解く。
    /// 頼み方の表は、記述の機種に合うもの（`NasneProfiles.profile(for:)`）を全部のサービスに渡す
    public static func live(registration: RegisteredNasne, device: NasneDevice,
                            client: any HTTPExchanging) throws -> NasneServices {
        let profile = NasneProfiles.profile(for: device)
        let webAPI = WebAPITransport(host: registration.host, client: client, profile: profile)
        let catalog = RecordingCatalogService(soap: SOAPTransport(client: client), device: device, profile: profile)
        return NasneServices(
            registration: registration,
            deviceInfo: WebAPIDeviceInfoService(transport: webAPI),
            schedules: catalog,
            titles: catalog,
            programGuide: WebAPIProgramGuideService(transport: webAPI, tokens: try registration.tokenProvider()),
            liveCatalog: DLNALiveCatalogService(catalog: catalog),
            media: DLNAMediaLibraryService(catalog: catalog),
            nasneHomeURL: webAPI.pageURL(webAPI.endpoints.nasneHome),
            resumePositions: WebAPIResumePositionService(transport: webAPI))
    }
}
