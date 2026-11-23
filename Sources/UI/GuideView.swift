import os
import SwiftUI

// mirne の `Sources/mirne/GuideView.swift`（8fd441a）を写したもの。
// 変えたところ:
// - 局は mirne の `ChannelList.Entry` ではなく nasne のチャンネル一覧（`Channel`）。並べる局は `GuideLineupModel`
// - データの出所は mirne の `ViewerModel` ではなく `ProgramGuideModel`（nasne の EPGGet → EPGStore）。読み直しの合図はその書き込みの回数
// - 時計は Mac の時刻（mirne は放送の時刻に合わせる）。番組を押しても選局はせず、詳細の吹き出しをすぐ出す
// - 上の操作の「視聴した局の分だけ集まります」の注記を外した（nasne は全局をまとめて返す。取り直しは開いている間の版数表の見回りで行う）
// - 別ウィンドウ（`WindowID.guide`・`GuideWindowController`）とシートは、まだ写していない

/// 番組表の画面の寸法。
enum GuideLayout {
    /// 主ウインドウの文字の倍率（mirne mobile で足した）。列の幅・1 分の高さ・時刻の列の幅・ロゴ・概要を出す高さに掛ける。
    /// 主ウインドウ（`MainView`）が番組表を作る前に書き、倍率が変わったら番組表を作り直す（`.id`）。
    /// 寸法は表のあちこち（行・欄・スクロールの計算）が静的に読むので、環境の値で配らずここに置いた。書くのは主スレッドだけ
    nonisolated(unsafe) static var scale: CGFloat = MainTextSize.standardScale
    /// 1 分の高さ。1 時間で 180 pt（30 分の番組に番組名が 2〜3 行入る）。倍率を掛ける
    static var pointsPerMinute: CGFloat { basePointsPerMinute * scale }
    private static let basePointsPerMinute: CGFloat = 3
    /// 1 時間の行の高さ（番組表は 1 時間ずつの行で並べる）
    static var hourHeight: CGFloat { 60 * pointsPerMinute }
    /// 1 日（朝 4 時から翌朝 4 時）の高さ
    static var dayHeight: CGFloat { 24 * hourHeight }
    /// 狭い幅（iPhone の縦向きなど）のときの局の列の幅。主画面が番組表を作る前に書く（`apply`）。nil なら広い幅
    nonisolated(unsafe) static var compactColumnWidth: CGFloat?
    /// 局の列の幅（倍率を掛ける。狭い幅では画面に決まった数の局が収まる幅）
    static var columnWidth: CGFloat { compactColumnWidth ?? (baseColumnWidth * scale).rounded() }
    private static let baseColumnWidth: CGFloat = 168
    /// 左の時刻の列の幅（倍率を掛ける。狭い幅では詰める）
    static var rulerWidth: CGFloat { ((compactColumnWidth == nil ? baseRulerWidth : baseCompactRulerWidth) * scale).rounded() }
    private static let baseRulerWidth: CGFloat = 32
    /// 狭い幅の時刻の列の幅（2026-11-23。時と日付〔縮めて入れる〕が入る幅。体感の値）
    private static let baseCompactRulerWidth: CGFloat = 22
    /// 表の右端の余白（スクロールバーの幅）。重ねて出すスクロールバーが右端の局の欄（局名の欄の視聴のボタン）に重なって押しにくかったので、
    /// 右端まで送ったときに最後の局がスクロールバーの左に来るよう、その幅だけ余らせる（mirne mobile で足した。2026-11-20 実機）。
    /// 「スクロールバーを常に表示」（`.legacy`）では、スクロールバーが表に重ならず自分の幅を取るので余らせない
    /// （余らせると、スクロールバーの左にもう 1 本分の隙間が開いた。2026-11-21）。
    /// 測り方は OS ごと（`guideTrailingScrollerInset()`。iPad のスクロールバーは細く、押すものに重ならないので余らせない）
    /// 局名の横に出すロゴの高さ（nasne のロゴは 64×36。縦横比はそのまま。mirne mobile で足した）
    static var logoHeight: CGFloat { baseLogoHeight * scale }
    private static let baseLogoHeight: CGFloat = 18
    /// 番組の欄に時刻と番組名に加えて概要も出す高さ（倍率を掛ける）
    static var heightForDescription: CGFloat { baseHeightForDescription * scale }
    private static let baseHeightForDescription: CGFloat = 72
    /// 別ウィンドウの初めの大きさ
    static let windowSize = CGSize(width: 1100, height: 760)
    /// シートの大きさ（幅は別ウィンドウと同じ。既定の視聴ウィンドウ（映像 960 とサイドバー）に収まる）
    static let sheetSize = CGSize(width: 1100, height: 640)
    /// 開いたとき・「現在」を押したとき、今の時刻の何時間前から見せるか
    static let hoursBeforeNow = 1
    /// 局名の行・時刻の列・左上の角の背景。番組の欄（白・ジャンルの色）と分けて、表の枠として見せる。
    /// 3 つとも同じ不透明の色にする（局名の行は半透明の `.bar`、時刻の列は白で揃っていなかった。時刻の列は番組の欄の上に重なるので、透けない色が要る）
    static var frameBackground: Color { Color.windowBackground }
    /// 日の境目（朝 4 時）の線の太さ。1 時間ごとの区切り線（1 pt）と見分けられる太さにする
    static let dayBoundaryThickness: CGFloat = 2
    /// 日の境目の線の色。区切り線（`separatorColor`）より濃くする
    static var dayBoundaryColor: Color { Color.secondaryLabelText }
    /// 画面に見えている行の前後に、余分に作っておく行の数（送り始めたときに、作るのが間に合わず空いて見えないように）
    static let overscanRows = 1
    /// 送った量がまだ分からないうちに作る行の数（開いた直後。すぐに見えている行へ置き換わる）
    static let initialRows = 8
}

/// 狭い幅の番組表（iPhone の縦向きなど）
enum GuideCompactLayout {
    /// 画面の幅に収める局の数（2026-11-23。3 局は列が狭すぎるので 2 局。横向きなど広いときは広い幅の列の幅のまま）
    static let visibleColumns: CGFloat = 2
}

/// 狭い幅の帯の日付の表記
enum GuideDayText {
    /// 「11/4 水」（「11/4(水)」の括弧を省いて空白でつなぐ。帯の幅を稼ぐため。2026-11-23）
    static func compact(_ day: GuideDay) -> String {
        ProgramGuide.dayLabel(day).replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: ")", with: "")
    }
}

/// 番組表の寸法の組（変わったら番組表を作り直す鍵）
struct GuideSizing: Hashable {
    let scale: CGFloat
    let compactColumnWidth: CGFloat?
}

extension GuideLayout {
    /// 番組表の寸法を書く（主画面が番組表を作る前に。書くのは主スレッドだけ）。
    /// `compactWidth` は狭い幅のときの画面の幅（広い幅では nil）。狭い幅では、時刻の列を詰め、局の列を画面に決まった数だけ収まる幅にする
    static func apply(textScale: CGFloat, compactWidth: CGFloat?) -> GuideSizing {
        if scale != textScale { scale = textScale }
        var column: CGFloat?
        if let compactWidth {
            let ruler = (baseCompactRulerWidth * textScale).rounded()
            let fitted = ((compactWidth - ruler) / GuideCompactLayout.visibleColumns).rounded(.down)
            column = min((baseColumnWidth * textScale).rounded(), fitted)
        }
        if compactColumnWidth != column { compactColumnWidth = column }
        return GuideSizing(scale: textScale, compactColumnWidth: column)
    }
}

/// 番組表の調べ（数と位置だけ。番組名は書かない）
enum GuideDiagnostics {
    static let logger = Logger(subsystem: AppLog.subsystem, category: "ui")
}

