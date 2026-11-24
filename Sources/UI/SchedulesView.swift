import SwiftUI

/// 予約の一覧。開始の早い順に並べ、予約を押すと、詳細と画質・繰り返しの変更・削除の予約のシートをじかに出す
/// （2026-11-24。前は一覧に重ねるカードを出し、その「画質を変更」から変更のシートを出していた）。
/// 「マニュアル予約」で時刻を指定した予約を作る。
/// 時刻の変更は出さない：nasne は時刻を指定した予約を 1 件しか持てず、「作ってから消す」が必ず Fault 830 になる
/// （2026-11-20 実機）
struct SchedulesView: View {
    @State var model: SchedulesModel
    /// nasne に届くか（つながっていない間は nasne と通信する操作を押せなくする。2026-11-24）
    @Environment(\.nasneLink) private var link
    @Environment(AppEnvironment.self) private var environment
    /// 上の帯に画面の操作も置いているか（そのときは「マニュアル予約」を上の帯に出す）
    @Environment(\.mainTitleBarHasActions) private var titleBarHasActions
    /// 開いているシート（作成・予約のシート。閉じていれば nil）
    @State private var sheet: ScheduleSheet?
    /// 消すかを確かめている予約
    @State private var pendingDeletion: RecordSchedule?
    let scheduleService: any ScheduleService
    /// 予約の録画先を決めるのに HDD の一覧を読む
    let deviceInfo: any DeviceInfoService
    /// 狭い幅の形（「マニュアル予約」は絵だけ）
    @Environment(\.usesCompactLayout) private var compact

    /// マニュアル予約のモデル（録画先は送る直前に HDD の一覧から決める）
    private func creationModel() -> ScheduleCreationModel {
        ScheduleCreationModel(channels: model.channels, service: scheduleService,
                              destination: { [deviceInfo] in await RecordDestination.preferred(from: deviceInfo) })
    }

    var body: some View {
        // 消す前の確かめ。予約のシートを出しているときは、シートの側で出す（下の画面からはシートの上に出せない）
        deletionAlert(screen, isPresented: pendingDeletion != nil && sheet == nil)
    }

    private var screen: some View {
        // 上の帯（番組表と同じ位置）に「マニュアル予約」。帯の下の横線で、左右の仕切りの縦線を止める
        // （仕切りの縦線がツールバーまで突き抜けていた。2026-11-20）
        VStack(spacing: 0) {
            // 上の帯に画面の操作を置くとき（iPhone の縦向き・iPad の狭い分割）は「マニュアル予約」を上の帯の左に出すので、ここには置かない
            ScreenActionBar(status: listStatus, hasLeading: ManualScheduleLabel.isOffered && !titleBarHasActions) {
                if ManualScheduleLabel.isOffered && !titleBarHasActions { newScheduleButton }
            }
            // 一覧は窓の幅いっぱい。予約を押すと予約のシートを出す
            list
        }
        .navigationTitle("予約")
        // 予約を押したら（一覧の選択が変わったら）、予約のシートをじかに出す
        .onChange(of: model.selectedID) {
            guard sheet == nil, let schedule = model.selectedSchedule else { return }
            sheet = .edit(ScheduleEditModel(original: schedule, service: scheduleService))
        }
        // 開くたびに読み直す（古い一覧のまま消すと、もう無い ID に送って何も消えない）。
        // 開いている間の読み直しは MainView が受け持つ（予約の一覧の世代が変わったら。番組表の予約済みの印も同じモデルを使う）
        .task { await model.reload() }
        // メニュー：マニュアル予約…（⌘N）・予約を削除…（⌘⌫）
        .onChange(of: environment.mainCommands.pending, initial: true) {
            let center = environment.mainCommands
            if center.consume(.newSchedule), sheet == nil {
                Task {
                    // 予約の画面を開いた直後は局の一覧をまだ読んでいないので、読み終えてから出す
                    if model.channels.isEmpty { await model.reload() }
                    if !model.channels.isEmpty, sheet == nil {
                        sheet = .create(creationModel())
                    }
                }
            }
            if center.consume(.deleteSchedule), let schedule = model.selectedSchedule { pendingDeletion = schedule }
        }
        // 予約のシートを閉じたら（スワイプで閉じたときも）選択を外す（次に同じ予約を押してもシートが出るように）
        .sheet(item: $sheet, onDismiss: { model.selectedID = nil }) { sheet in
            switch sheet {
            case .create(let creation):
                // 作った予約は選ばない（選ぶと予約のシートが開くため。2026-11-24 に、予約を押すとシートを出す形にした）
                ScheduleCreationView(model: creation, channelName: model.channelName) { _ in
                    self.sheet = nil
                    Task { await model.reload() }
                }
            case .edit(let edit):
                deletionAlert(
                    ScheduleEditView(model: edit, channelName: model.channelName(edit.original.channel),
                                     timing: ScheduleTiming(edit.original, now: Date()),
                                     delete: { pendingDeletion = edit.original }) {
                        self.sheet = nil
                        model.selectedID = nil
                        Task { await model.reload() }
                    },
                    isPresented: pendingDeletion != nil)
            }
        }
    }

