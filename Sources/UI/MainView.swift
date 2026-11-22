import SwiftUI

/// 主ウィンドウ（登録した後）。ツールバーの中央の切り替えで「番組表」「予約」「録画」「情報」を切り替える（2026-11-20 にサイドバーをやめた）。
/// 「ライブ」は切り替えの左、「設定」は右端の別のボタン。設定は主ウィンドウの上にシートで開く（2026-11-20 に決めた）。
/// 選んだ項目は保存し、起動し直したときはその項目を開く（2026-11-20。初めて・保存した項目が無いとき・前に「設定」を保存していたときは「情報」）。
/// iPad の主画面も同じ形（「ライブ」は再生の画面ができるまで出さない）
struct MainView: View {
    @Environment(AppEnvironment.self) private var environment
    let services: NasneServices
    /// 視聴の画面を開く（OS ごとに違うので、作る側が渡す）。無ければ「ライブ」と録画の再生のボタンを出さない
    let openViewer: (() -> Void)?
    /// 選んでいる切り替えの項目（保存する。知らない値〔前の「設定」を含む〕なら既定の「情報」）
    @AppStorage(MainWindowSettingsKey.section) private var selection: MainSection = .info
    /// 設定のシートを出しているか
    @State private var showsSettings = false
    /// 文字の大きさ（番組表の寸法に掛け、変わったら番組表を作り直す）
    @AppStorage(MainWindowSettingsKey.textSize) private var textSize = MainTextSize.initial.rawValue
    /// 中身の幅（足りなければ「ライブ」「設定」の文字を省く）
    @State private var contentWidth: CGFloat = MainWindowLayout.defaultSize.width
    @State private var info: InfoModel
    @State private var recordings: RecordingsModel
    @State private var lineup: GuideLineupModel
    @State private var schedules: SchedulesModel
    @State private var credentials = CredentialsModel.live()
    /// 局のロゴの絵（録画・予約の一覧の行の頭に出す。ロゴが変わったときだけ作り直す）
    @State private var logoImages = ChannelLogoImages()
    /// 番組表にサブチャンネルも並べるか（設定。既定は隠す）
    @AppStorage(GuideSettingsKey.showsSubchannels) private var showsSubchannels = false