/// 番組表の読み直しの決まり
enum GuideReloadTiming {
    /// 番組表が保存されたことによる読み直しを、これより詰めて行わない。巡回や視聴の始めは番組表のセクションが 1 秒に何度も届くので、
    /// 届くたびに読み直すと表を作り直し続けて動きが重くなる。集まった番組が表に出るのが、最大でこの分遅れる
    static let minimumInterval: Duration = .seconds(2)
}

/// 番組の欄にマウスを置いたときに出す吹き出し（番組の内容）。
/// システムのツールチップ（`.help`）は文字が小さく書式も選べないので、自前の吹き出しにしている
enum GuidePopover {
    /// マウスを置いてから出すまで。番組の欄の上を通り過ぎるだけでは出ないよう、システムのツールチップより少し長くしてある
    static let hoverDelay: Duration = .seconds(1)
    /// 吹き出しの幅（概要を読みやすい行の長さに折り返す。文字の倍率を掛ける）
    static var width: CGFloat { (baseWidth * GuideLayout.scale).rounded() }
    private static let baseWidth: CGFloat = 340
    static let padding: CGFloat = 14
    /// 時刻・番組名・概要の間
    static let spacing: CGFloat = 6
    /// 矢印を向ける所の幅。番組の欄の横の中央から出すための細い縦の線（0 だと吹き出しが出ない）
    static let anchorWidth: CGFloat = 1
}

/// 番組表からライブで見る口（mirne mobile で足した）
struct GuideLive {
    let model: LiveModel
    /// その局をライブで見る（視聴ウィンドウを開く）
    let watch: (Channel) -> Void

    /// ボタンの説明（見られない局は理由）
    static func help(_ availability: LiveAvailability) -> String {
        if case .unavailable(let reason) = availability { return "ライブで見られません：\(reason)" }
        return "この局をライブで見る"
    }
}

extension LiveAvailability {
    /// ボタンを押せないか（分からないときは押せるようにし、押してから確かめる）
    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

/// 番組表の 1 局（列）
struct GuideStation: Identifiable, Equatable, Sendable {
    let entry: Channel
    let coverage: EPGCoverage?
    var id: String { entry.guideID }
}

extension Channel {
    /// 番組表の列の ID（ネットワーク・TS・サービスの組）
    var guideID: String { "\(networkID)-\(transportStreamID)-\(serviceID)" }

    /// 番組表（EPGStore）を引く鍵
    var guideServiceKey: EPGStore.ServiceKey {
        EPGStore.ServiceKey(networkID: networkID, transportStreamID: transportStreamID, serviceID: serviceID)
    }
}

/// 番組表に並べるもの。今日の朝 4 時から、持っている番組の最後の日の終わりまでを日をまたいで続けて並べ、1 時間ずつの行に分ける
struct GuideTable: Sendable {
    /// 並べる範囲（最初の日の始まりから最後の日の終わりまで）
    let span: GuideDay
    let days: [GuideDay]
    let stations: [GuideStation]
    /// 1 時間ずつの行（`span` の始まりから）の、局ごとの番組。行をまたぐ番組は、かかるすべての行に入る
    let hours: [[[GuidePlacement]]]

    /// 読み出した番組表から作る（重いので画面の外で行う）
    nonisolated static func build(start: Date, lineup: [Channel], schedules: [EPGStore.ServiceSchedule]) -> GuideTable {
        let days = ProgramGuide.days(from: start, through: schedules.compactMap { $0.coverage?.latestEnd }.max())
        let span = ProgramGuide.span(of: days) ?? ProgramGuide.day(containing: start)
        let hourCount = days.count * 24
        let buckets = schedules.map { schedule in
            ProgramGuide.hourBuckets(ProgramGuide.placements(schedule.events, in: span), hours: hourCount)
        }
        let hours = (0..<hourCount).map { hour in buckets.map { $0[hour] } }
        let stations = zip(lineup, schedules).map { GuideStation(entry: $0, coverage: $1.coverage) }
        return GuideTable(span: span, days: days, stations: stations, hours: hours)
    }
}

/// 番組表。局を横・時間を縦に並べ、番組を押すとその番組の詳細を出す。
///
/// 今日の朝 4 時から、持っている番組の最後の日までを日をまたいで続けて並べる（日付の選択は、その日へ送るだけ）。
/// 行は 1 時間ずつで、画面に出ている行だけを作る（8 日分の番組の欄を一度に作らない）。
/// 開いたときに局の一覧を読み、番組表を取り直す（版数表が前と同じなら EPGGet は送らない）
struct GuideView: View {
    let guide: ProgramGuideModel
    let lineup: GuideLineupModel
    /// 番組から予約するときの予約のサービスと、作った後の知らせ（mirne mobile で足した）
    var scheduling: GuideScheduling?
    /// 局をライブで見る口（無ければボタンを出さない）
    var live: GuideLive?
    /// メニューの頼みを受け取る（mirne mobile で足した。無ければ受け取らない）
    var commandCenter: MainCommandCenter?
    var dismiss: (() -> Void)?
    /// 開いているシート（番組の詳細か、予約の作成。閉じていれば nil）
    @State private var sheet: GuideSheet?
    /// 知らせの帯（「予約しました」を出す）
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    /// 予約済みの印。予約の一覧を読み直している間・読めなかったときは前の印のまま（読み直すたびに消えて点滅しないように）
    @State private var scheduleMarks = ScheduleMarks.none

    /// 並べている番組表（最初の読み込みが済むまで nil）
    @State private var table: GuideTable?
    /// 並べる範囲の始まり（朝 4 時）。開いている間に日が替わっても、開き直すか「現在」を押すまでは動かさない
    /// （始まりを動かすと、見ている位置が 1 日分ずれる）
    @State private var rangeStart: Date?
    /// 表示した後に今の時刻へ送る（読み込みが済んでから）
    @State private var scrollRequest = 0
    /// 「現在」へ送るのを、読み込みが済むまで待っている
    @State private var pendingScrollToNow = false
    @State private var position = ScrollPosition(point: .zero)
    /// 局名の行の高さ（左上の角を同じ高さで塗り、時刻の列をその下から出す）
    @State private var headerHeight: CGFloat = 0
    /// 狭い幅の形（局名の欄の取得の時刻を省く）
    @Environment(\.usesCompactLayout) private var compact
    /// 送った量（時刻の列と上の操作だけが読む）
    @State private var scroll = GuideScrollState()
    /// マウスの下の番組と吹き出し
    @State private var hover = GuideHoverState()
    @State private var loading = GuideLoadState()
    /// 局のロゴの絵（serviceID ごと。`lineup.logos` が変わったときだけ PNG を読み直す）
    @State private var logoImages: [Int: Image] = [:]

