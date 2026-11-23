import SwiftUI

/// 予約の一覧。開始の早い順に並べ、選んだ予約の詳細と画質の変更・削除のボタンは、
/// 一覧の右寄りに選んだ行の高さで重ねるカードに出す（録画の画面と同じ `SelectionCardOverlay`）。
/// 「新規予約」で手動の予約を作る。
/// 時刻の変更は出さない：nasne は時刻を指定した予約を 1 件しか持てず、「作ってから消す」が必ず Fault 830 になる
/// （2026-11-20 実機）
struct SchedulesView: View {
    @State var model: SchedulesModel
    @Environment(AppEnvironment.self) private var environment
    /// 上の帯に画面の操作も置いているか（そのときは「新規予約」を上の帯に出す）
    @Environment(\.mainTitleBarHasActions) private var titleBarHasActions
    /// 開いているシート（作成・画質の変更。閉じていれば nil）
    @State private var sheet: ScheduleSheet?
    /// 消すかを確かめている予約
    @State private var pendingDeletion: RecordSchedule?
    /// 見えている行の枠（カードを選んだ行の高さに置くため）
    @State private var rowFrames = ListRowFrames<String>()
    let scheduleService: any ScheduleService
    /// 狭い幅の形（「新規予約」は絵だけ・カードはシート）
    @Environment(\.usesCompactLayout) private var compact
    /// カードのシートを閉じ終えてからすること（画質の変更のシートは、カードのシートを出している間は出せない）
    @State private var afterCardSheet: (() -> Void)?

    var body: some View {
        // 消す前の確かめ。カードのシートを出しているときは、シートの側で出す（下の画面からはシートの上に出せない）
        deletionAlert(screen, isPresented: pendingDeletion != nil && !showsCardSheet)
    }