    init(services: NasneServices, channels: ChannelCatalog, logos: ChannelLogoModel?, library: LibraryStore?, viewing: ViewingRecorder?,
         openViewer: (() -> Void)?) {
        self.services = services
        self.openViewer = openViewer
        _info = State(initialValue: InfoModel(services: services))
        _recordings = State(initialValue: RecordingsModel(services: services, channels: channels, library: library, viewing: viewing))
        _schedules = State(initialValue: SchedulesModel(schedules: services.schedules, channels: channels))
        _lineup = State(initialValue: GuideLineupModel(
            channels: channels, logos: logos,
            showsSubchannels: UserDefaults.standard.bool(forKey: GuideSettingsKey.showsSubchannels)))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            // 知らせの帯（読み込み中・誤り・操作の結果。全部の画面のものをここに出す）。窓の下端に置く（2026-11-21。前は上）
            MainNoticeBar(notices: environment.notices.visible(state: stateNotices),
                          perform: perform(_:), dismiss: { environment.notices.dismiss($0) })
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: stateNotices) { environment.notices.forgetDismissed(notIn: stateNotices) }
            // 録画一覧は起動したときから読む（録画の画面を開くのを待たない。2026-11-21）
            .task { if case .idle = recordings.titles { await recordings.reload() } }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            .onChange(of: showsSubchannels) { lineup.showsSubchannels = showsSubchannels }
            .environment(logoImages)
            .onChange(of: environment.channelLogos?.revision, initial: true) { logoImages.update(from: environment.channelLogos) }
            .toolbar {
                // 中央の切り替え。シンボルと文字（窓が狭いときはシンボルだけ）
                ToolbarItem(placement: .principal) {
                    MainSectionPicker(selection: $selection, showsTitles: showsToolbarTitles)
                        .fixedSize()
                        // 文字の有無が変わったら作り直す（ツールバーが項目の背景の大きさを測り直すように）
                        .id(showsToolbarTitles)
                }
                // ライブと設定：右端に 1 つのまとまりで並べる（「ライブ」は前は切り替えの左。
                // 2026-11-21 に「設定」の左へ移した）。各画面の操作は画面の上の帯にある
                ToolbarItemGroup(placement: .primaryAction) {
                    if let watchLive {
                        Button { watchLive(nil) } label: { Label("ライブ", systemImage: LiveSymbol.watch) }
                            .labelStyle(toolbarLabelStyle)
                            .help("ライブで見る（前に見た局）")
                            .disabled(environment.live == nil)
                            // 文字の有無が変わったら作り直す（作り直さないと、窓を広げても文字が戻らなかった）
                            .id(showsToolbarTitles)
                    }
                    Button { showsSettings = true } label: { Label("設定", systemImage: MainToolbarSymbol.settings) }
                        .labelStyle(toolbarLabelStyle)
                        .help("設定を開く")
                        .id(showsToolbarTitles)
                }
            }
            .sheet(isPresented: $showsSettings) {
                SettingsSheet(services: services, credentials: credentials) { showsSettings = false }
            }
            // メニュー：録画と予約のモデルを渡し（項目の有効・無効に使う）、設定…（⌘,）の頼みを受ける
            .onAppear {
                environment.mainCommands.recordings = recordings
                environment.mainCommands.schedules = schedules
            }
            .onChange(of: environment.mainCommands.pending, initial: true) {
                if environment.mainCommands.consume(.settings) { showsSettings = true }
                if environment.mainCommands.consume(.watchLive) { watchLive?(nil) }
            }
    }

    /// 窓の幅が足りないときは、「ライブ」「設定」をシンボルだけにする
    /// ツールバーの項目に文字も出すか（窓の幅が足りなければシンボルだけ）
    private var showsToolbarTitles: Bool {
        contentWidth >= MainWindowLayout.compactToolbarWidth
    }

    private var toolbarLabelStyle: AnyLabelStyle {
        showsToolbarTitles ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly)
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .info: InfoView(model: info)
        case .recordings: RecordingsView(model: recordings, openViewer: openViewer)
        case .schedules: SchedulesView(model: schedules, scheduleService: services.schedules)
        case .guide:
            if let guide = environment.programGuide {
                let scale = Self.applyGuideScale(MainTextSize.saved(textSize))
                GuideView(guide: guide, lineup: lineup,
                          scheduling: GuideScheduling(service: services.schedules, schedules: schedules) { Task { await schedules.reload() } },
                          live: guideLive,
                          commandCenter: environment.mainCommands)
                    .navigationTitle("番組表")
                    // 寸法は静的に読まれるので、倍率が変わったら番組表を作り直す
                    .id(scale)
            } else {
                // 開けないことは知らせの帯に出す
                Color.clear
            }
        }
    }

    /// 番組表の局をライブで見る（視聴の画面を開けなければ無く、局名の欄の視聴のボタンを出さない）
    private var guideLive: GuideLive? {
        guard let live = environment.live, let watchLive else { return nil }
        return GuideLive(model: live) { watchLive($0) }
    }

    /// 番組表の寸法の倍率を書く（番組表を作る前。書いた倍率を返す）
    private static func applyGuideScale(_ size: MainTextSize) -> CGFloat {
        if GuideLayout.scale != size.scale { GuideLayout.scale = size.scale }
        return size.scale
    }

    /// ライブで見る（局を渡さなければ前に見た局。初めてなら最初の局）。視聴の画面を開けなければ無い
    private var watchLive: ((Channel?) -> Void)? {
        guard let openViewer else { return nil }
        return { [environment] channel in
            openViewer()
            Task {
                if let channel {
                    await environment.startLive(channel: channel)
                } else {
                    await environment.startLive()
                }
            }
        }
    }

    /// 状態から作る知らせ（nasne を探している・各画面の読み込み中と誤り）。画面を開いていなくても出す
    private var stateNotices: [MainNotice] {
        var notices: [MainNotice] = []
        if let connection = MainNotices.connection(environment.connection) { notices.append(connection) }
        notices += MainNotices.recordings(isLoading: recordings.titles.isLoading, loadError: recordings.titles.error,
                                          isRefreshing: recordings.isRefreshing, refreshError: recordings.refreshError,
                                          isShowingSavedList: recordings.isShowingSavedList, isDeleting: recordings.deletingID != nil,
                                          isProtecting: recordings.protectingID != nil)
        if let notice = MainNotices.schedules(isLoading: schedules.schedules.isLoading, loadError: schedules.schedules.error) {
            notices.append(notice)
        }
        if let notice = MainNotices.guide(canOpen: environment.programGuide != nil, refreshState: environment.programGuide?.state) {
            notices.append(notice)
        }
        if let notice = MainNotices.lineup(isLoading: lineup.channels.isLoading, loadError: lineup.channels.error) {
            notices.append(notice)
        }
        let infoErrors = [info.device.error, info.hdds.error, info.status.error, info.recNg.error].compactMap { $0 }
        if let notice = MainNotices.info(isLoading: info.isLoading, errors: infoErrors) { notices.append(notice) }
        return notices
    }

    /// 知らせのボタン
    private func perform(_ action: MainNoticeAction) {
        switch action {
        case .retryConnection: environment.checkConnection(.manual)
        case .reloadRecordings: Task { await recordings.reload() }
        case .reloadSchedules: Task { await schedules.reload() }
        case .reloadInfo: Task { await info.reload() }
        case .refreshGuide: Task { await environment.programGuide?.refresh() }
        case .reloadLineup: Task { await lineup.load() }
        }
    }
}

/// 主ウインドウを作り直す鍵（登録した nasne と、そのアドレス）
struct MainViewIdentity: Hashable {
    let udn: String
    let host: String
}

/// ライブの記号（ツールバーの「ライブ」と番組表の視聴のボタン。 で `play.tv` と決めた）
enum LiveSymbol {
    static let watch = "play.tv"
}

/// 主ウィンドウのツールバーの記号
enum MainToolbarSymbol {
    static let settings = "gearshape"
}

/// どちらかのラベルの形を、実行時に選べるように包む
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init<Style: LabelStyle>(_ style: Style) {
        make = { AnyView(Label($0).labelStyle(style)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// 中央の切り替えの項目（並びはこの順）。「設定」は 2026-11-20 に切り替えから外した（前に保存した "settings" は知らない値として「情報」になる）
enum MainSection: String, CaseIterable, Identifiable {
    case guide, schedules, recordings, info

    var id: String { rawValue }

    var title: String {
        switch self {
        case .guide: "番組表"
        case .schedules: "予約"
        case .recordings: "録画"
        case .info: "情報"
        }
    }

    var symbol: String {
        switch self {
        case .guide: "list.bullet.rectangle"
        case .schedules: "calendar.badge.clock"
        case .recordings: "film.stack"
        // nasne の本体・HDD・状態の情報（ホームの家の形から、情報の i に替えた）
        case .info: "info.circle"
        }
    }
}