    var body: some View {
        VStack(spacing: 0) {
            GuideToolbar(days: table?.days ?? [], scroll: scroll,
                         moveDay: moveDay(by:), showDay: showDay(_:), showNow: showNow, dismiss: dismiss)
            Divider()
            if lineup.lineup.isEmpty {
                lineupPlaceholder
            } else {
                grid
                    // ほかのアプリから戻るクリックで、番組のシートを出さない（macOS。窓を前面にするだけ）
                    .overlay { ActivationClickBlocker() }
            }
        }
        // 番組表の書き込み・局の一覧の変化を見て読み直す。見るのは下の小さな view だけにし、この画面全体は描き直さない
        .background {
            GuideReloadDriver(revision: guide.revision, lineup: lineup.lineup.map(\.guideID), rangeStart: rangeStart) { immediate in
                await reload(immediate: immediate)
            }
        }
        .onAppear {
            if rangeStart == nil { rangeStart = ProgramGuide.day(containing: Date()).start }
        }
        // 開いたときに局の一覧を読み、番組表を取り直す
        .task {
            await lineup.load()
            async let logos: Void = lineup.loadLogos()
            await guide.refresh()
            await logos
        }
        // 開いていて前面にある間は、版数表を見回り、変わっていたら取り直す（同じなら EPGGet を送らない）
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: ProgramGuideRefreshTiming.checkInterval)
                await guide.refreshQuietly()
            }
        }
        // ライブで見られる局を知る（Browse だけ。チューナーは動かない）
        .task { await live?.model.load() }
        // 予約済みの印のために予約の一覧を読む（まだ読んでいなければ。作った・変えた・消した後は主ウィンドウの予約のモデルが読み直す）
        .task {
            if let model = scheduling?.schedules, model.schedules == .idle { await model.reload() }
        }
        .onChange(of: scheduling?.schedules.schedules.value, initial: true) { _, value in
            if let value { scheduleMarks = ScheduleMarks(value) }
        }
        .onChange(of: lineup.logos, initial: true) {
            logoImages = lineup.logos.compactMapValues(GuideLogo.image(from:))
        }
        .onDisappear { hover.reset() }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .program(let selection):
                ProgramSheet(selection: selection,
                             reserve: scheduling == nil ? nil : { reserve(selection) },
                             watch: live.map { live in { self.sheet = nil; live.watch(selection.station) } },
                             watchAvailability: live?.model.availability(of: selection.station) ?? .unknown,
                             close: { self.sheet = nil })
            case .creation(let creation):
                ScheduleCreationView(model: creation, channelName: { _ in creation.program?.channel.serviceName ?? "" }) { createdID in
                    let title = creation.program?.title
                    self.sheet = nil
                    if createdID != nil {
                        // 知らせの帯に出す（前はアラート）
                        environment.notices.post(MainNotice(id: "guide.reservation", kind: .success, title: "予約しました",
                                                            detail: title.flatMap { $0.isEmpty ? nil : $0 }))
                        scheduling?.created()
                    }
                }
            }
        }
        .onChange(of: scrollRequest) { scrollToNow() }
        // メニュー：番組表の「現在」へ
        .onChange(of: commandCenter?.pending, initial: true) {
            guard let center = commandCenter else { return }
            if center.consume(.guideNow) { showNow() }
        }
    }

    /// 番組を押した：詳細のシートを出す（吹き出しではなく、「閉じる」で閉じる。2026-11-19）
    private func showProgram(station index: Int, placement: GuidePlacement) {
        guard let table, table.stations.indices.contains(index) else { return }
        sheet = .program(GuideProgramSelection(station: table.stations[index].entry, event: placement.event))
    }

    /// シートの「録画予約」：同じシートを番組の予約の作成に替える
    private func reserve(_ selection: GuideProgramSelection) {
        guard let scheduling, let program = ScheduleProgram(station: selection.station, event: selection.event),
              program.isReservable(at: Date()) else { return }
        sheet = .creation(ScheduleCreationModel(program: program, service: scheduling.service))
    }

    /// 並べる局が無いとき（読み込み中・失敗・テレビの局が無い）
    @ViewBuilder private var lineupPlaceholder: some View {
        switch lineup.channels {
        case .idle, .loading, .failed:
            // 読み込み中・読み込めなかったことは知らせの帯に出す（「もう一度読み込む」も帯に）
            Color.clear
        case .loaded:
            ContentUnavailableView("テレビの局がありません", systemImage: "list.bullet.rectangle",
                                   description: Text("nasne のチャンネル一覧に、テレビの局がありません。"))
        }
    }

    // MARK: - 上の操作

    /// 今日の、今の時刻の少し前へ送る（「現在」ボタン・番組表を開き直したとき）。日が替わっていたら、範囲の始まりを今日にしてから送る
    private func showNow() {
        let today = ProgramGuide.day(containing: Date()).start
        if today != rangeStart || table?.span.start != today {
            pendingScrollToNow = true
            rangeStart = today
        } else {
            scrollRequest += 1
        }
    }

    /// 前後の日へ。見ている時刻と横の位置は変えない（日付を替えても同じ時間帯を見られるように）
    private func moveDay(by offset: Int) {
        guard let table else { return }
        let target = scroll.visibleDay + offset
        guard table.days.indices.contains(target) else { return }
        scrollVertically(to: scroll.y + CGFloat(offset) * GuideLayout.dayHeight, in: table)
    }

    /// 選んだ日へ。見ている時刻と横の位置は変えない
    private func showDay(_ index: Int) {
        guard let table, table.days.indices.contains(index) else { return }
        let timeOfDay = scroll.y - CGFloat(scroll.visibleDay) * GuideLayout.dayHeight
        scrollVertically(to: CGFloat(index) * GuideLayout.dayHeight + timeOfDay, in: table)
    }

    private func scrollVertically(to y: CGFloat, in table: GuideTable) {
        let limit = CGFloat(table.days.count - 1) * GuideLayout.dayHeight + (GuideLayout.dayHeight - GuideLayout.hourHeight)
        position.scrollTo(point: CGPoint(x: scroll.x, y: min(max(y, 0), max(limit, 0))))
    }

    /// 今の時刻の `hoursBeforeNow` 時間前の行へ、左端から（今までの「現在」と同じ）
    private func scrollToNow() {
        guard let table else { return }
        let now = Date()
        let hour = table.span.contains(now) ? Int(now.timeIntervalSince(table.span.start) / 3600) - GuideLayout.hoursBeforeNow : 0
        position.scrollTo(point: CGPoint(x: 0, y: CGFloat(max(hour, 0)) * GuideLayout.hourHeight))
    }

    // MARK: - グリッド

    @ViewBuilder private var grid: some View {
        if let table {
            // 今の時刻は分の単位で進める（Mac の時刻の分の境目に合わせる）
            let minute = (Date().timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
            TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: minute), by: 60)) { context in
                tableView(table, now: context.date)
            }
        } else {
            Color.clear
        }
    }

    private func tableView(_ table: GuideTable, now: Date) -> some View {
        // ジャンルの色の設定（mirne の設定の画面）はまだ写していないので、mirne の既定を使う
        let palette = GuideGenrePalette(GuideGenreColors())
        let style = GuideGenreStyle.both
        return ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    GuideRows(table: table, now: now, genreStyle: style, palette: palette, marks: scheduleMarks, scroll: scroll,
                              hover: hover, select: showProgram(station:placement:))
                } header: {
                    header(table)
                }
            }
            .guideTrailingScrollerInset()
            // 斜めのスワイプでも自由に動かす（Mac のトラックパッド・Magic Mouse。iPad・iPhone は元から）
            .guideFreeScrolling()
        }
        .scrollPosition($position)
        // 下端の安全領域（iPad・iPhone の OS のタブバー）を無視し、横のスクロールバーを画面の下端（タブバーの裏）に出す。
        // タブバーは重なるだけにする（Mac と同じ。最後の行の真ん中はタブバーに隠れる。2026-11-23）
        .ignoresSafeArea(.container, edges: .bottom)
        // 送った量だけを時刻の列・上の操作・作る行の範囲へ渡す（この値を読むのはその 3 つだけなので、番組の欄は描き直さない）
        .onScrollGeometryChange(for: GuideScrollGeometry.self) {
            GuideScrollGeometry(offset: CGPoint(x: $0.contentOffset.x + $0.contentInsets.leading, y: $0.contentOffset.y + $0.contentInsets.top),
                                viewportHeight: $0.containerSize.height)
        } action: { old, geometry in
            scroll.update(geometry, dayCount: table.days.count, hourCount: table.hours.count)
            if old.offset != geometry.offset { hover.scrolled() }
        }
        .overlay(alignment: .topLeading) {
            FloatingRuler(scroll: scroll, top: headerHeight) { rulerContent(table, now: now) }
        }
        .overlay(alignment: .topLeading) { corner }
    }

    private func header(_ table: GuideTable) -> some View {
        // ほかの局に番組表があるのに無い局は、nasne が番組表を返さない局（版数表に載っていない）。
        // どの局にも無ければ、まだ取っていないだけ（mirne mobile で足した。mirne は「未取得」だけ）
        let hasAnyCoverage = table.stations.contains { $0.coverage != nil }
        return HStack(spacing: 0) {
            Color.clear.frame(width: GuideLayout.rulerWidth)
            ForEach(table.stations) { station in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let key = station.entry.remoteControlKey {
                            Text("\(key)").scaledFont(.headline, monospacedDigit: true).foregroundStyle(.secondary)
                        }
                        if let logo = logoImages[station.entry.serviceID] {
                            logo.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                                .frame(height: GuideLayout.logoHeight)
                                .accessibilityHidden(true)
                        }
                        Text(station.entry.serviceName).scaledFont(.headline).lineLimit(1)
                        if let live {
                            // 局名の欄の端の視聴のボタン（局名そのものを押しても視聴は始めない）
                            Spacer(minLength: 0)
                            let availability = live.model.availability(of: station.entry)
                            Button { live.watch(station.entry) } label: { Image(systemName: LiveSymbol.watch) }
                                .buttonStyle(.borderless)
                                .disabled(availability.isUnavailable)
                                .help(GuideLive.help(availability))
                                .accessibilityLabel("この局をライブで見る")
                        }
                    }
                    // 狭い幅では取得の時刻を省く（2026-11-23。番組表の無い局・まだ取っていない局の断りは残す）
                    if !(compact && station.coverage != nil) {
                        Text(station.coverage.map { "取得 \(ProgramGuide.receivedLabel($0.lastReceived))" }
                             ?? (hasAnyCoverage ? "nasne の番組表なし" : "未取得"))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            // 局の欄の中央に置く（2026-11-23。局名の行は左寄せのまま）
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(width: GuideLayout.columnWidth, alignment: .leading)
                .overlay(alignment: .leading) { GuideRule(axis: .vertical) }
            }
        }
        .background(GuideLayout.frameBackground)
        .overlay(alignment: .bottom) { GuideRule(axis: .horizontal) }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
    }

    /// 左上の角（時刻の列の上・局名の行の左）。スクロールの外から重ね、横に送った局名が時刻の列の上へ入り込まないようにする。
    /// 局名の行の中に左へ留める並びを入れると、行の高さが決まらず局名が上で切れた
    private var corner: some View {
        Rectangle().fill(GuideLayout.frameBackground)
            .frame(width: GuideLayout.rulerWidth, height: headerHeight)
            .overlay(alignment: .bottom) { GuideRule(axis: .horizontal) }
            .overlay(alignment: .trailing) { GuideRule(axis: .vertical) }
            .allowsHitTesting(false)
    }

    /// 時刻の列の中身（番組の欄の上に重なるので、背景を塗って下の欄を隠す）。日の境目（朝 4 時）には日付を添え、線を太くする
    private func rulerContent(_ table: GuideTable, now: Date) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(table.hours.indices, id: \.self) { index in
                    let dayStart = index % 24 == 0
                    VStack(spacing: 1) {
                        Text(ProgramGuide.hourLabel(index))
                            .scaledFont(.callout, weight: .semibold, monospacedDigit: true)
                            .foregroundStyle(.secondary)
                        if dayStart, table.days.indices.contains(index / 24) {
                            let label = ProgramGuide.rulerDayLabel(table.days[index / 24])
                            Group {
                                Text(label.date)
                                Text(label.weekday)
                            }
                            .scaledFont(.caption2, weight: .semibold, monospacedDigit: true)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        }
                    }
                    .padding(.top, 2)
                    .frame(width: GuideLayout.rulerWidth, height: GuideLayout.hourHeight, alignment: .top)
                    .overlay(alignment: .top) {
                        if dayStart, index > 0 { GuideDayBoundary() } else { GuideRule(axis: .horizontal) }
                    }
                }
            }
            if let y = GuideHourRow.nowOffset(now, from: table.span.start, within: table.span.end.timeIntervalSince(table.span.start)) {
                GuideNowLine(width: GuideLayout.rulerWidth).offset(y: y)
            }
        }
        .background(GuideLayout.frameBackground)
        .overlay(alignment: .trailing) { GuideRule(axis: .vertical) }
    }

    // MARK: - 読み込みと選局

    /// 番組表を読み直す。読み出しも表の組み立てもメインスレッドの外で行う。
    /// `immediate` でなければ（番組表が保存されただけなら）、前の読み直しから `GuideReloadTiming.minimumInterval` たつまで待つ
    private func reload(immediate: Bool) async {
        guard let start = rangeStart else { return }
        if !immediate, let last = loading.lastStarted {
            let wait = GuideReloadTiming.minimumInterval - (ContinuousClock.now - last)
            if wait > .zero { try? await Task.sleep(for: wait) }
            // 待っている間に次の合図が来た（その合図の読み直しが同じ時刻まで待つ）
            guard !Task.isCancelled else { return }
        }
        loading.lastStarted = .now
        loading.generation += 1
        let generation = loading.generation
        #if DEBUG
        let revisionAtRead = guide.revision
        #endif
        let stations = lineup.lineup
        let services = stations.map(\.guideServiceKey)
        // 範囲の終わりは持っている番組で決まるので、始まりから先をすべて読む（番組表は nasne から 8 日分ほど）
        let schedules = await guide.store.schedules(of: services, overlapping: start..<Date.distantFuture)
            .map { $0.normalizingBroadcastMarks() }
        let built = await Task.detached(priority: .userInitiated) {
            GuideTable.build(start: start, lineup: stations, schedules: schedules)
        }.value
        // 読み始めた後で取り消されても、読んだ結果は新しいので使う（次々に合図が来ると、取り消してばかりで表が変わらなくなる）。
        // 後から読み始めた結果が先に出ていれば、古いほうは捨てる
        guard generation > loading.applied else { return }
        loading.applied = generation
        GuideDiagnostics.logger.info("番組表を組んだ: 局 \(built.stations.count, privacy: .public)・日 \(built.days.count, privacy: .public)・行 \(built.hours.count, privacy: .public)・番組の欄 \(built.hours.joined().map(\.count).reduce(0, +), privacy: .public)・範囲のある局 \(built.stations.filter { $0.coverage != nil }.count, privacy: .public)")
        // 局のある表を初めて出したときに「現在」へ送る。局の一覧は開いた後で届くので、局 0 の表（表の代わりに「読んでいます」を
        // 出している間）で送っても、スクロールする表がまだ無く、届いた後の表が下の方に出ていた（mirne mobile で直した。
        // mirne は局の一覧を初めから持っている）
        let isFirstLoad = (table?.stations.isEmpty ?? true) && !built.stations.isEmpty
        table = built
        #if DEBUG
        // 非機能要件の計測（「番組表の取得 → 表示」）：EPGGet で書き換えた番組表を、初めて表に出したとき（開発用のビルドだけ）
        if let fetch = guide.lastChangedFetch, fetch.revision == revisionAtRead, loading.measuredRevision != fetch.revision {
            loading.measuredRevision = fetch.revision
            PerformanceLog.logger.info("計測: 番組表の取り直しを始めてから表を出すまで \(fetch.startedAt.elapsedMilliseconds, privacy: .public) ms（取得と保存 \(fetch.fetchMilliseconds, privacy: .public) ms・局 \(built.stations.count, privacy: .public)・日 \(built.days.count, privacy: .public)）")
        }
        #endif
        if isFirstLoad || pendingScrollToNow {
            pendingScrollToNow = false
            scrollRequest += 1
        }
    }
}