    private var screen: some View {
        // 上の帯（番組表と同じ位置）に「＋ 新規予約」。帯の下の横線で、左右の仕切りの縦線を止める
        // （仕切りの縦線がツールバーまで突き抜けていた。2026-11-20）
        VStack(spacing: 0) {
            // 上の帯に画面の操作を置くとき（iPhone の縦向き・iPad の狭い分割）は「新規予約」を上の帯の左に出すので、ここには置かない
            ScreenActionBar(hasLeading: !titleBarHasActions) {
                if !titleBarHasActions { newScheduleButton }
            }
            // 一覧は窓の幅いっぱい。選んだ予約の詳細は一覧に重ねるカードに出す（2026-11-22。前は右に区切った詳細の欄。録画の画面と同じ）
            list
                .overlay {
                    if !compact { SelectionCardOverlay(id: model.selectedID, rows: rowFrames) { _ in card } }
                }
        }
        .navigationTitle("予約")
        // 狭い幅では、選んだ予約のカードを下からのシートで出す
        .selectionCardSheet(isPresented: showsCardSheet, close: { model.selectedID = nil }, onDismiss: runAfterCardSheet) {
            deletionAlert(card, isPresented: pendingDeletion != nil)
        }
        // 開くたびに読み直す（古い一覧のまま消すと、もう無い ID に送って何も消えない）。
        // 開いている間の読み直しは MainView が受け持つ（予約の一覧の世代が変わったら。番組表の予約済みの印も同じモデルを使う）
        .task { await model.reload() }
        // メニュー：新しい予約…（⌘N）・予約を削除…（⌘⌫）
        .onChange(of: environment.mainCommands.pending, initial: true) {
            let center = environment.mainCommands
            if center.consume(.newSchedule), sheet == nil {
                Task {
                    // 予約の画面を開いた直後は局の一覧をまだ読んでいないので、読み終えてから出す
                    if model.channels.isEmpty { await model.reload() }
                    if !model.channels.isEmpty, sheet == nil {
                        sheet = .create(ScheduleCreationModel(channels: model.channels, service: scheduleService))
                    }
                }
            }
            if center.consume(.deleteSchedule), let schedule = model.selectedSchedule { pendingDeletion = schedule }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .create(let creation):
                ScheduleCreationView(model: creation, channelName: model.channelName) { createdID in
                    self.sheet = nil
                    Task {
                        await model.reload()
                        if let createdID { model.selectedID = createdID }
                    }
                }
            case .edit(let edit):
                ScheduleEditView(model: edit) {
                    self.sheet = nil
                    Task { await model.reload() }
                }
            }
        }
    }

    /// カードをシートで出すか（狭い幅で、予約を選んでいるとき）
    private var showsCardSheet: Bool { compact && model.selectedSchedule != nil }

    /// カードのシートを閉じ終えたら、預けていた操作をする
    private func runAfterCardSheet() {
        let action = afterCardSheet
        afterCardSheet = nil
        action?()
    }

    /// 消す前の確かめ（文は 2026-11-19 に）。閉じたときの Binding の set では何もしない
    private func deletionAlert<Content: View>(_ content: Content, isPresented: Bool) -> some View {
        content.alert("この予約を削除しますか？", isPresented: Binding(get: { isPresented }, set: { _ in })) {
            Button("削除", role: .destructive) {
                guard let schedule = pendingDeletion else { return }
                pendingDeletion = nil
                // 消せなかったときは知らせの帯に出す（前はアラート）
                Task {
                    if let error = await model.delete(schedule) {
                        environment.notices.post(.error(id: "schedules.deletion", error, prefix: "予約の削除"))
                    }
                }
            }
            Button("キャンセル", role: .cancel) { pendingDeletion = nil }
        } message: {
            if let schedule = pendingDeletion {
                Text("\(ScheduleText.timeRange(schedule))　\(ScheduleText.title(schedule))\nnasne から予約が消えます。取り消せません。")
            }
        }
    }

    /// 「＋ 新規予約」で時刻を指定した予約を作る。文字付きで置く（ツールバーの絵だけのボタンは分かりにくかった。
    /// 2026-11-21。一覧の上の帯から画面の上の帯へ移した）
    private var newScheduleButton: some View {
        Button {
            sheet = .create(ScheduleCreationModel(channels: model.channels, service: scheduleService))
        } label: { Label("新規予約", systemImage: "plus") }
            // 狭い幅では絵だけ（2026-11-23）
            .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
            // iOS はほかの帯のボタンと同じ丸い板（OS ごと。2026-11-24）
            .barButtonChrome()
            .disabled(model.channels.isEmpty)
            .help(model.channels.isEmpty ? "局の一覧を読み込めていないので、予約を作れません" : "時刻を指定して予約する")
    }

    @ViewBuilder
    private var list: some View {
        switch model.schedules {
        case .idle, .loading, .failed:
            // 読み込み中・読み込めなかったことは知らせの帯に出す（「もう一度読み込む」も帯に）
            Color.clear
        case .loaded:
            let sorted = model.sortedSchedules
            let now = Date()
            List(sorted, id: \.id, selection: $model.selectedID) { schedule in
                ScheduleRow(schedule: schedule, channelName: model.channelName(schedule.channel),
                            timing: ScheduleTiming(schedule, now: now))
                    .reportsRowFrame(schedule.id, into: rowFrames)
                    .tag(schedule.id)
            }
            .compactListTopMargin()
            // カードの外を押したら閉じる（行を押したときは、カードがその行へ移る）。esc でも閉じる（どちらも選択を外す）
            // 狭い幅ではカードはシートなので見張らない（シートの中を押しても閉じてしまう）
            .closesSelectionCardOnOutsideTap(rows: rowFrames, isOpen: model.selectedID != nil && !compact) { model.selectedID = nil }
            .onKeyPress(.escape) {
                guard model.selectedID != nil else { return .ignored }
                model.selectedID = nil
                return .handled
            }
            .overlay {
                if sorted.isEmpty { ContentUnavailableView("予約はありません", systemImage: "calendar") }
            }
            .safeAreaInset(edge: .bottom) {
                Text("\(sorted.count) 件")
                    .scaledFont(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(4).background(.bar)
            }
        }
    }

    /// 選んだ予約のカード
    @ViewBuilder
    private var card: some View {
        if let schedule = model.selectedSchedule {
            let timing = ScheduleTiming(schedule, now: Date())
            ScheduleCard(
                schedule: schedule, channelName: model.channelName(schedule.channel), timing: timing,
                // 画質の変更は始まる前の予約だけ
                editQuality: timing == .upcoming ? { editQuality(schedule) } : nil,
                delete: { pendingDeletion = schedule },
                close: { model.selectedID = nil })
        }
    }

    /// 画質の変更のシートを出す。カードのシートから押したときは、カードのシートを閉じ終えてから出す
    private func editQuality(_ schedule: RecordSchedule) {
        let edit = ScheduleSheet.edit(ScheduleEditModel(original: schedule, service: scheduleService))
        if showsCardSheet {
            afterCardSheet = { sheet = edit }
            model.selectedID = nil
            return
        }
        sheet = edit
    }
}

