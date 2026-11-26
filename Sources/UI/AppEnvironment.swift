import Foundation
import Observation
import os

/// アプリの部品の組み立て（起動時の 1 か所）。
///
/// 画面はここから領域サービス（`DeviceSetupServices`・`NasneServices`）を受け取り、中身の型を知らない。
/// 試験やプレビューでは、モックの部品を渡して作る。
@MainActor
@Observable
final class AppEnvironment {
    /// nasne とのやり取りに使う HTTP（Cookie・キャッシュを使わない）
    let client: any HTTPExchanging
    /// 登録の前に使う部品（発見・記述・登録）
    let setup: DeviceSetupServices
    /// 登録の保存先（ファイルと Keychain）
    let store: any RegistrationStore
    /// 登録した nasne の一覧と選んでいる台（設定の「nasne」の節に出す。読んだ・書いたたびに読み直す）
    private(set) var registrations: RegistrationList = .empty
    /// 登録した nasne に対する部品。登録するまでは nil
    private(set) var services: NasneServices?
    /// 集約ステータスの見回り（一覧ごとの世代と、nasne に届くか。services と一緒に作り、一緒に捨てる。回すのは主ウィンドウ）
    private(set) var liveStatus: LiveStatusMonitor?
    /// nasne に届くか（メニューの項目を押せるかに使う。登録する前・確かめている間は偽）
    var isNasneOnline: Bool { liveStatus?.isOnline == true }
    /// 局の一覧（録画・予約・番組表・ライブの画面で共通。services と一緒に作り、一緒に捨てる）
    private(set) var channels: ChannelCatalog?
    /// 番組表の取り直しと番組表（登録した nasne ごと。登録するまで・番組表を開けなかったときは nil）
    private(set) var programGuide: ProgramGuideModel?
    /// 局のロゴ（番組表・録画・予約の画面で共通。登録するまでは nil）
    private(set) var channelLogos: ChannelLogoModel?
    /// 録画一覧のキャッシュ（登録するまで・開けなかったときは nil）
    private(set) var library: LibraryStore?
    /// 視聴の状態の記録（登録するまでは nil。キャッシュを開けなかったときは、記録をこの起動の間だけ持つ）
    private(set) var viewing: ViewingRecorder?
    /// ライブで見る局（登録するまでは nil）
    private(set) var live: LiveModel?
    /// いま視聴ウィンドウで再生しているもの（録画か局か。何も頼んでいなければ nil）
    private(set) var nowPlaying: NowPlaying?
    /// nasne が録画している局（ライブを始めたとき・配信が 511 で断られたときに読む。録画中でなければ nil）
    private(set) var recordingStation: LiveStation?
    /// ライブを始められなかった理由（局が無い・見られない局を選んだ。視聴ウィンドウに出す）
    private(set) var liveStartError: ErrorPresentation?
    /// ライブを始める前に、局の一覧を読んでいる
    private(set) var preparingLive = false
    /// いま再生している録画（画質の切り替えの選択肢を出す。ライブ・何も再生していなければ nil）
    private(set) var currentTitle: RecordedTitle? {
        didSet { if oldValue?.id != currentTitle?.id { chapters = [] } }
    }
    /// 再生している録画のチャプターの点（録画の頭からの秒。読めない・無ければ空で、チャプターのボタンを出さない）
    private(set) var chapters: [Double] = []
    /// 視聴ウィンドウで切り替えたライブの画質（窓を閉じるまで、局を替えても引き継ぐ。無ければ設定の既定。2026-11-20 に決めた）
    private(set) var liveQualityOverride: String?
    /// 再生している間、一定の間隔で位置を記録する
    @ObservationIgnored private var checkpointTask: Task<Void, Never>?
    /// 保存した登録を読めなかったときの誤り（画面に出す）
    private(set) var restoreError: ErrorPresentation?
    /// nasne につながっているか（探している間・見つからないときは主ウインドウの上に帯を出す）
    var connection: NasneConnectionState = .connected
    /// 確かめている最中の仕事（同時には 1 つだけ）
    @ObservationIgnored var connectionCheckTask: Task<Void, Never>?
    /// 前に確かめた時刻（頼みが届かなかったことで確かめるときの間引き）
    @ObservationIgnored var lastConnectionCheck: ContinuousClock.Instant?
    /// ネットワークの切り替えの見張り
    @ObservationIgnored var networkWatcher: NetworkPathWatcher?
    /// 録画の再生（同時には 1 本だけ）
    let playback: PlaybackController
    /// 再生の映像を描く（Metal が使えなければ nil）
    let renderer: VideoRenderer?
    /// 字幕の重ね出し（出すかどうかは起動したときに設定から決め、アプリを開いている間は録画をまたいで引き継ぐ）
    let captions: CaptionOverlayModel
    /// ディスプレイのスリープの抑止（どの再生が抑えているかを数えて持つ）
    let displaySleep: DisplaySleepGuard
    /// OS ごとの部品（macOS：視聴ウィンドウの窓・主ウインドウの位置・スリープの見張り／iOS：裏へ回ったときの見張り）
    let platform: PlatformEnvironment
    /// 主ウインドウの上の帯の知らせ（操作の結果と、閉じた知らせ）
    let notices = MainNoticeCenter()
    /// メニューと主ウインドウの仲立ち（主ウインドウへの頼みと、項目の有効・無効を決めるためのモデル）
    let mainCommands = MainCommandCenter()
    #if DEBUG
    /// 再生の非機能要件の計測（ログに時間と数値だけを出す。開発用のビルドだけ）
    @ObservationIgnored private var playbackMeasurement: PlaybackMeasurement?
    #endif