/// 番組表の読み直しの合図を見る。合図を読むのはこの小さな view だけにし、番組表の画面全体が描き直されないようにする。
/// 範囲の始まり・局の一覧が変わったら、待たずに読み直す
private struct GuideReloadDriver: View {
    /// 番組表に書き込んだ回数（`ProgramGuideModel.revision`）
    let revision: Int
    let lineup: [String]
    let rangeStart: Date?
    let reload: (_ immediate: Bool) async -> Void
    @State private var previous: ReloadKey?

    private struct ReloadKey: Equatable {
        var rangeStart: Date?
        var revision: Int
        var lineup: [String]
    }

    var body: some View {
        let key = ReloadKey(rangeStart: rangeStart, revision: revision, lineup: lineup)
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: key) {
                let immediate = previous.map { $0.rangeStart != key.rangeStart || $0.lineup != key.lineup } ?? true
                previous = key
                await reload(immediate)
            }
    }
}

/// 読み直しの時刻と順番（画面の描き直しには関わらないので、観測しない入れ物に持つ）
@MainActor
private final class GuideLoadState {
    /// 最後に読み直しを始めた時刻
    var lastStarted: ContinuousClock.Instant?
    /// 読み直しを始めた回数と、表に当てた最後の回
    var generation = 0
    var applied = 0
    #if DEBUG
    /// 計測のログを出した番組表の書き換え（同じ書き換えで 2 度出さない。開発用のビルドだけ）
    var measuredRevision: Int?
    #endif
}

