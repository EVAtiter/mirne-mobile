import SwiftUI

/// 主ウィンドウ（登録した後）。Mac・iPad・iPhone で同じ形（2026-11-23）：
/// 上端に画面の名前だけ（Mac は窓のタイトル・iPhone の縦向きはナビゲーションの帯。iPad の広い幅は上の帯を出さない。
/// iPhone の横向きは上の帯を隠し、名前を各画面の帯の中央に出す）、
/// 各画面の帯の右端に「ライブ」「設定」（iPhone の縦向き・iPad の狭い分割は上の帯の右端）、下端に「番組表」「予約」「録画」「情報」の切り替え（`MainTabContainer`。OS ごと）。
/// 設定は主ウィンドウの上にシートで開く（2026-11-20 に決めた）。
/// 選んだ項目は保存し、起動し直したときはその項目を開く（2026-11-20。初めて・保存した項目が無いとき・前に「設定」を保存していたときは「情報」）
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
    /// 中身の幅（足りなければ「ライブ」「設定」の文字を省く。狭い幅の番組表の列の幅にも使う）
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
        // 上の帯を出すか・狭い幅の形にするか（OS と画面の大きさで決める）
        MainLayoutReader { layout in
            mainBody(layout)
        }
    }

    private func mainBody(_ layout: MainLayout) -> some View {
        sections(layout)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: stateNotices) { environment.notices.forgetDismissed(notIn: stateNotices) }
            // 録画一覧は起動したときから読む（録画の画面を開くのを待たない。2026-11-21）
            .task { if case .idle = recordings.titles { await recordings.reload() } }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            .onChange(of: showsSubchannels) { lineup.showsSubchannels = showsSubchannels }
            .environment(logoImages)
            .onChange(of: environment.channelLogos?.revision, initial: true) { logoImages.update(from: environment.channelLogos) }
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

    /// 画面の中身と知らせを、切り替えの器（OS ごと）に入れる。知らせは切り替えのすぐ上に浮かべる
    private func sections(_ layout: MainLayout) -> some View {
        // 知らせは切り替えのすぐ上に浮かべる板（置き場所は器が決める）
        MainTabContainer(selection: $selection) {
            noticeBar
        } content: { section in
            content(section, layout: layout)
            // iPhone の横向きは、画面の名前を各画面の帯の中央に出す（録画は検索の欄で幅が足りないので出さない。2026-11-23）
            .environment(\.mainBarTitle, layout.showsBarTitle && section != .recordings ? section.title : nil)
        }
        // 上端（Mac は窓のタイトル）に今の画面の名前
        .navigationTitle(selection.title)
        // 狭い幅では各画面を狭い形で出す（帯のボタンを絵だけ・行を短く・カードをシートに）
        .environment(\.usesCompactLayout, layout.usesCompactLayout)
        // iPad の広い幅と iPhone の横向きは上の帯を隠す（各画面の帯の上の余白を戻す）
        .hidesNavigationBar(!layout.showsTitleBar)
        .environment(\.mainTitleBarHidden, !layout.showsTitleBar)
        // 「ライブ」「設定」は各画面の帯の右端に出す（iOS で上の帯を出すときは、上の帯の右端）
        .environment(\.mainBarAccessories, layout.showsAccessoriesInTitleBar ? nil : barAccessories(layout))
        .toolbar {
            if layout.showsAccessoriesInTitleBar {
                // ボタンの丸い板は上の帯が付ける（各画面の帯の部品は自分で板を付けるので使わない）
                ToolbarItemGroup(placement: .primaryAction) {
                    if let watchLive {
                        Button { watchLive(nil) } label: { Label("ライブ", systemImage: LiveSymbol.watch) }
                            .labelStyle(.iconOnly)
                            .help("ライブで見る（前に見た局）")
                            .disabled(environment.live == nil)
                    }
                    Button { showsSettings = true } label: { Label("設定", systemImage: MainToolbarSymbol.settings) }
                        .labelStyle(.iconOnly)
                        .help("設定を開く")
                }
            }
        }
    }

    /// 各画面の帯の右端に出す「ライブ」「設定」。Mac は広い窓なら絵と文字、それ以外は絵だけ（iPad・iPhone はいつも絵だけ。
    /// `MainWindowLayout.accessoryTitlesWidth` は OS ごと）
    private func barAccessories(_ layout: MainLayout) -> MainBarAccessories {
        MainBarAccessories(watchLive: watchLive.map { watch in { watch(nil) } },
                           liveDisabled: environment.live == nil,
                           openSettings: { showsSettings = true },
                           showsTitles: !layout.usesCompactLayout && contentWidth >= MainWindowLayout.accessoryTitlesWidth)
    }

    /// 知らせ（読み込み中・誤り・操作の結果。全部の画面のものをここに出す）。切り替えのすぐ上に浮かべる板（2026-11-23。前は窓の下端の帯）
    private var noticeBar: some View {
        MainNoticeBar(notices: environment.notices.visible(state: stateNotices),
                      perform: perform(_:), dismiss: { environment.notices.dismiss($0) })
    }

    @ViewBuilder
    private func content(_ section: MainSection, layout: MainLayout) -> some View {
        switch section {
        case .info: InfoView(model: info)
        case .recordings: RecordingsView(model: recordings, openViewer: openViewer)
        case .schedules: SchedulesView(model: schedules, scheduleService: services.schedules)
        case .guide:
            if let guide = environment.programGuide {
                // 狭い幅では時刻の列を詰め、局の列を画面の幅に 2 局収まる幅にする
                let sizing = GuideLayout.apply(textScale: MainTextSize.saved(textSize).scale,
                                               compactWidth: layout.usesCompactLayout ? contentWidth : nil)
                GuideView(guide: guide, lineup: lineup,
                          scheduling: GuideScheduling(service: services.schedules, schedules: schedules) { Task { await schedules.reload() } },
                          live: guideLive,
                          commandCenter: environment.mainCommands)
                    .navigationTitle("番組表")
                    // 寸法は静的に読まれるので、倍率・列の幅が変わったら番組表を作り直す
                    .id(sizing)
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

/// 主画面の「設定」の記号（各画面の帯の右端）
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

/// 主画面の形（OS と画面の大きさで決める。`MainLayoutReader`。2026-11-23 に、切り替えの置き場から、互いに関わらない 2 つに分けた）
struct MainLayout: Equatable {
    /// 上の帯（画面の名前）を出すか。出さないのは iPad の広い幅（名前は要らない。2026-11-23）と、
    /// iPhone の横向き（縦が狭いので、上の帯と各画面の帯の 2 段を 1 段にする）
    let showsTitleBar: Bool
    /// 各画面の帯の中央に画面の名前を出すか（iPhone の横向きだけ。上の帯の代わり）
    let showsBarTitle: Bool
    /// 各画面を狭い幅の形にするか（iPhone と iPad の狭い分割。帯のボタンを絵だけ・行を短く・カードをシートに）
    let usesCompactLayout: Bool
    /// 「ライブ」「設定」を上の帯（ナビゲーションの帯）の右端に出すか。iOS で上の帯を出すとき（iPhone の縦向き・iPad の狭い分割）。
    /// 各画面の帯に入れると幅が足りず、帯が画面からはみ出したため（2026-11-23）。Mac は窓のタイトルの帯に置かず、各画面の帯の右端
    let showsAccessoriesInTitleBar: Bool
}

/// 下の切り替えの項目（並びはこの順）。「設定」は 2026-11-20 に切り替えから外した（前に保存した "settings" は知らない値として「情報」になる）
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