    /// 消す前の確かめ（文は 2026-11-19 に）。閉じたときの Binding の set では何もしない
    private func deletionAlert<Content: View>(_ content: Content, isPresented: Bool) -> some View {
        content.alert("この予約を削除しますか？", isPresented: Binding(get: { isPresented }, set: { _ in })) {
            Button("削除", role: .destructive) {
                guard let schedule = pendingDeletion else { return }
                pendingDeletion = nil
                // 予約のシートから消したときは、シートも閉じる
                sheet = nil
                model.selectedID = nil
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

    /// 「マニュアル予約」で時刻を指定した予約を作る。文字付きで置く（ツールバーの絵だけのボタンは分かりにくかった。
    /// 2026-11-21。一覧の上の帯から画面の上の帯へ移した。2026-11-24 に「新規予約」と ＋ から改めた：番組の予約と取り違えやすかった）
    private var newScheduleButton: some View {
        Button {
            sheet = .create(creationModel())
        } label: { Label(ManualScheduleLabel.title, systemImage: ManualScheduleLabel.symbol) }
            // 狭い幅では絵だけ（2026-11-23）
            .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
            // iOS はほかの帯のボタンと同じ丸い板（OS ごと。2026-11-24）
            .barButtonChrome()
            .disabled(model.channels.isEmpty || link != .online)
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
                    .tag(schedule.id)
            }
            .compactListTopMargin()
            .overlay {
                if sorted.isEmpty { ContentUnavailableView("予約はありません", systemImage: "calendar") }
            }
        }
    }

    /// 帯の右に出す件数（読めていなければ出さない。録画の件数と同じ形・同じ場所。2026-11-24 から。前は一覧の下端の帯）
    private var listStatus: String? {
        guard case .loaded = model.schedules else { return nil }
        return "\(model.sortedSchedules.count) 件"
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
                // 繰り返しの予約は名前の札（一回録画は出さない。2026-11-24）
                if let repeatText = ScheduleRepeatText.badge(schedule) { Badge(text: repeatText, tint: .accentColor) }
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
        ScheduleSheetFrame(
            title: model.program == nil ? ManualScheduleLabel.title : "番組を予約",
            confirm: ScheduleSheetConfirm(title: "予約する", disabled: model.draft == nil || model.phase.isBusy, action: submit),
            cancelTitle: "キャンセル", cancel: { finish(nil) },
            status: model.validationMessage
                ?? (model.phase.isBusy ? (model.phase == .checking ? "重なる予約を確かめています…" : "予約しています…") : nil),
            isBusy: model.phase.isBusy
        ) {
            Group {
                if let program = model.program {
                    programSection(program)
                } else {
                    manualSection
                }
            }
            .disabled(model.phase.isBusy)

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
        // シートの幅（macOS は決めた幅、iPad は OS の決めるシートの幅いっぱい）
        .sheetContentWidth(ScheduleSheetLayout.width)
        .scheduleSheetSizing()
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
                    // 欄の名前は出さない（macOS のフォームでは欄の名前が「長さ」の右にもう一度、折り返して出た。2026-11-24）
                    TextField("長さ", value: $model.durationMinutes, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                    Text("分")
                }
            }
            LabeledContent("終了", value: model.end.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute()))
            qualityPicker
        } header: {
            if !SheetActionLayout.usesNavigationBar { Text(ManualScheduleLabel.title) }
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
            ScheduleRepeatPicker(selection: $model.repeatMode, choices: model.repeatChoices)
        } header: {
            if !SheetActionLayout.usesNavigationBar { Text("番組を予約") }
        } footer: {
            Text(model.repeatMode == .once
                 ? "番組の予約は、nasne が開始と長さを番組に合わせます。録画が始まると録画一覧に載り、終わると予約の一覧から消えます。"
                 : ScheduleRepeatNote.text)
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
    /// マニュアル予約・時刻の変更
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

/// 予約のシート（2026-11-24 から一覧の予約を押すとじかに出す。前はカードを出し、その「画質を変更」から出していた）。
/// 詳細と、始まる前の予約なら画質と繰り返しの変更。左下に削除。送った後は読み直した値を出し、変わらなかったらそのことを出す
struct ScheduleEditView: View {
    @State var model: ScheduleEditModel
    let channelName: String
    let timing: ScheduleTiming
    /// 削除（押すと確かめのアラートを出す。シートの側で出す）
    let delete: () -> Void
    let finish: () -> Void
    /// nasne に届くか（つながっていない間は変更も削除もさせない）
    @Environment(\.nasneLink) private var link

    /// 画質・繰り返しを変えられるか（始まる前の予約で、つながっているとき）
    private var editable: Bool { timing == .upcoming && link == .online }

    var body: some View {
        ScheduleSheetFrame(
            title: editable ? "予約を変更" : "予約",
            confirm: editable && !isFinished
                ? ScheduleSheetConfirm(title: "変更する", disabled: !model.hasChange || model.phase == .sending, action: submit) : nil,
            cancelTitle: editable && !isFinished ? "キャンセル" : "閉じる", cancel: finish,
            delete: isFinished ? nil : delete, deleteDisabled: model.phase == .sending || link != .online,
            status: model.phase == .sending ? "変更しています…" : nil,
            isBusy: model.phase == .sending
        ) {
            Section {
                Text(ScheduleText.title(model.original)).scaledFont(.headline)
                LabeledContent("局", value: channelName)
                LabeledContent("時刻", value: ScheduleText.timeRange(model.original))
                if let duration = RecordingFormat.duration(model.original.durationSeconds) { LabeledContent("長さ", value: duration) }
                LabeledContent("予約の種類", value: model.original.isLinkedToProgram ? "番組の予約" : "時刻を指定した予約")
                switch timing {
                case .recording: LabeledContent("状態", value: "録画中")
                case .ended: LabeledContent("状態", value: "終了")
                case .upcoming: EmptyView()
                }
                if editable {
                    Picker("画質", selection: $model.qualityMode) {
                        Text(QualityMode.label(QualityMode.dr)).tag(QualityMode.dr)
                        Text(QualityMode.label(QualityMode.threeTimes)).tag(QualityMode.threeTimes)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.phase != .editing)
                } else {
                    LabeledContent("画質", value: QualityMode.label(model.original.desiredQualityMode))
                }
                // 繰り返し（変えられるのは番組に紐付いた予約で、今の値が読めるときだけ。2026-11-24）
                if editable && model.offersRepeatChange {
                    ScheduleRepeatPicker(selection: $model.repeatMode, choices: model.repeatChoices)
                        .disabled(model.phase != .editing)
                } else if let repeatText = ScheduleRepeatText.badge(model.original) {
                    LabeledContent("繰り返し", value: repeatText)
                }
            } header: {
                if !SheetActionLayout.usesNavigationBar { Text(editable ? "予約を変更" : "予約") }
            } footer: {
                // 終わった手動の予約は nasne の一覧に残り、残っている間はほかの手動の予約を作れない（Fault 830）
                if timing == .ended && !model.original.isLinkedToProgram {
                    Text("時刻を指定した予約は、終わっても nasne の一覧に残ります。残っている間は、ほかの時刻を指定した予約を作れません。")
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
            switch model.phase {
            case .finished(reflected: false):
                Section {
                    Text("nasne は受け付けましたが、変更が反映されませんでした。")
                    if let reread = model.reread {
                        LabeledContent("読み直した画質", value: QualityMode.label(reread.desiredQualityMode))
                        if model.offersRepeatChange {
                            LabeledContent("読み直した繰り返し",
                                           value: reread.repeatMode.map(ScheduleRepeatText.label) ?? reread.conditionID)
                        }
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
        // シートの幅（macOS は決めた幅、iPad は OS の決めるシートの幅いっぱい）
        .sheetContentWidth(ScheduleSheetLayout.width)
        .scheduleSheetSizing()
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

    /// 「変更する」
    private func submit() {
        model.dismissFailure()
        Task { await model.submit() }
    }
}

/// 繰り返しの選択（公式の torne® mobile と同じ 5 つ。番組表からの予約と、予約の変更のシートで使う）
struct ScheduleRepeatPicker: View {
    @Binding var selection: ScheduleRepeat
    let choices: [ScheduleRepeat]

    var body: some View {
        Picker("繰り返し", selection: $selection) {
            ForEach(choices, id: \.self) { choice in
                Text(ScheduleRepeatText.label(choice)).tag(choice)
            }
        }
        .pickerStyle(.menu)
    }
}

/// 繰り返しの予約の説明（予約のシートの下に出す）
enum ScheduleRepeatNote {
    static let text = "繰り返しの予約は、録画が終わると nasne が次の回の番組を探して、同じ予約を書き換えます。番組名などで探すので、番組名が大きく変わった回や放送の無い回は見つからないことがあります。"
}

/// 時刻を指定した予約の入口の名前と絵（帯・メニュー・シートで同じものを使う。2026-11-24 に「新規予約」と ＋ から改めた）
enum ManualScheduleLabel {
    /// マニュアル予約の入口を出すか。2026-11-24 に Buffalo 製で測ると、マニュアル予約（eventId 0）は録画しても録画の一覧・Browse・
    /// 公式のアプリのどれにも何も出ず、HDD の空きも減らなかった（終わった項目が残っている間は次のマニュアル予約も作れない）ので、
    /// 入口（帯・メニュー・上の帯）を出さない。作りは残し、録画できる作り方が分かったら戻す
    static let isOffered = false
    static let title = "マニュアル予約"
    /// 目覚まし時計（時刻を決めて録る。予約のタブの絵〔カレンダー〕とも、番組表の予約とも似ないもの）
    static let symbol = "alarm"
}

/// 予約のシートの確定のボタン
struct ScheduleSheetConfirm {
    let title: String
    let disabled: Bool
    let action: () -> Void
}

/// 予約のシートの器（番組表からの予約・マニュアル予約・予約のシートで同じ形。2026-11-24）。
/// macOS は下の帯（左に削除・右に「キャンセル」と確定）。iOS は iOS の標準の形：上のナビゲーションの帯の左に「キャンセル」・右に確定、
/// 削除は中身のいちばん下の赤い行（カレンダーの予定と同じ）。中身は狭い幅（iPhone）ではスクロールする
struct ScheduleSheetFrame<Content: View>: View {
    let title: String
    /// 確定のボタン（無ければ「閉じる」だけ）
    var confirm: ScheduleSheetConfirm?
    let cancelTitle: String
    let cancel: () -> Void
    /// 削除（無ければ出さない。押すと確かめのアラートを出す）
    var delete: (() -> Void)?
    var deleteDisabled = false
    /// 状態の文（入力の誤り・送っている途中）
    var status: String?
    var isBusy = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        if SheetActionLayout.usesNavigationBar {
            NavigationStack {
                form
                    .navigationTitle(title)
                    .inlineNavigationTitle()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(cancelTitle, role: .cancel, action: cancel).disabled(isBusy && confirm != nil)
                        }
                        if let confirm {
                            ToolbarItem(placement: .confirmationAction) {
                                if isBusy {
                                    ProgressView()
                                } else {
                                    Button(confirm.title, action: confirm.action).disabled(confirm.disabled)
                                }
                            }
                        }
                    }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                form
                HStack {
                    if let delete {
                        Button(role: .destructive, action: delete) { Image(systemName: CardDeleteSymbol.name) }
                            .accessibilityLabel("削除…")
                            .help("この予約を削除する")
                            .disabled(deleteDisabled)
                    }
                    if isBusy { ProgressView().controlSize(.small) }
                    if let status { Text(status).scaledFont(.callout).foregroundStyle(isBusy ? .primary : .secondary) }
                    Spacer()
                    Button(cancelTitle, role: .cancel, action: cancel)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isBusy && confirm != nil)
                    if let confirm {
                        Button(confirm.title, action: confirm.action)
                            .keyboardShortcut(.defaultAction)
                            .disabled(confirm.disabled)
                    }
                }
                .padding()
            }
        }
    }

    private var form: some View {
        Form {
            content()
            if SheetActionLayout.usesNavigationBar {
                // 状態の文（入力の誤り・送っている途中）は中身の下に出す（上の帯には入らない）
                if let status {
                    Section { Text(status).scaledFont(.callout).foregroundStyle(.secondary) }
                }
                if let delete {
                    Section {
                        Button(role: .destructive, action: delete) {
                            Text("予約を削除").frame(maxWidth: .infinity)
                        }
                        .disabled(deleteDisabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scheduleSheetFormHeight()
    }
}