/// 上の操作（日付・「現在」・閉じる）。送った位置の日付を出すので、送った量のうち「何日目か」だけを見る
private struct GuideToolbar: View {
    /// 狭い幅の形（日付の曜日の括弧を省く）
    @Environment(\.usesCompactLayout) private var compact
    let days: [GuideDay]
    let scroll: GuideScrollState
    let moveDay: (Int) -> Void
    let showDay: (Int) -> Void
    let showNow: () -> Void
    let dismiss: (() -> Void)?
    /// 帯の中央に出す画面の名前（iPhone の横向き。入らない機種では出さない）
    @Environment(\.mainBarTitle) private var title
    /// 上の帯に画面の操作も置いているか（そのときは「現在」を上の帯の左に出す）
    @Environment(\.mainTitleBarHasActions) private var titleBarHasActions

    var body: some View {
        Group {
            if let title {
                ViewThatFits(in: .horizontal) {
                    CenteredRow(spacing: ScreenActionBarLayout.spacing) {
                        HStack(spacing: ScreenActionBarLayout.spacing) { dayControls(showsSteppers: true) }
                        MainBarTitle(text: title)
                        HStack(spacing: ScreenActionBarLayout.spacing) { trailingControls }
                    }
                    rows
                }
            } else {
                rows
            }
        }
        // 録画・予約・情報の帯と同じ余白（狭い幅では段の高さを揃える）
        .screenActionBarPadding()
        // 入りきらなくても、帯の幅は画面の幅のまま（下の番組表を広げて左右にずらさない。2026-11-23）
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    /// 名前を出さない帯。入らなければ前後の日のボタンを省く
    /// （ほかの部品を押しつぶさない。日は日付のメニューから選べる。iPad の窓をいちばん狭くしたとき。2026-11-23）
    private var rows: some View {
        ViewThatFits(in: .horizontal) {
            row(showsSteppers: true)
            row(showsSteppers: false)
        }
    }

    private func row(showsSteppers: Bool) -> some View {
        HStack(spacing: ScreenActionBarLayout.spacing) {
            dayControls(showsSteppers: showsSteppers)
            Spacer()
            trailingControls
        }
    }

    /// 左の日付の操作（「現在」・前後の日・日付）。「現在」はいちばん左（2026-11-24）。上の帯に画面の操作も置くとき
    /// （iPhone の縦向き・iPad の狭い分割）は、「現在」を上の帯の左に出すので、ここには置かない
    @ViewBuilder private func dayControls(showsSteppers: Bool) -> some View {
        let visible = min(scroll.visibleDay, max(days.count - 1, 0))
        // 今の時刻へ送る（2026-11-20 に「今」から改めた）
        if !titleBarHasActions {
            Button("現在", action: showNow)
                // 幅が足りなくても文字を折り返さない（帯の形を選ぶのは `rows`）
                .lineLimit(1)
                .fixedSize()
                .barButtonChrome()
        }
        // 前後の日（OS ごとの部品）
        if showsSteppers {
            GuideDaySteppers(canGoBack: !days.isEmpty && visible > 0,
                             canGoForward: !days.isEmpty && visible < days.count - 1,
                             move: moveDay)
        }
        Picker("日付", selection: Binding(get: { days.isEmpty ? nil : visible }, set: { if let index = $0 { showDay(index) } })) {
            ForEach(days.indices, id: \.self) { index in
                Text(compact ? GuideDayText.compact(days[index]) : ProgramGuide.dayLabel(days[index])).tag(Optional(index))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        // iOS はナビゲーションの帯のボタンと同じ形（OS ごと）
        .barMenuChrome()
    }

    /// 右の操作（「ライブ」「設定」・閉じる。「更新」と更新の時刻は 2026-11-24 に外した。開いている間は版数表を見回って取り直す）
    @ViewBuilder private var trailingControls: some View {
        // 「ライブ」「設定」（上の帯の右端に置くとき〔iPhone の縦向き・iPad の狭い分割〕は出さない）
        MainBarAccessoryButtons()
        if let dismiss {
            Button("閉じる", action: dismiss)
                .keyboardShortcut(.cancelAction)
        }
    }
}

/// 送った量と、見えている高さ
private struct GuideScrollGeometry: Equatable {
    var offset: CGPoint
    var viewportHeight: CGFloat
}

/// 送った量。番組表の本体は読まず、時刻の列（`y`）・上の操作（`visibleDay`）・行の並び（`visibleRows`）だけが読む（読む view だけが描き直される）
@MainActor
@Observable
private final class GuideScrollState {
    /// 縦に送った量
    var y: CGFloat = 0
    /// 横に送った量（日付を替えるときに横の位置を保つためだけに使う。描き直しには使わない）
    @ObservationIgnored var x: CGFloat = 0
    /// 画面の上端にある日（何日目か）。日が替わったときだけ変わる
    var visibleDay = 0
    /// 作る行（見えている行と前後の余分）。行の区切りを越えたときだけ変わる
    var visibleRows = 0..<GuideLayout.initialRows

    func update(_ geometry: GuideScrollGeometry, dayCount: Int, hourCount: Int) {
        y = geometry.offset.y
        x = geometry.offset.x
        let day = min(max(Int(geometry.offset.y / GuideLayout.dayHeight), 0), max(dayCount - 1, 0))
        if day != visibleDay { visibleDay = day }
        // 行は局名の行の下から始まるので、見えている範囲は送った量から見えている高さまで（局名の行のぶんは余分の行で足りる）
        let first = Int((geometry.offset.y / GuideLayout.hourHeight).rounded(.down)) - GuideLayout.overscanRows
        let last = Int(((geometry.offset.y + geometry.viewportHeight) / GuideLayout.hourHeight).rounded(.up)) + GuideLayout.overscanRows
        let rows = min(max(first, 0), hourCount)..<min(max(last, 0), hourCount)
        if rows != visibleRows { visibleRows = rows }
    }
}

/// 1 時間の行を並べる。行の位置は計算で決め（時刻の列と必ず揃う）、見えている行だけを作る。
///
/// 最初は `LazyVStack` に全部の行を並べたが、まだ作っていない行の高さを見積もりで置くので、「次の日」などで遠くへ送ると
/// 行の位置が計算とずれ、時刻の列と番組の欄が 1 時間ほど食い違った
private struct GuideRows: View {
    let table: GuideTable
    let now: Date
    let genreStyle: GuideGenreStyle
    let palette: GuideGenrePalette
    /// 予約済みの印
    let marks: ScheduleMarks
    let scroll: GuideScrollState
    let hover: GuideHoverState
    /// 番組を押した（局の列の番号と番組）
    let select: (Int, GuidePlacement) -> Void

    var body: some View {
        let rows = scroll.visibleRows.clamped(to: 0..<table.hours.count)
        ZStack(alignment: .topLeading) {
            // 全部の行の大きさの空き（送れる範囲を決める）
            Color.clear
                .frame(width: GuideLayout.rulerWidth + GuideLayout.columnWidth * CGFloat(table.stations.count),
                       height: GuideLayout.hourHeight * CGFloat(table.hours.count))
            ForEach(Array(rows), id: \.self) { hour in
                GuideHourRow(hour: hour, start: table.span.start.addingTimeInterval(TimeInterval(hour) * 3600),
                             stations: table.stations, cells: table.hours[hour], now: now,
                             genreStyle: genreStyle, palette: palette, marks: marks, hover: hover) { station, placement in
                    // 番組を押したら、吹き出しを閉じて詳細のシートを出す（選局はまだ無い。mirne mobile で足した）
                    hover.select(station: station, placement: placement)
                    select(station, placement)
                }
                    .equatable()
                    .alignmentGuide(.top) { _ in -CGFloat(hour) * GuideLayout.hourHeight }
            }
        }
        // マウスの見張りは表全体で 1 つにし、下の行・局・番組を位置から割り出す。
        // 番組の欄ごとに見張ると数が増え、スクロールのたびにすべての見張りの範囲を直すので、縦も横も重くなった。
        // 行ごとに見張ると、「現在」へ送った直後などに見張りの範囲が送った位置に追いつかず、マウスと違う行（3 行下）に届いた
        .contentShape(Rectangle())
        // マウスを置いたときの吹き出しは macOS だけ（iPad は番組を押したときのシートだけ）
        .guidePointerHover { phase in
            switch phase {
            case .active(let location): hovered(at: location)
            case .ended: hover.mouseLeft()
            }
        }
    }

    /// マウスの位置（表の左上から）から、下の行・局・番組を割り出す
    private func hovered(at location: CGPoint) {
        let row = Int((location.y / GuideLayout.hourHeight).rounded(.down))
        let column = Int(((location.x - GuideLayout.rulerWidth) / GuideLayout.columnWidth).rounded(.down))
        guard location.x >= GuideLayout.rulerWidth, table.hours.indices.contains(row), table.hours[row].indices.contains(column) else {
            hover.update(row: max(row, 0), station: nil, placement: nil)
            return
        }
        let minutes = Double(location.y / GuideLayout.pointsPerMinute)
        let placement = table.hours[row][column].first { minutes >= $0.offsetMinutes && minutes < $0.offsetMinutes + $0.lengthMinutes }
        hover.update(row: row, station: column, placement: placement)
    }
}

/// マウスの下の番組と、吹き出しを出している番組。
/// 吹き出しは 1 時間の行に付けて出すので、同じ番組の上で行をまたいでも待ち直さないよう、番組で覚える
@MainActor
@Observable
private final class GuideHoverState {
    struct Detail: Identifiable, Equatable {
        /// 吹き出しを出す行（マウスがあった行）と局の列
        let row: Int
        let station: Int
        let placement: GuidePlacement
        var id: String { "\(station)-\(placement.id)" }
    }

    private(set) var detail: Detail?
    @ObservationIgnored private var hovered: HoverKey?
    @ObservationIgnored private var activeRow: Int?
    @ObservationIgnored private var task: Task<Void, Never>?

    private struct HoverKey: Equatable {
        let station: Int
        let event: UInt16
    }

    /// マウスが行 `row` の、局 `station` の番組 `placement` の上にある（番組が無ければ nil）。番組が替わったときだけ待ち直す
    func update(row: Int, station: Int?, placement: GuidePlacement?) {
        activeRow = row
        let key = station.flatMap { station in placement.map { HoverKey(station: station, event: $0.id) } }
        guard key != hovered else { return }
        hovered = key
        task?.cancel()
        if detail != nil { detail = nil }
        guard let station, let placement else { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: GuidePopover.hoverDelay)
            guard !Task.isCancelled, let self else { return }
            self.detail = Detail(row: self.activeRow ?? row, station: station, placement: placement)
        }
    }

    /// 番組を押した：吹き出しを閉じ、待っている吹き出しも出さない（詳細はシートで出す。mirne mobile で足した。mirne は押すと選局する）。
    /// マウスの下の番組は覚えたままにし、別の番組へ移るまで吹き出しを出し直さない
    func select(station: Int, placement: GuidePlacement) {
        task?.cancel()
        hovered = HoverKey(station: station, event: placement.id)
        if detail != nil { detail = nil }
    }

    /// 吹き出しを閉じた（外を押した）。マウスの下の番組は覚えたままにし、別の番組へ移るまで出し直さない。
    /// 吹き出しを出していないときにも SwiftUI が閉じる知らせを送ってくることがあり、そのまま待ちを取り消すと、
    /// 別の番組へ移った直後の待ちが消えて吹き出しが出なかったので、出しているときだけ閉じる
    func dismiss() {
        guard detail != nil else { return }
        task?.cancel()
        detail = nil
    }

    /// マウスが番組表の外へ出た。待っている吹き出しは取り消すが、出ている吹き出しと、マウスの下にあった番組は残す。
    ///
    /// 吹き出しがマウスの位置に重なって出ると、マウスが吹き出しの上へ移り、番組表の外へ出たことになる。
    /// ここで全部やり直していた（mirne は `reset()`）ので、閉じる → また番組の上 → 1 秒後に出す → 重なって閉じる、を繰り返して
    /// 点滅した（2026-11-19。mirne mobile で直した）。出している吹き出しは、別の番組へ移るか外を押すと閉じる
    func mouseLeft() {
        task?.cancel()
        if detail == nil {
            hovered = nil
            activeRow = nil
        }
    }

    /// 番組表が送られた：吹き出しを閉じ、待っている吹き出しも取り消す。マウスの下の番組も忘れ、止まってから番組の上に置き直すと出す。
    ///
    /// 吹き出しは番組表とは別の小さな窓なので、出したまま送ると、マウスの下に来た吹き出しがスクロールの操作を受けてしまい、
    /// 番組表がそこで止まった（2026-11-21）
    func scrolled() {
        guard detail != nil || task != nil || hovered != nil else { return }
        reset()
    }

    func reset() {
        task?.cancel()
        task = nil
        hovered = nil
        activeRow = nil
        if detail != nil { detail = nil }
    }
}

/// 1 時間の行。全局の、その 1 時間にかかる番組の欄を並べる。
///
/// 行をまたぐ番組は、かかる行ごとに同じ大きさの欄を同じ位置に描いて、行の範囲で切る（つなぎ目はずれないので、1 つの欄に見える）。
/// 同じ内容なら描き直さない（今の時刻が進んでも、放送中・終わったが変わらない欄は描き直さない）
private struct GuideHourRow: View, Equatable {
    let hour: Int
    /// この行の始まりの時刻
    let start: Date
    let stations: [GuideStation]
    /// 局ごとの、この 1 時間にかかる番組
    let cells: [[GuidePlacement]]
    let now: Date
    let genreStyle: GuideGenreStyle
    let palette: GuideGenrePalette
    /// 予約済みの印（mirne mobile で足した）
    let marks: ScheduleMarks
    let hover: GuideHoverState
    /// 番組を押した（局の列の番号と番組）
    let select: (Int, GuidePlacement) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hour == rhs.hour && lhs.start == rhs.start && lhs.now == rhs.now && lhs.stations == rhs.stations
            && lhs.cells == rhs.cells && lhs.genreStyle == rhs.genreStyle && lhs.palette == rhs.palette && lhs.marks == rhs.marks
    }

    /// この行の始まりからの分（行の中での番組の位置）
    private var startMinutes: Double { Double(hour * 60) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 時刻の列の幅の空き（時刻の列そのものはスクロールの外に重ねる）
            Color.clear.frame(width: GuideLayout.rulerWidth)
            ForEach(stations.indices, id: \.self) { index in
                cell(stations[index], index: index, placements: cells.indices.contains(index) ? cells[index] : [])
            }
        }
        .frame(height: GuideLayout.hourHeight, alignment: .top)
        .overlay(alignment: .topLeading) {
            if let y = Self.nowOffset(now, from: start, within: 3600) {
                GuideNowLine(width: nil).offset(y: y)
            }
        }
        .overlay(alignment: .top) {
            // 日の境目（朝 4 時。最初の日の始まりは局名の行の線と重なるので引かない）
            if hour > 0, hour % 24 == 0 { GuideDayBoundary() }
        }
        // 吹き出しはこの行に付けて出す（マウスの見張りは `GuideRows` が表全体で 1 つ持つ）
        .overlay(alignment: .topLeading) {
            GuidePopoverHost(hover: hover, row: hour, rowStartMinutes: startMinutes)
        }
    }