/// 予約の一覧の上の帯の余白（録画の画面の帯 `RecordingsFilterBarLayout` と揃えた値だが、別の画面の帯なので独立させる）
/// 予約の時刻の表記（一覧と詳細で同じものを使う）
enum ScheduleText {
    /// 「11月20日(木) 21:00〜21:54」。終わりが別の日なら終わりにも日付を付ける
    static func timeRange(_ schedule: RecordSchedule) -> String {
        let start = schedule.start.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute())
        let sameDay = Calendar.current.isDate(schedule.start, inSameDayAs: schedule.end)
        let end = sameDay ? schedule.end.formatted(.dateTime.hour().minute())
                          : schedule.end.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute())
        return "\(start)〜\(end)"
    }

    /// 狭い幅の行の「11/20(木) 21:00〜21:54」。終わりが別の日なら終わりにも日付を付ける
    static func compactTimeRange(_ schedule: RecordSchedule) -> String {
        let sameDay = Calendar.current.isDate(schedule.start, inSameDayAs: schedule.end)
        let end = sameDay ? CompactDateText.time(schedule.end) : CompactDateText.dateTime(schedule.end)
        return "\(CompactDateText.dateTime(schedule.start))〜\(end)"
    }

    static func title(_ schedule: RecordSchedule) -> String {
        guard let title = schedule.title, !title.isEmpty else { return "（番組名なし）" }
        return title
    }
}

/// 一覧の 1 行
struct ScheduleRow: View {
    let schedule: RecordSchedule
    let channelName: String
    let timing: ScheduleTiming
    /// 狭い幅の形（2 行目を短くする）
    @Environment(\.usesCompactLayout) private var compact
    /// 行の頭のロゴ（狭い幅では、ロゴの出る局の局名を省く）
    @Environment(ChannelLogoImages.self) private var logos: ChannelLogoImages?

