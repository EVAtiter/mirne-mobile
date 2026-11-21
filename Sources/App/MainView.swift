import SwiftUI

/// 主ウィンドウ（登録した後）。ツールバーの中央の切り替えで「番組表」「予約」「録画」「情報」を切り替える（2026-11-20 にサイドバーをやめた）。
/// 「ライブ」は切り替えの左、「設定」は右端の別のボタン。設定は主ウィンドウの上にシートで開く（2026-11-20 に決めた）。
/// 選んだ項目は保存し、起動し直したときはその項目を開く（2026-11-20。初めて・保存した項目が無いとき・前に「設定」を保存していたときは「情報」）
struct MainView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    let services: NasneServices
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
    /// 番組表にサブチャンネルも並べるか（設定。既定は隠す）
    @AppStorage(GuideSettingsKey.showsSubchannels) private var showsSubchannels = false

    init(services: NasneServices, channels: ChannelCatalog, library: LibraryStore?, viewing: ViewingRecorder?) {
        self.services = services
        _info = State(initialValue: InfoModel(services: services))
        _recordings = State(initialValue: RecordingsModel(services: services, channels: channels, library: library, viewing: viewing))
        _schedules = State(initialValue: SchedulesModel(schedules: services.schedules, channels: channels))
        _lineup = State(initialValue: GuideLineupModel(
            channels: channels, logoSource: services.programGuide,
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
                    Button(action: startLive) { Label("ライブ", systemImage: LiveSymbol.watch) }
                        .labelStyle(toolbarLabelStyle)
                        .help("ライブで見る（前に見た局）")
                        .disabled(environment.live == nil)
                        // 文字の有無が変わったら作り直す（作り直さないと、窓を広げても文字が戻らなかった）
                        .id(showsToolbarTitles)
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
        case .recordings: RecordingsView(model: recordings)
        case .guide:
            if let guide = environment.programGuide {
                let scale = Self.applyGuideScale(MainTextSize.saved(textSize))
                GuideView(guide: guide, lineup: lineup,
                          scheduling: GuideScheduling(service: services.schedules, schedules: schedules) { Task { await schedules.reload() } },
                          live: environment.live.map { GuideLive(model: $0, watch: watchLive(_:)) },
                          commandCenter: environment.mainCommands)
                    .navigationTitle("番組表")
                    // 寸法は静的に読まれるので、倍率が変わったら番組表を作り直す
                    .id(scale)
            } else {
                // 開けないことは知らせの帯に出す
                Color.clear
            }
        case .schedules: SchedulesView(model: schedules, scheduleService: services.schedules)
        }
    }

    /// 状態から作る知らせ（nasne を探している・各画面の読み込み中と誤り）。画面を開いていなくても出す
    private var stateNotices: [MainNotice] {
        var notices: [MainNotice] = []
        if let connection = MainNotices.connection(environment.connection) { notices.append(connection) }
        notices += MainNotices.recordings(isLoading: recordings.titles.isLoading, loadError: recordings.titles.error,
                                          isRefreshing: recordings.isRefreshing, refreshError: recordings.refreshError,
                                          isShowingSavedList: recordings.isShowingSavedList, isDeleting: recordings.deletingID != nil)
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

    /// 番組表の寸法の倍率を書く（番組表を作る前。書いた倍率を返す）
    private static func applyGuideScale(_ size: MainTextSize) -> CGFloat {
        if GuideLayout.scale != size.scale { GuideLayout.scale = size.scale }
        return size.scale
    }

    /// 視聴ウィンドウを開いて、前に見た局（初めてなら最初の局）を映す
    private func startLive() {
        openWindow(id: ViewerWindowID.main)
        Task { await environment.startLive() }
    }

    /// 番組表の局をライブで見る
    private func watchLive(_ channel: Channel) {
        openWindow(id: ViewerWindowID.main)
        Task { await environment.startLive(channel: channel) }
    }
}

/// ライブの記号（ツールバーの「ライブ」と番組表の視聴のボタン。 で `play.tv` と決めた）
enum LiveSymbol {
    static let watch = "play.tv"
}

/// 主ウィンドウのツールバーの記号
enum MainToolbarSymbol {
    static let settings = "gearshape"
}

/// 主ウィンドウの設定の鍵（UserDefaults）
enum MainWindowSettingsKey {
    /// 最後に選んだ切り替えの項目（`MainSection` の rawValue）。鍵の名前はサイドバーだったときのまま
    static let section = "mainSidebarSection"
    /// 文字の大きさ（`MainTextSize` の rawValue。未設定なら標準）
    static let textSize = "mainTextSize"
}

/// どちらかのラベルの形を、実行時に選べるように包む
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init<Style: LabelStyle>(_ style: Style) {
        make = { AnyView(Label($0).labelStyle(style)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// 番組表の設定の鍵（UserDefaults）
enum GuideSettingsKey {
    /// サブチャンネルも並べるか（既定は false）
    static let showsSubchannels = "guideShowsSubchannels"
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

/// 情報（2026-11-19 に「ホーム」から改名）。区画ごとに読み込み、失敗した区画だけ誤りを出す
struct InfoView: View {
    @State var model: InfoModel
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(spacing: 0) {
            // 上の帯（番組表と同じ位置）。情報の画面の操作は「更新」だけ
            ScreenActionBar(refreshHelp: "情報を更新する（⌘R）", isRefreshing: model.isLoading,
                            refresh: { Task { await model.reload() } }) { EmptyView() }
            form
        }
        .navigationTitle("情報")
        .task {
            if model.lastUpdated == nil { await model.reload() }
            #if DEBUG
            // 非機能要件の計測（参考値：全部の区画がそろうまで。起動してから最初の 1 回だけ出す。開発用のビルドだけ）
            if model.lastUpdated != nil { PerformanceLog.infoCompleted() }
            #endif
        }
        #if DEBUG
        // 非機能要件の計測（「起動 → 情報の画面の表示」：最初の区画に値が出たとき。起動してから最初の 1 回だけ出す。開発用のビルドだけ）
        .onChange(of: model.hasAnyValue, initial: true) { _, shown in
            if shown { PerformanceLog.infoShown() }
        }
        #endif
        .onChange(of: environment.mainCommands.pending, initial: true) {
            if environment.mainCommands.consume(.refresh) { Task { await model.reload() } }
        }
    }

    private var form: some View {
        Form {
            Section("本体情報") {
                section(model.device) { device in
                    LabeledContent("名前", value: device.name)
                    LabeledContent("システムソフトウェア", value: device.softwareVersion)
                    if let date = device.currentDate {
                        LabeledContent("本体の時刻", value: date.formatted(date: .abbreviated, time: .standard))
                    }
                    if let area = device.area { LabeledContent("地域", value: area) }
                    if let count = device.titleCount {
                        LabeledContent("録画", value: device.titleMax.map { "\(count) / \($0) 件" } ?? "\(count) 件")
                    }
                    if device.updateExists { LabeledContent("更新", value: "システムソフトウェアの更新があります") }
                }
            }

            Section("HDD") {
                section(model.hdds) { hdds in
                    if hdds.isEmpty { Text("HDD が見つかりません").foregroundStyle(.secondary) }
                    ForEach(hdds) { hdd in hddRow(hdd) }
                }
            }

            Section("状態") {
                section(model.status) { status in
                    if status.recordingTitles.isEmpty {
                        LabeledContent("録画中", value: "なし")
                    } else {
                        ForEach(Array(status.recordingTitles.enumerated()), id: \.offset) { _, title in
                            LabeledContent("録画中", value: title)
                        }
                    }
                    if status.messages.isEmpty {
                        LabeledContent("お知らせ", value: "なし")
                    } else {
                        ForEach(Array(status.messages.enumerated()), id: \.offset) { _, message in
                            Label(message, systemImage: "exclamationmark.bubble")
                        }
                    }
                }
            }

            Section("録画失敗") {
                section(model.recNg) { items in
                    if items.isEmpty { Text("録画失敗はありません").foregroundStyle(.secondary) }
                    ForEach(items, id: \.id) { item in
                        LabeledContent(item.title.isEmpty ? "（番組名なし）" : item.title,
                                       value: item.start?.formatted(date: .abbreviated, time: .shortened) ?? "")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 区画の読み込みの状態を出す
    @ViewBuilder
    private func section<Value, Content: View>(_ state: Loadable<Value>,
                                               @ViewBuilder content: (Value) -> Content) -> some View {
        switch state {
        case .idle, .loading, .failed:
            // 読み込み中・読み込めなかったことは知らせの帯に出す
            EmptyView()
        case .loaded(let value):
            content(value)
        }
    }

    private func hddRow(_ hdd: HDDSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(hdd.isInternal ? "内蔵 HDD" : "外付け HDD")
                Spacer()
                if let free = hdd.freeBytes, let total = hdd.totalBytes {
                    Text("空き \(Self.bytes(free)) / \(Self.bytes(total))").foregroundStyle(.secondary)
                } else if !hdd.isMounted {
                    Text("つながっていません").foregroundStyle(.secondary)
                }
            }
            if let fraction = hdd.usedFraction {
                ProgressView(value: fraction)
                    .help("使用 \(hdd.usedBytes.map(Self.bytes) ?? "-")")
            }
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .decimal)
    }
}

/// 設定（登録した nasne と資格情報）
/// 設定のシート（主ウィンドウの中で開く。iPad と同じ形にするため）
struct SettingsSheet: View {
    let services: NasneServices
    let credentials: CredentialsModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsView(services: services, credentials: credentials)
            Divider()
            HStack {
                Spacer()
                Button("閉じる", action: close)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(SettingsSheetLayout.barPadding)
        }
        .frame(minWidth: SettingsSheetLayout.minimumSize.width, idealWidth: SettingsSheetLayout.idealSize.width,
               minHeight: SettingsSheetLayout.minimumSize.height, idealHeight: SettingsSheetLayout.idealSize.height)
    }
}

/// 設定のシートの大きさ
enum SettingsSheetLayout {
    static let minimumSize = CGSize(width: 480, height: 400)
    static let idealSize = CGSize(width: 560, height: 600)
    static let barPadding: CGFloat = 12

    /// 右に足す余白：「スクロールバーを常に表示」のとき、スクロールバーが Form（grouped）の右の余白（左と同じ 20pt）の中に
    /// 重なって描かれ、中身の端からスクロールバーまで約 2pt しか空かなかった（2026-11-21・AX で測った）。そのときはスクロールバーの幅を足す。
    /// `contentMargins` は Form がもともと持つ余白に足し算で効く（AX で測った。`for: .scrollContent` は効かなかった）ので、足す分だけを返す
    /// `NSScroller` は main actor の上でしか読めないので、これも main actor に置く（画面の中からしか読まない）
    @MainActor static func extraTrailingMargin(scrollerStyle: NSScroller.Style) -> CGFloat {
        scrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }
}

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    let services: NasneServices
    let credentials: CredentialsModel
    @State private var error: ErrorPresentation?
    @State private var confirming = false
    @AppStorage(GuideSettingsKey.showsSubchannels) private var showsSubchannels = false
    @AppStorage(ViewerSettingsKey.captionsByDefault) private var captionsByDefault = false
    /// ライブを始めるときの画質（既定は DR）
    @AppStorage(LiveSettingsKey.defaultQuality) private var liveDefaultQuality = LiveQuality.initial.rawValue
    /// 主ウインドウの文字の大きさ
    @AppStorage(MainWindowSettingsKey.textSize) private var textSize = MainTextSize.initial.rawValue
    /// スクロールバーの出し方（「常に表示」のときは右の余白にスクロールバーの幅を足す）
    @State private var scrollerStyle = NSScroller.preferredScrollerStyle

    var body: some View {
        Form {
            Section("表示") {
                Picker("文字の大きさ", selection: Binding(get: { MainTextSize.saved(textSize) }, set: { textSize = $0.rawValue })) {
                    ForEach(MainTextSize.allCases) { size in Text(size.label).tag(size) }
                }
                SettingsNote("主ウインドウの文字の大きさです。", details: ["視聴ウインドウと字幕は変わりません。"])
            }
            Section("nasne") {
                LabeledContent("登録した nasne", value: services.registration.friendlyName)
                if let date = services.registration.registeredAt {
                    LabeledContent("登録した日時", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Button("登録を外す…", role: .destructive) { confirming = true }
            }
            Section("番組表") {
                Toggle("サブチャンネルも表示する", isOn: $showsSubchannels)
                SettingsNote("同じ局の 2 つ目以降のテレビのサービスです。",
                             details: ["ふだんは本チャンネルと同じ番組なので、既定では出しません。"])
            }
            Section("再生") {
                Toggle("起動したときに字幕を表示する", isOn: $captionsByDefault)
                SettingsNote("再生中は C キーか操作部のボタンで出し入れできます。",
                             details: ["選んだ状態は、アプリを終えるまで次の録画にも引き継ぎます。"])
            }
            Section("ライブ") {
                Picker("始めるときの画質", selection: Binding(get: { LiveQuality.saved(liveDefaultQuality) },
                                                        set: { liveDefaultQuality = $0.rawValue })) {
                    ForEach(LiveQuality.allCases, id: \.self) { quality in Text(quality.label).tag(quality) }
                }
                SettingsNote("ライブを始めるときの画質です。",
                             details: ["視聴ウインドウで切り替えた画質は、ウインドウを閉じるまで局を替えても引き継ぎます。"])
            }
            CredentialsSection(model: credentials)
            if let error { Section { ErrorBanner(error: error) } }
        }
        .formStyle(.grouped)
        .contentMargins(.trailing, SettingsSheetLayout.extraTrailingMargin(scrollerStyle: scrollerStyle))
        .contentMargins(.trailing, 0, for: .scrollIndicators)
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scrollerStyle = NSScroller.preferredScrollerStyle
        }
        .navigationTitle("設定")
        .confirmationDialog("この nasne の登録を外しますか？", isPresented: $confirming) {
            Button("登録を外す", role: .destructive) {
                Task {
                    do {
                        try await environment.unregister()
                    } catch {
                        self.error = ErrorText.present(error)
                    }
                }
            }
        } message: {
            Text("保存した登録と、この Mac に保存した番組表・録画一覧を消します。この Mac の視聴の記録（見終わった・途中まで見た位置）も消えます。nasne の録画や予約は消えません。")
        }
    }
}

/// 中央の切り替え。項目にシンボルと文字を並べる（窓が狭いときはシンボルだけ）。
///
/// SwiftUI の segmented の Picker は、Label を渡しても絵を出さず（文字だけになった）、文字に埋め込んだ絵も出さなかった（2026-11-21）。
/// AppKit の NSSegmentedControl は項目に絵と文字の両方を設定すると並べて出すので、それを載せる。iPad 版では iPad の部品で作る
struct MainSectionPicker: NSViewRepresentable {
    @Binding var selection: MainSection
    /// 文字も出すか（窓が狭ければシンボルだけ）
    let showsTitles: Bool

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = MainSection.allCases.count
        control.trackingMode = .selectOne
        // 項目の幅は中身に合わせる（均等に広げない）
        control.segmentDistribution = .fit
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setAccessibilityLabel("画面")
        for (index, section) in MainSection.allCases.enumerated() {
            let image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)
            control.setImage(image, forSegment: index)
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            control.setToolTip(section.title, forSegment: index)
        }
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        var labelsChanged = false
        for (index, section) in MainSection.allCases.enumerated() {
            let label = showsTitles ? section.title : ""
            guard control.label(forSegment: index) != label else { continue }
            control.setLabel(label, forSegment: index)
            // 幅は中身に合わせる（0）
            control.setWidth(0, forSegment: index)
            labelsChanged = true
        }
        // 文字を省いた・戻したら大きさを測り直させる（測り直さないと、文字を省いても項目の幅が前のまま残った。2026-11-21）
        if labelsChanged { control.invalidateIntrinsicContentSize() }
        if let index = MainSection.allCases.firstIndex(of: selection), control.selectedSegment != index {
            control.selectedSegment = index
        }
    }

    /// 大きさは部品の中身から決める（文字を省いた・戻したときに SwiftUI が聞き直す。intrinsicContentSize だけでは、
    /// 文字を省いても幅が前のまま残り、戻すと文字が切れた。2026-11-21）
    func sizeThatFits(_ proposal: ProposedViewSize, nsView control: NSSegmentedControl, context: Context) -> CGSize? {
        control.intrinsicContentSize
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<MainSection>

        init(selection: Binding<MainSection>) {
            self.selection = selection
        }

        @objc func changed(_ sender: NSSegmentedControl) {
            let all = MainSection.allCases
            guard all.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = all[sender.selectedSegment]
        }
    }
}