    private func cell(_ station: GuideStation, index: Int, placements: [GuidePlacement]) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(station.coverage == nil ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.background))
            ForEach(placements) { placement in
                ProgramCell(placement: placement, isOnAir: Self.isOnAir(placement.event, at: now),
                            hasEnded: (placement.event.end ?? .distantFuture) <= now,
                            isReserved: marks.isReserved(placement.event, on: station.entry), genreStyle: genreStyle,
                            genreColor: placement.event.genre.flatMap(palette.color(for:))) { select(index, placement) }
                    .equatable()
                    .offset(y: CGFloat(placement.offsetMinutes - startMinutes) * GuideLayout.pointsPerMinute)
            }
        }
        .frame(width: GuideLayout.columnWidth, height: GuideLayout.hourHeight, alignment: .topLeading)
        .clipped()
        .overlay(alignment: .leading) { GuideRule(axis: .vertical) }
    }

    static func isOnAir(_ event: BroadcastEvent, at now: Date) -> Bool {
        guard let start = event.start else { return false }
        return start <= now && now < (event.end ?? start)
    }

    /// 今の時刻の線の位置（`start` からの距離）。`length` 秒の間に入っていなければ nil
    static func nowOffset(_ now: Date, from start: Date, within length: TimeInterval) -> CGFloat? {
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= 0, elapsed < length else { return nil }
        return CGFloat(elapsed / 60) * GuideLayout.pointsPerMinute - 1
    }
}