    var body: some View {
        HStack(spacing: 8) {
            // 左端に局のロゴ（2026-11-22）
            ChannelLogoSlot(key: schedule.channel.logoKey)
            details.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                switch timing {
                case .recording: Badge(text: "録画中", tint: .red)
                case .ended: Badge(text: "終了", tint: .gray)
                case .upcoming: EmptyView()
                }
                Text(ScheduleText.title(schedule)).lineLimit(1)
            }
            HStack(spacing: 8) {
                // 狭い幅では日時を短い形にし、局名は行の頭のロゴで分かるので省く（ロゴの無い局だけ出す。2026-11-23）
                Text(compact ? ScheduleText.compactTimeRange(schedule) : ScheduleText.timeRange(schedule))
                if let duration = RecordingFormat.duration(schedule.durationSeconds) { Text("（\(duration)）") }
                if !(compact && logos?.images[schedule.channel.logoKey] != nil) { Text(channelName).lineLimit(1) }
                Text(QualityMode.label(schedule.desiredQualityMode))
            }
            .scaledFont(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// 予約のカード：詳細と、画質の変更・削除のボタン。録画先（recordDestinationID）は出さない：予約では作り手の望む値で、
/// 別のアプリで作った予約では実際の録画先と食い違うことがある（torne mobile HB と同じ扱い）
struct ScheduleCard: View {
    let schedule: RecordSchedule
    let channelName: String
    let timing: ScheduleTiming
    /// 画質の変更（出さないときは nil）
    var editQuality: (() -> Void)?
    /// 削除
    var delete: (() -> Void)?
    let close: () -> Void

    var body: some View {
        SelectionCardContent(title: ScheduleText.title(schedule), close: close) {
            VStack(alignment: .leading, spacing: 4) {
                SelectionCardField("局", value: channelName)
                SelectionCardField("開始", value: schedule.start.formatted(date: .abbreviated, time: .shortened))
                SelectionCardField("終了", value: schedule.end.formatted(date: .abbreviated, time: .shortened))
                if let duration = RecordingFormat.duration(schedule.durationSeconds) { SelectionCardField("長さ", value: duration) }
                SelectionCardField("画質", value: QualityMode.label(schedule.desiredQualityMode))
                SelectionCardField("予約の種類", value: schedule.isLinkedToProgram ? "番組の予約" : "時刻を指定した予約")
                switch timing {
                case .recording: SelectionCardField("状態", value: "録画中")
                case .ended: SelectionCardField("状態", value: "終了")
                case .upcoming: EmptyView()
                }
            }
            // 終わった手動の予約は nasne の一覧に残り、残っている間はほかの手動の予約を作れない（Fault 830）
            if timing == .ended && !schedule.isLinkedToProgram {
                Text("時刻を指定した予約は、終わっても nasne の一覧に残ります。残っている間は、ほかの時刻を指定した予約を作れません。")
                    .scaledFont(.callout).foregroundStyle(.secondary)
            }
        } actions: {
            if editQuality != nil || delete != nil {
                HStack {
                    if let editQuality { Button("画質を変更", action: editQuality).buttonStyle(.bordered) }
                    Spacer(minLength: 0)
                    if let delete {
                        Button(role: .destructive, action: delete) {
                            // ゴミ箱の絵だけ（録画のカードと同じ。2026-11-23。どの OS も）
                            Image(systemName: CardDeleteSymbol.name)
                        }
                        .accessibilityLabel("削除…")
                        .buttonStyle(.bordered)
                        .help("この予約を削除する")
                    }
                }
            }
        }
    }
}

extension ScheduleCreationModel: Identifiable {
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

/// 手動の予約の作成。重なる予約があれば一覧を見せて続けるかを聞く。作ったら `finish` に ID を渡す
/// （閉じただけなら nil。作られたか分からないまま閉じたときも nil で、一覧を読み直す）
struct ScheduleCreationView: View {
    @State var model: ScheduleCreationModel
    let channelName: (ScheduleChannel) -> String
    let finish: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                if let program = model.program {
                    programSection(program)
                } else {
                    manualSection
                }

                if case .failed(let error, let mayHaveCreated) = model.phase {
                    Section {
                        ErrorBanner(error: error)
                        if mayHaveCreated {
                            Text("nasne に届いて、予約が作られていることがあります。閉じて予約の一覧を確かめてから、作り直してください。")
                                .scaledFont(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .formFitsContentHeight()
            .disabled(model.phase.isBusy)
            // 下の帯：macOS は右に「キャンセル」「予約する」、iPad は左端に「キャンセル」・右端に「予約する」（太字）（2026-11-22。
            // 上の帯の左右に置く形を試したが下に戻し、並びだけ上の帯のときの左右にした）
            HStack {
                if SheetActionLayout.splitsCancelAndConfirm { cancelButton }
                if let message = model.validationMessage {
                    Text(message).scaledFont(.callout).foregroundStyle(.secondary)
                } else if model.phase.isBusy {
                    ProgressView().controlSize(.small)
                    Text(model.phase == .checking ? "重なる予約を確かめています…" : "予約しています…").scaledFont(.callout)
                }
                Spacer()
                if !SheetActionLayout.splitsCancelAndConfirm { cancelButton }
                Button(action: submit) {
                    Text("予約する").fontWeight(SheetActionLayout.splitsCancelAndConfirm ? .semibold : nil)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.draft == nil || model.phase.isBusy)
            }
            .padding()
        }
        // シートの幅（macOS は決めた幅、iPad は OS の決めるシートの幅いっぱい）
        .sheetContentWidth(ScheduleSheetLayout.width)
        .sheetFitsContentHeight()
        .alert("重なる予約があります", isPresented: conflictsShown) {
            Button("予約する") { Task { await model.confirmConflicts() } }
            Button("やめる", role: .cancel) { model.cancelConflicts() }
        } message: {
            Text(conflictText)
        }
        .onChange(of: model.phase) {
            if case .created(let id) = model.phase { finish(id) }
        }
    }

    private var cancelButton: some View {
        Button("キャンセル", role: .cancel) { finish(nil) }
            .keyboardShortcut(.cancelAction)
            .disabled(model.phase.isBusy)
    }

    /// 「予約する」
    private func submit() {
        model.dismissFailure()
        Task { await model.submit() }
    }

    /// 手動の予約の入力（局・開始・長さ・画質）
    private var manualSection: some View {
        Section {
            Picker("局", selection: $model.channelKey) {
                ForEach(model.channels, id: \.scheduleKey) { channel in
                    Text(channel.remoteControlKey.map { "\($0)  \(channel.serviceName)" } ?? channel.serviceName)
                        .tag(Optional(channel.scheduleKey))
                }
            }
            DatePicker("開始", selection: $model.start, displayedComponents: [.date, .hourAndMinute])
            Stepper(value: $model.durationMinutes, in: 1...ScheduleCreationLimits.maximumMinutes) {
                LabeledContent("長さ") {
                    TextField("長さ", value: $model.durationMinutes, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                    Text("分")
                }
            }
            LabeledContent("終了", value: model.end.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute()))
            qualityPicker
        } header: {
            Text("新規予約")
        } footer: {
            Text("時刻を指定した予約は、nasne に 1 件しか置けません。録画されても録画一覧に載らず、終わった後も nasne の予約の一覧に残ります。")
                .scaledFont(.caption).foregroundStyle(.secondary)
        }
    }

    /// 番組表からの予約（局・時刻は番組のもの。画質だけ選ぶ）
    private func programSection(_ program: ScheduleProgram) -> some View {
        Section {
            Text(program.title.isEmpty ? "（番組名なし）" : program.title).scaledFont(.headline)
            LabeledContent("局", value: program.channel.serviceName)
            LabeledContent("放送", value: "\(program.start.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute()))〜\(program.end.formatted(.dateTime.hour().minute()))")
            if let duration = RecordingFormat.duration(program.durationSeconds) { LabeledContent("長さ", value: duration) }
            qualityPicker
        } header: {
            Text("番組を予約")
        } footer: {
            Text("番組の予約は、nasne が開始と長さを番組に合わせます。録画が始まると録画一覧に載り、終わると予約の一覧から消えます。")
                .scaledFont(.caption).foregroundStyle(.secondary)
        }
    }

    private var qualityPicker: some View {
        Picker("画質", selection: $model.qualityMode) {
            Text(QualityMode.label(QualityMode.dr)).tag(QualityMode.dr)
            Text(QualityMode.label(QualityMode.threeTimes)).tag(QualityMode.threeTimes)
        }
        .pickerStyle(.segmented)
    }

    private var conflictsShown: Binding<Bool> {
        Binding(get: {
            if case .confirmingConflicts = model.phase { return true }
            return false
        }, set: { _ in
            // 閉じたときは何もしない。SwiftUI はボタンの動作の後で false を書くので、ここで取り消すと
            // 「予約する」の Task が始まる前に入力へ戻ってしまう。
            // 取り消しは「やめる」（Esc も同じ）が受け持つ
        })
    }

    /// 重なる予約の一覧（日時と時刻・局・番組名）
    private var conflictText: String {
        guard case .confirmingConflicts(let conflicts) = model.phase else { return "" }
        let lines = conflicts.map { "\(ScheduleText.timeRange($0))  \(channelName($0.channel))  \(ScheduleText.title($0))" }
        return lines.joined(separator: "\n") + "\n\n続けて予約しますか？"
    }
}

/// 予約のシート（作成・画質の変更）の寸法
enum ScheduleSheetLayout {
    /// 幅（macOS。iPad はシートの幅いっぱい）
    static let width: CGFloat = 440
}

/// 作成の入力の上限（入力の歯止め。nasne の上限は分かっていない）
enum ScheduleCreationLimits {
    /// 長さの上限（24 時間）
    static let maximumMinutes = 24 * 60
}

/// 予約の画面のシート
enum ScheduleSheet: Identifiable {
    /// 新規予約・時刻の変更
    case create(ScheduleCreationModel)
    /// 画質の変更
    case edit(ScheduleEditModel)

    var id: ObjectIdentifier {
        switch self {
        case .create(let model): ObjectIdentifier(model)
        case .edit(let model): ObjectIdentifier(model)
        }
    }
}

/// 画質の変更。送った後は読み直した値を出し、変わらなかったらそのことを出す（文は）
struct ScheduleEditView: View {
    @State var model: ScheduleEditModel
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Text(ScheduleText.title(model.original)).scaledFont(.headline)
                    LabeledContent("時刻", value: ScheduleText.timeRange(model.original))
                    LabeledContent("今の画質", value: QualityMode.label(model.original.desiredQualityMode))
                    Picker("画質", selection: $model.qualityMode) {
                        Text(QualityMode.label(QualityMode.dr)).tag(QualityMode.dr)
                        Text(QualityMode.label(QualityMode.threeTimes)).tag(QualityMode.threeTimes)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.phase != .editing)
                } header: {
                    Text("画質を変更")
                }
                switch model.phase {
                case .finished(reflected: false):
                    Section {
                        Text("nasne は受け付けましたが、画質は変わりませんでした。")
                        if let reread = model.reread {
                            LabeledContent("読み直した画質", value: QualityMode.label(reread.desiredQualityMode))
                        }
                    }
                case .missing:
                    Section { Text("読み直したら、この予約は nasne の一覧にありませんでした。") }
                case .failed(let error, let mayHaveChanged):
                    Section {
                        ErrorBanner(error: error)
                        if mayHaveChanged {
                            Text("nasne に届いて、変わっていることがあります。閉じて予約の一覧を確かめてください。")
                                .scaledFont(.callout).foregroundStyle(.secondary)
                        }
                    }
                default:
                    EmptyView()
                }
            }
            .formStyle(.grouped)
            .formFitsContentHeight()
            HStack {
                if SheetActionLayout.splitsCancelAndConfirm, !isFinished { cancelButton }
                if model.phase == .sending {
                    ProgressView().controlSize(.small)
                    Text("変更しています…").scaledFont(.callout)
                }
                Spacer()
                // ボタンは下の帯（並びは作るシートと同じ。iPad は「キャンセル」を左端へ）
                switch model.phase {
                case .finished, .missing:
                    Button("閉じる", action: finish).keyboardShortcut(.defaultAction)
                default:
                    if !SheetActionLayout.splitsCancelAndConfirm { cancelButton }
                    Button(action: submit) {
                        Text("変更する").fontWeight(SheetActionLayout.splitsCancelAndConfirm ? .semibold : nil)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasChange || model.phase == .sending)
                }
            }
            .padding()
        }
        // シートの幅（macOS は決めた幅、iPad は OS の決めるシートの幅いっぱい）
        .sheetContentWidth(ScheduleSheetLayout.width)
        .sheetFitsContentHeight()
        // 変わったときは、そのまま閉じて一覧を読み直す
        .onChange(of: model.phase) {
            if model.phase == .finished(reflected: true) { finish() }
        }
    }

    /// 変え終わった（または予約が無くなった）か（ボタンは「閉じる」だけになる）
    private var isFinished: Bool {
        switch model.phase {
        case .finished, .missing: true
        default: false
        }
    }

    private var cancelButton: some View {
        Button("キャンセル", role: .cancel, action: finish)
            .keyboardShortcut(.cancelAction)
            .disabled(model.phase == .sending)
    }

    /// 「変更する」
    private func submit() {
        model.dismissFailure()
        Task { await model.submit() }
    }
}