    init(client: any HTTPExchanging, setup: DeviceSetupServices, store: any RegistrationStore, playback: PlaybackController,
         displaySleep: DisplaySleepGuard) {
        self.client = client
        self.setup = setup
        self.store = store
        self.playback = playback
        self.displaySleep = displaySleep
        let engine = playback.engine
        let renderer = VideoRenderer(frames: engine.frames)
        renderer?.clock = { engine.presentationTime() }
        renderer?.mediaTimeAtHost = { engine.mediaTime(atHost: $0) }
        renderer?.clockEpoch = { engine.clockEpoch }
        // 一時停止の間は、止めた絵を出しきったら描くのを止め、時計が変わったら描き直す（CPU を使い続けない）
        renderer?.isClockPaused = { engine.isPaused }
        if let wake = renderer?.wakeFromPause { engine.onClockChange(wake) }
        self.renderer = renderer
        captions = CaptionOverlayModel(engine: engine, renderer: renderer,
                                       isEnabled: UserDefaults.standard.bool(forKey: ViewerSettingsKey.captionsByDefault))
        platform = PlatformEnvironment(playback: playback, renderer: renderer)
        #if DEBUG
        playbackMeasurement = PlaybackMeasurement(playback: playback, renderer: renderer)
        #endif
        playback.onCheckpoint = { [weak self] checkpoint in self?.viewing?.record(checkpoint) }
        checkpointTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: ViewingPolicy.checkpointInterval)
                guard let self else { return }
                if self.playback.state == .playing { self.playback.recordCheckpoint() }
            }
        }
        restore()
        startWatchingNetwork()
    }

    /// 実機に向けた組み立て。ディスプレイのスリープを止める印の出し方は OS ごと（`live()` は OS ごとのファイルにある）
    /// `usesSSDP` は nasne を SSDP で探すか（iOS は SSDP を送れないので /24 の走査だけ）
    static func live(displaySleepAssertion: any DisplaySleepAssertion, usesSSDP: Bool) -> AppEnvironment {
        // 使っている途中で頼みが届かなくなったら探し直す。知らせの受け手は環境を作ってから付ける
        let client = ReachabilityReportingHTTPClient(base: URLSessionHTTPClient())
        let environment = AppEnvironment(client: client, setup: .live(client: client, usesSSDP: usesSSDP),
                                         store: FileRegistrationStore.standard(),
                                         playback: .live(client: client),
                                         displaySleep: DisplaySleepGuard(assertion: displaySleepAssertion))
        client.onUnreachable { [weak environment] in
            Task { @MainActor in environment?.checkConnection(.requestFailed) }
        }
        return environment
    }

    /// 保存した登録があれば、選んでいる台に向けて部品を作る
    private func restore() {
        do {
            registrations = try store.load()
            if let selected = registrations.selected {
                try connect(registration: selected.registration, device: selected.device)
                // 保存したアドレスに届くかを確かめ、届かなければ探し直す
                checkConnection(.launch)
            }
        } catch {
            restoreError = ErrorText.present(error)
        }
    }

    /// 保存した登録の一覧を読み直す（読めなければ前の一覧のまま）
    func reloadRegistrations() {
        do {
            registrations = try store.load()
        } catch {
            restoreError = ErrorText.present(error)
        }
    }

    /// いま部品を作っている台の鍵（登録が無ければ nil）
    var currentNasneKey: String? { services?.registration.storageKey }

    /// いま見ている台の呼び名（予約のシートの「予約先」の行・設定の確かめに出す。登録が無ければ nil）
    var currentNasneName: String? {
        guard let key = currentNasneKey else { return nil }
        return NasneDisplayName.names(for: registrations.entries)[key] ?? services?.registration.friendlyName
    }

    /// このアプリの中だけの呼び名を付ける（設定の「名前を変える…」。空なら本体名に戻す）
    func renameNasne(key: String, to name: String) throws {
        try store.rename(key: key, customName: name)
        registrations = try store.load()
    }

    /// 本体名を読み直し、変わっていれば保存し直す（nasne HOME で変えた名前をアプリにも出す。つながったと確かめたとき）。
    /// 読めなくても何もしない（名前は前のまま）。ログに名前は出さない
    func refreshBoxName() async {
        guard let services else { return }
        let key = services.registration.storageKey
        let logger = Logger(subsystem: AppLog.subsystem, category: "discovery")
        do {
            let name = try await services.deviceInfo.boxName()
            guard currentNasneKey == key, try store.updateBoxName(key: key, name: name) else { return }
            registrations = try store.load()
            logger.info("本体名が変わっていたので、保存し直した")
        } catch {
            logger.info("本体名を読み直せない（\(NasneDiagnostics.summary(error), privacy: .public)）")
        }
    }

    /// 登録した nasne に向けて部品を作る（control URL は記述から解く）
    func connect(registration: RegisteredNasne, device: NasneDevice) throws {
        let services = try NasneServices.live(registration: registration, device: device, client: client)
        let key = registration.storageKey
        // 主ウィンドウは services が立った時点で作られ、そのときの library を録画のモデルに渡すので、先に開く
        library = Self.makeLibrary()
        let viewing = ViewingRecorder(udn: registration.udn, library: library, resumePositions: services.resumePositions)
        self.viewing = viewing
        Task { await viewing.load() }
        // 届くかを確かめるまで、各部品は nasne から読まない（確かめてつながったら主ウィンドウがまとめて読む）
        let liveStatus = LiveStatusMonitor(deviceInfo: services.deviceInfo)
        self.liveStatus = liveStatus
        let channels = ChannelCatalog(deviceInfo: services.deviceInfo, link: liveStatus)
        self.channels = channels
        self.services = services
        restoreError = nil
        programGuide = Self.makeProgramGuide(services: services, link: liveStatus, nasneKey: key)
        LiveSettingsKey.moveLegacyLastStation(to: key)
        live = LiveModel(channels: channels, catalog: services.liveCatalog, programGuide: programGuide?.store, nasneKey: key)
        // 局のロゴ：保存したものをすぐ出す。nasne からの読み直しと番組表の取り直しは、届くと分かったときに主ウィンドウが頼む
        // （起動したとき・登録したとき・つながり直したとき。版数表が前と同じなら EPGGet は送らない）
        let logos = ChannelLogoModel(source: services.programGuide, store: programGuide?.store, link: liveStatus)
        logos.loadSaved()
        channelLogos = logos
    }

    /// 台の番組表を開いて、取り直しのモデルを作る。開けなければ nil（番組表のほかは使えるようにする）。
    /// 1.6 までの番組表（1 つのファイル）があれば、先に台のフォルダーへ移す
    private static func makeProgramGuide(services: NasneServices, link: LiveStatusMonitor, nasneKey: String) -> ProgramGuideModel? {
        do {
            let url = try ProgramGuideFiles.storeURL(for: nasneKey)
            ProgramGuideFiles.moveLegacy(from: try ProgramGuideFiles.legacyStoreURL(), to: url)
            return ProgramGuideModel(service: services.programGuide, store: try EPGStore(fileURL: url),
                                     versions: FileProgramGuideVersionStore(fileURL: ProgramGuideFiles.versionURL(storeURL: url)),
                                     link: link)
        } catch {
            Logger(subsystem: AppLog.subsystem, category: "epg")
                .error("番組表を開けない: \(NasneDiagnostics.summary(error), privacy: .public)")
            return nil
        }
    }

    /// 録画一覧のキャッシュを開く。開けなければ nil（キャッシュなしで nasne から取る）
    private static func makeLibrary() -> LibraryStore? {
        do {
            return try LibraryStore(fileURL: LibraryStore.defaultFileURL())
        } catch {
            Logger(subsystem: AppLog.subsystem, category: "library")
                .error("録画一覧のキャッシュを開けない: \(LibraryStore.summary(error), privacy: .public)")
            return nil
        }
    }

    // MARK: - 台の切り替え・追加・登録を外す

    /// 部品を作り直す（台のアドレスが変わった・台を切り替えた・台を足した。作り直しの道はこれ 1 つ）。
    /// 再生は止める。主ウインドウは RootView の id（台の UDN とアドレス）が変わって開き直す
    func rebuildConnection(registration: RegisteredNasne, device: NasneDevice) async throws {
        await tearDownConnection()
        try connect(registration: registration, device: device)
    }

    /// 今の台の部品を閉じる（再生を止め、視聴の記録と番組表の書き込みを済ませ、録画一覧のキャッシュを閉じる）
    private func tearDownConnection() async {
        endViewing()
        // ライブの局の一覧・番組表・録画一覧のキャッシュ・視聴の記録は connect が作り直す
        await viewing?.flush()
        // 届かずに頼み直している番組表の取り直しは待たずに取り消す
        await programGuide?.cancelAndFinish()
        await library?.close()
    }

    /// 見る nasne を切り替える（設定の「nasne」の節。再生は止める。2026-11-25 に決めた）
    func selectNasne(key: String) async {
        guard key != currentNasneKey else { return }
        do {
            try store.select(key: key)
            registrations = try store.load()
            guard let selected = registrations.selected, selected.key == key else { return }
            try await rebuildConnection(registration: selected.registration, device: selected.device)
            connection = .connected
            checkConnection(.launch)
        } catch {
            restoreError = ErrorText.present(error)
        }
    }

    /// 登録を足した（登録の画面から）。足した台へ切り替える（2026-11-25 に決めた）
    private func addedNasne(_ registration: RegisteredNasne, device: NasneDevice) async {
        do {
            try store.select(key: registration.storageKey)
            registrations = try store.load()
            if services == nil {
                try connect(registration: registration, device: device)
            } else {
                try await rebuildConnection(registration: registration, device: device)
            }
            connection = .connected
        } catch {
            restoreError = ErrorText.present(error)
        }
    }

    /// 1 台の登録を外す（保存した登録と Keychain の MAC アドレス、その台の番組表・録画一覧・視聴の記録・前に見た局も消す）。
    /// 見ている台を外したら、残っている台へ切り替える（無ければ登録の画面）。
    /// 番組表と録画一覧・視聴の記録は、書き込みが終わって閉じてから消す（開いたまま消すと、書きかけの記録のファイルが残りうる）
    func unregister(key: String) async throws {
        guard let entry = registrations.entries.first(where: { $0.key == key }) else { return }
        let isCurrent = key == currentNasneKey
        if isCurrent {
            liveQualityOverride = nil
            await tearDownConnection()
            live = nil
            channelLogos = nil
            viewing = nil
            programGuide = nil
            services = nil
            liveStatus = nil
            channels = nil
        }
        try store.delete(key: key)
        UserDefaults.standard.removeObject(forKey: LiveSettingsKey.lastStation(nasne: key))
        try ProgramGuideFiles.delete(storeURL: try ProgramGuideFiles.storeURL(for: key))
        registrations = try store.load()
        if let next = registrations.selected {
            if isCurrent {
                try connect(registration: next.registration, device: next.device)
                checkConnection(.launch)
            }
            // 録画一覧のキャッシュは台をまたいで 1 つのファイル。外した台の行だけ消す
            try await library?.delete(udn: entry.registration.udn)
        } else {
            library = nil
            try LibraryStore.delete(fileURL: try LibraryStore.defaultFileURL())
        }
    }

    /// 録画を再生する。前の録画の位置を記録してから、これから見る録画を視聴の記録に知らせて始める
    func play(_ title: RecordedTitle, resource: TitleResource, from seconds: Double) {
        playback.recordCheckpoint(.left)
        viewing?.begin(title)
        liveStartError = nil
        nowPlaying = .recording(titleID: title.id)
        currentTitle = title
        // 録画中の録画は、再生している間に長さを伸ばす（録り始めた時刻から。番組の終わりで止める。2026-11-20）
        let growth = title.isRecording ? title.start.map { RecordingGrowth(recordingStart: $0, limit: title.programEnd) } : nil
        playback.play(resource, durationSeconds: title.durationSeconds.map(Double.init), from: seconds, growth: growth)
        loadChapters(title)
    }

    /// 録画のチャプターを読む（再生を始めたときに 1 回。録画中の録画は読まない〔伸びている途中で、測っていない〕）。
    /// 失敗しても再生は止めず、チャプターなしにする
    private func loadChapters(_ title: RecordedTitle) {
        guard !title.isRecording, let duration = title.durationSeconds, let catalog = services?.titles else { return }
        Task { [weak self] in
            let points = (try? await catalog.chapters(id: title.id, durationSeconds: duration)) ?? []
            guard let self, self.currentTitle?.id == title.id else { return }
            self.chapters = points
        }
    }

    /// 前後のチャプターへ飛ぶ（操作部のボタンと Shift + ←→）。チャプターが無い・飛べない・その向きに点が無ければ何もしない
    func seekChapter(forward: Bool) {
        guard playback.kind == .recording, playback.canSeek, let position = playback.displaySeconds else { return }
        let target = forward ? ChapterNavigation.next(chapters, from: position) : ChapterNavigation.previous(chapters, from: position)
        if let target { playback.seek(to: target) }
    }

    /// 一覧の下の欄のボタン：視聴ウィンドウで再生している録画なら、別の画質は切り替え・同じ画質は何もしない
    /// （呼び出し側が窓を前に出す）。ほかの録画と「最初から」は新しく再生する
    func playFromList(_ title: RecordedTitle, _ action: RecordingPlayAction) {
        if !action.startsOver, nowPlaying == .recording(titleID: title.id), Self.isActive(playback.state) {
            if action.resource != playback.currentResource { switchQuality(to: action.resource) }
            return
        }
        play(title, resource: action.resource, from: action.from)
    }

    // MARK: - 画質の切り替え

    /// いま切り替えられる画質（録画は元画質とモバイル、ライブは DR・3倍・モバイル。何も再生していなければ空）
    var qualityChoices: [TitleResource] {
        switch nowPlaying {
        case .recording: currentTitle.map(PlaybackQuality.choices(of:)) ?? []
        case .live(let key): live?.station(key)?.qualityChoices ?? []
        case .media, nil: []
        }
    }

    /// 画質を替える（ライブなら、窓を閉じるまで局を替えてもその画質で見る）
    func switchQuality(to resource: TitleResource) {
        playback.switchQuality(resource)
        if playback.kind == .live { liveQualityOverride = resource.quality }
    }

    /// Q キー：次の画質へ
    func cycleQuality() {
        guard let next = PlaybackQuality.next(after: playback.currentResource, in: qualityChoices) else { return }
        switchQuality(to: next)
    }

    /// ライブを始めるときの画質（設定。未設定なら DR）
    static var defaultLiveQuality: LiveQuality {
        LiveQuality.saved(UserDefaults.standard.string(forKey: LiveSettingsKey.defaultQuality))
    }

    /// 再生が続いているか（始めている・再生している・止めている・待っている）
    private static func isActive(_ state: PlaybackState) -> Bool {
        switch state {
        case .starting, .playing, .paused, .waiting: true
        case .idle, .ended, .failed: false
        }
    }

    // MARK: - ライブ

    /// ツールバーの「ライブ」：nasne が録画中なら録画している局、そうでなければ前に見た局（初めて・見られなければ最初の局）を映す。
    /// 局の一覧は押すたびに読み直す（放送中の番組名を新しくする）。録画中かは録画一覧で見る（局の一覧と同時に読む）
    func startLive() async {
        guard let live else { return }
        liveStartError = nil
        preparingLive = true
        async let titles = try? services?.titles.titles(withMetadata: false)
        await live.load(reload: true)
        let recording = LiveLineup.recordingStation(await titles ?? [], in: live.stations(showsSubchannels: true))
        recordingStation = recording
        preparingLive = false
        let station = recording ?? LiveLineup.initialStation(last: live.lastStation, visible: live.stations(showsSubchannels: Self.showsSubchannels),
                                                             all: live.stations(showsSubchannels: true))
        guard let station else {
            presentLiveStartError(live)
            return
        }
        playLive(station)
    }

    /// 番組表の局をライブで見る（番組表の「視聴」と局名の欄のボタン）
    func startLive(channel: Channel) async {
        guard let live else { return }
        liveStartError = nil
        preparingLive = true
        await live.load()
        preparingLive = false
        guard let station = live.station(LiveStationKey(channel)) else {
            presentLiveStartError(live, reason: LiveText.notInLiveList)
            return
        }
        playLive(station)
    }

    /// 局を替える：前の録画の位置を記録してから、その局を受信する。見られない局なら理由を出す
    func playLive(_ station: LiveStation) {
        guard let live else { return }
        guard station.resource != nil,
              let resource = station.resource(preferring: liveQualityOverride ?? Self.defaultLiveQuality.rawValue) else {
            liveStartError = ErrorPresentation(title: "この局はライブで見られません", message: station.unavailableReason ?? LiveText.noResource)
            return
        }
        if playback.kind == .recording { playback.recordCheckpoint(.left) }
        viewing?.end()
        liveStartError = nil
        currentTitle = nil
        nowPlaying = .live(station.key)
        live.lastStation = station.key
        playback.playLive(resource)
    }

    /// 録画中の録画の局を読み直す（ライブの配信が 511 で断られたとき。録画中でなければ nil）
    func refreshRecordingStation() async {
        guard let live else { return }
        let titles = (try? await services?.titles.titles(withMetadata: false)) ?? []
        recordingStation = LiveLineup.recordingStation(titles, in: live.stations(showsSubchannels: true))
    }

    /// 録画中の局へ切り替える（ライブの配信が録画のために断られたときのボタン）
    func switchToRecordingStation() {
        guard let recordingStation else { return }
        playLive(recordingStation)
    }

    /// ↑↓：前後の局へ（ライブを見ているとき）
    func stepLive(_ offset: Int) {
        guard let live, case .live(let current) = nowPlaying else { return }
        let station = LiveLineup.step(from: current, offset: offset, visible: live.stations(showsSubchannels: Self.showsSubchannels),
                                      all: live.stations(showsSubchannels: true))
        if let station { playLive(station) }
    }

    /// 数字キー：リモコンキーの局へ（ライブを見ているとき）
    func selectLive(remoteKey number: Int) {
        guard let live, case .live = nowPlaying,
              let station = LiveLineup.station(remoteKey: number, in: live.stations(showsSubchannels: Self.showsSubchannels)) else { return }
        playLive(station)
    }

    /// 録画を消す前に、その録画を再生していれば止める。止めどころは記録しない（消す録画なので）。視聴ウィンドウは開いたまま
    func stopIfPlaying(titleID: String) {
        guard nowPlaying == .recording(titleID: titleID) else { return }
        playback.stop()
        nowPlaying = nil
        currentTitle = nil
    }

    // MARK: - メディア

    /// 再生の窓に出しているメディア（録画・ライブのときは nil）
    var mediaPlayback: MediaPlayback? {
        if case .media(let media) = nowPlaying { return media }
        return nil
    }

    /// 録画・ライブを再生しているか（メディアでない。操作部・メニューの対象）
    var isPlayingBroadcast: Bool { nowPlaying != nil && mediaPlayback == nil }

    /// メディアの動画・音楽を再生の窓で再生する（録画・ライブと同じ窓を使い、窓が 1 つなので同時には鳴らない）。
    /// 録画なら止めどころを記録してから止める。逆に録画・ライブを始めると、`nowPlaying` が替わってメディアは止まる
    func playMedia(_ media: MediaPlayback) {
        if playback.kind == .recording { playback.recordCheckpoint(.left) }
        viewing?.end()
        playback.stop()
        liveStartError = nil
        currentTitle = nil
        nowPlaying = .media(media)
    }

    /// 視聴ウィンドウを閉じた
    func endViewing() {
        playback.stop()
        nowPlaying = nil
        currentTitle = nil
        liveQualityOverride = nil
        liveStartError = nil
    }

    /// 番組表にサブチャンネルも並べるか（ライブの局の並びも従う。2026-11-20 に決めた）
    static var showsSubchannels: Bool {
        UserDefaults.standard.bool(forKey: GuideSettingsKey.showsSubchannels)
    }

    private func presentLiveStartError(_ live: LiveModel, reason: String? = nil) {
        if let reason {
            liveStartError = ErrorPresentation(title: "この局はライブで見られません", message: reason)
        } else if case .failed(let error) = live.channels {
            liveStartError = error
        } else if case .failed(let error) = live.liveChannels {
            liveStartError = error
        } else {
            liveStartError = ErrorPresentation(title: LiveText.noStation, message: "nasne のライブの局の一覧に、番組表の局がありません。")
        }
    }

    /// 終了の前に、頼んだ視聴の記録の書き込みを待つ
    func flushViewing() async {
        await viewing?.flush()
    }

    /// 発見・登録の流れのモデル（登録が通ったら、足した台へ切り替えて部品を作り、`added` を呼ぶ）
    func makeSetupModel(added: (@MainActor () -> Void)? = nil) -> DeviceSetupModel {
        DeviceSetupModel(setup: setup, store: store) { [weak self] registration, device in
            Task {
                await self?.addedNasne(registration, device: device)
                added?()
            }
        }
    }
}

/// 視聴ウィンドウで再生しているもの（画質の切り替え・操作部の出し分けに使う）
enum NowPlaying: Equatable {
    case recording(titleID: String)
    case live(LiveStationKey)
    /// メディア（共有フォルダーの動画・音楽。OS の標準の再生画面）
    case media(MediaPlayback)
}