/// 行の上に重ねて、吹き出しを出す。吹き出しの状態はこの小さな view だけが読み、行そのものは描き直さない
private struct GuidePopoverHost: View {
    let hover: GuideHoverState
    let row: Int
    let rowStartMinutes: Double

    var body: some View {
        let detail = hover.detail.flatMap { $0.row == row ? $0 : nil }
        Color.clear
            .allowsHitTesting(false)
            .popover(item: Binding(get: { detail }, set: { if $0 == nil, detail != nil { hover.dismiss() } }),
                     attachmentAnchor: .rect(.rect(anchorRect(detail))), arrowEdge: .trailing) { detail in
                ProgramDetail(event: detail.placement.event)
                    .popoverScrollWatcher { hover.scrolled() }
            }
    }

    /// 吹き出しの矢印を向ける所。番組の欄（この行に見えている部分）の中心から出す。
    /// 欄の幅いっぱいの矩形にすると矢印が欄の右端から出るので、細い縦の線を欄の横の中央に置く（縦は見えている部分の中央）。
    /// 幅を 0 にすると空の矩形とみなされ、吹き出しが出なかった
    private func anchorRect(_ detail: GuideHoverState.Detail?) -> CGRect {
        guard let detail else { return .zero }
        let top = max(CGFloat(detail.placement.offsetMinutes - rowStartMinutes) * GuideLayout.pointsPerMinute, 0)
        let bottom = min(CGFloat(detail.placement.offsetMinutes + detail.placement.lengthMinutes - rowStartMinutes) * GuideLayout.pointsPerMinute,
                         GuideLayout.hourHeight)
        let centerX = GuideLayout.rulerWidth + (CGFloat(detail.station) + 0.5) * GuideLayout.columnWidth
        return CGRect(x: centerX - GuidePopover.anchorWidth / 2, y: top, width: GuidePopover.anchorWidth, height: max(bottom - top, 1))
    }
}

/// 1 番組の欄。同じ内容なら描き直さない（押したときの処理は比べない）
private struct ProgramCell: View, Equatable {
    let placement: GuidePlacement
    let isOnAir: Bool
    let hasEnded: Bool
    /// 予約済みか（時刻の横に赤い録画の印）
    let isReserved: Bool
    let genreStyle: GuideGenreStyle
    /// ジャンルの色。ジャンルが無い番組は nil（色を付けない）
    let genreColor: Color?
    let select: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.placement == rhs.placement && lhs.isOnAir == rhs.isOnAir && lhs.hasEnded == rhs.hasEnded
            && lhs.isReserved == rhs.isReserved && lhs.genreStyle == rhs.genreStyle && lhs.genreColor == rhs.genreColor
    }

    private var event: BroadcastEvent { placement.event }
    private var height: CGFloat { CGFloat(placement.lengthMinutes) * GuideLayout.pointsPerMinute }

    /// 欄の背景。背景を塗る設定ならジャンルの淡い色、そうでなければ放送中の番組だけを強調色で塗る
    private var background: AnyShapeStyle {
        if genreStyle.paintsBackground {
            return genreColor.map { AnyShapeStyle($0.opacity(GuideGenreLayout.backgroundOpacity)) } ?? AnyShapeStyle(.clear)
        }
        return isOnAir ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear)
    }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: GuideScheduleMark.spacing) {
                    Text(event.start.map(ProgramDisplay.clock) ?? "")
                        .scaledFont(.caption, monospacedDigit: true)
                        .foregroundStyle(.secondary)
                    if isReserved {
                        // 背景（ジャンルの色）・放送中の枠とぶつからないよう、時刻の横に小さく出す（2026-11-20 に決めた）
                        Image(systemName: GuideScheduleMark.symbol)
                            .scaledFont(.caption2)
                            .foregroundStyle(.red)
                            .accessibilityLabel("予約済み")
                    }
                }
                Text(event.title)
                    .scaledFont(.callout, weight: .semibold)
                    .multilineTextAlignment(.leading)
                if height >= GuideLayout.heightForDescription, !event.text.isEmpty {
                    Text(event.text)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .padding(.leading, genreStyle.showsStripe ? GuideGenreLayout.stripeWidth : 0)
            .frame(width: GuideLayout.columnWidth, height: height, alignment: .topLeading)
            .background(background)
            .overlay(alignment: .leading) {
                if genreStyle.showsStripe, let genreColor {
                    Rectangle().fill(genreColor).frame(width: GuideGenreLayout.stripeWidth)
                }
            }
            .opacity(hasEnded ? 0.55 : 1)
            .overlay {
                // 背景をジャンルの色で塗るときは、放送中の番組を塗らずに枠で示す。枠は帯と同じジャンルの色で描く
                // （ジャンルが無い番組は強調色）
                if isOnAir, genreStyle.paintsBackground {
                    Rectangle().strokeBorder(genreColor ?? Color.accentColor, lineWidth: GuideGenreLayout.onAirOutlineWidth)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .overlay(alignment: .top) { GuideRule(axis: .horizontal) }
        }
        .buttonStyle(.plain)
    }
}

/// 番組の欄の吹き出しの中身。文字は番組の欄より大きく、色は副次の灰色を使わずに読みやすくする
private struct ProgramDetail: View {
    let event: BroadcastEvent

    var body: some View {
        VStack(alignment: .leading, spacing: GuidePopover.spacing) {
            Text(ProgramDisplay.timeRange(event))
                .scaledFont(.body, monospacedDigit: true)
            Text(event.title)
                .scaledFont(.title3, weight: .bold)
            if !event.text.isEmpty {
                Text(event.text)
                    .scaledFont(.body)
            }
        }
        .foregroundStyle(.primary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: GuidePopover.width, alignment: .leading)
        .padding(GuidePopover.padding)
        // 吹き出しの既定の背景は半透明で、下の番組の欄の文字が透けて読みにくいので、不透明にする
        .presentationBackground(Color.windowBackground)
    }
}

/// スクロールの外に重ねる時刻の列。横には動かず、縦は送った量だけずらす。局名の行の下で切る。
///
/// 1.0.2 の後に一度、時刻の列を局の列と同じ横の並びの「左に留める見出し」にした。横に送るたびに並び全体（全局の番組の欄）の
/// 配置を計算し直すことになり、横のスクロールだけがもたついたので、スクロールの外へ出した
private struct FloatingRuler<Content: View>: View {
    let scroll: GuideScrollState
    let top: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
            .offset(y: top - scroll.y)
            .frame(width: GuideLayout.rulerWidth, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .allowsHitTesting(false)
    }
}

/// 今の時刻の線。幅を渡さなければ行の幅いっぱい
private struct GuideNowLine: View {
    let width: CGFloat?

    var body: some View {
        Rectangle()
            .fill(.red)
            .frame(width: width, height: 2)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .allowsHitTesting(false)
    }
}

/// 日の境目（朝 4 時）の線。1 時間ごとの区切り線より太く濃く引く
private struct GuideDayBoundary: View {
    var body: some View {
        Rectangle()
            .fill(GuideLayout.dayBoundaryColor)
            .frame(height: GuideLayout.dayBoundaryThickness)
            .allowsHitTesting(false)
    }
}

/// 番組表の区切り線。overlay に `Divider` を置くと向きが定まらず、横線のつもりが列の中央に縦線として出たので、向きを決めて引く
private struct GuideRule: View {
    let axis: Axis

    var body: some View {
        Rectangle()
            .fill(Color.separatorLine)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}

/// 番組表から予約するときに渡すもの（mirne mobile で足した）
/// 予約済みの印
enum GuideScheduleMark {
    /// 赤い録画の印
    static let symbol = "record.circle"
    /// 時刻との間
    static let spacing: CGFloat = 3
}

struct GuideScheduling {
    let service: any ScheduleService
    /// 予約の一覧（主ウィンドウの予約の画面と同じモデル。予約済みの印に使う）
    let schedules: SchedulesModel
    /// 予約を作った（予約の一覧を読み直す）
    let created: () -> Void
}

/// 押した番組（局と番組）
struct GuideProgramSelection: Equatable {
    let station: Channel
    let event: BroadcastEvent
}

/// 番組表のシート（mirne mobile で足した）
enum GuideSheet: Identifiable {
    case program(GuideProgramSelection)
    case creation(ScheduleCreationModel)

    var id: String {
        switch self {
        case .program(let selection): "program-\(selection.station.scheduleKey)-\(selection.event.eventID)"
        case .creation(let model): "creation-\(ObjectIdentifier(model).hashValue)"
        }
    }
}

/// 番組を押したときの詳細（吹き出しではなく、矢印の無いシート。「閉じる」と Esc で閉じる。
/// 2026-11-19。吹き出しは外を押すと閉じ、マウスを動かすと消えて「録画予約」を押しにくかった）
private struct ProgramSheet: View {
    let selection: GuideProgramSelection
    /// 「録画予約」（予約できない画面では nil）
    let reserve: (() -> Void)?
    /// 「視聴」（ライブで見る口が無ければ nil。放送中の番組だけに出す）
    let watch: (() -> Void)?
    /// その局をライブで見られるか
    let watchAvailability: LiveAvailability
    let close: () -> Void

    private var event: BroadcastEvent { selection.event }
    /// 終わった番組には「録画予約」を出さない。放送中は出す（torne mobile HB と同じ）
    private var reservable: Bool { (event.end ?? .distantPast) > Date() }
    /// 放送中か（「視聴」を出す）
    private var onAir: Bool {
        let now = Date()
        return (event.start ?? .distantFuture) <= now && now < (event.end ?? .distantPast)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 閉じる：iPad は左上の ×、macOS は下の「閉じる」
            if SheetCloseLayout.closesAtTop { SheetTopCloseBar(close: close) }
            ScrollView {
                VStack(alignment: .leading, spacing: GuidePopover.spacing) {
                    Text(selection.station.serviceName)
                        .scaledFont(.body)
                        .foregroundStyle(.secondary)
                    Text(ProgramDisplay.timeRange(event))
                        .scaledFont(.body, monospacedDigit: true)
                    Text(event.title)
                        .scaledFont(.title3, weight: .bold)
                        .textSelection(.enabled)
                    if !event.text.isEmpty {
                        Text(event.text)
                            .scaledFont(.body)
                            .textSelection(.enabled)
                    }
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(GuidePopover.padding)
            }
            // 高さは中身に合わせ、概要が長いときだけ決めた高さで送る（前は枠を最大の高さまで広げていて、
            // iPad では中身の上下に大きな空きが残った。2026-11-22）
            .scrollFitsContentHeight(maxHeight: GuideProgramSheetLayout.maxScrollHeight)
            if hasBottomButtons {
                Divider()
                bottomButtons
            }
        }
        // シートの幅（macOS は決めた幅、iPad は OS の決めるシートの幅いっぱい）
        .sheetContentWidth(GuideProgramSheetLayout.width)
        .sheetFitsContentHeight()
    }

    /// 下の帯にボタンがあるか（iPad は「閉じる」を左上へ出すので、「ライブで見る」「録画予約…」が無ければ帯を出さない）
    private var hasBottomButtons: Bool {
        !SheetCloseLayout.closesAtTop || (watch != nil && onAir) || (reserve != nil && reservable)
    }

    private var bottomButtons: some View {
        HStack {
            Spacer()
            if !SheetCloseLayout.closesAtTop {
                Button("閉じる", action: close)
                    .keyboardShortcut(.cancelAction)
            }
            if let watch, onAir {
                Button(action: watch) { Label("ライブで見る", systemImage: LiveSymbol.watch) }
                    .disabled(watchAvailability.isUnavailable)
                    .help(GuideLive.help(watchAvailability))
            }
            if let reserve, reservable {
                Button(action: reserve) { Label("録画予約…", systemImage: "record.circle") }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }
}

/// 番組の詳細のシートの寸法
private enum GuideProgramSheetLayout {
    /// 幅（macOS。iPad はシートの幅いっぱい）
    static let width: CGFloat = 440
    /// 番組の情報（局名・時刻・番組名・概要）の欄の高さの上限。概要が長いときはこの高さで送る
    static let maxScrollHeight: CGFloat = 460
}
