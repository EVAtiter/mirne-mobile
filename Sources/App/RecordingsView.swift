import SwiftUI

/// 録画一覧と詳細。左に一覧、右に選んだ録画の詳細。
/// 一覧の下の欄に、選んだ録画の再生のボタンと一覧の状態を出す。行のダブルクリック・Return で最初のボタンと同じ再生
struct RecordingsView: View {
    @State var model: RecordingsModel
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    /// 開いているまとめ（まとめの名前）
    @State private var expandedGroups: Set<String> = []
    /// 消す前の確かめを出している録画
    @State private var pendingDeletion: RecordedTitle?

    var body: some View {
        // 上の帯（番組表と同じ位置）に検索・絞り込み・並べ替えと「更新」。帯の下の横線で、左右の仕切りの縦線を止める
        // （仕切りの縦線がツールバーまで突き抜けていた。2026-11-20）
        VStack(spacing: 0) {
            ScreenActionBar(refreshHelp: "録画の一覧を更新する（⌘R）", isRefreshing: model.isRefreshing,
                            refresh: { Task { await model.reload() } }, status: listStatus) {
                RecordingsFilterBar(model: model)
            }
            // 詳細の欄は固定の幅にし、一覧が残りの幅を使う（2026-11-21。前は左右の仕切り〔HSplitView〕で幅を変えられた）
            HStack(spacing: 0) {
                list
                    .frame(minWidth: DetailPaneLayout.listMinimumWidth, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                detail
                    .frame(width: DetailPaneLayout.width)
                    .frame(maxHeight: .infinity)
            }
        }
        .navigationTitle("録画")
        // 検索・視聴の状態・まとめる・並べ替えと「更新」は上の帯（ツールバーから一覧の上へ、のちに画面の上の帯へ移した）
        .task { if model.titles == .idle { await model.reload() } }
        // メニュー：録画を削除…（⌘⌫。選んだ録画で確かめを出す）・更新（⌘R）
        .onChange(of: environment.mainCommands.pending, initial: true) {
            let center = environment.mainCommands
            if center.consume(.deleteRecording), let title = model.selectedTitle, model.deletionBlocker(title) == nil {
                pendingDeletion = title
            }
            if center.consume(.refresh) { Task { await model.reload() } }
        }
        // 消す前の確かめ（文は予約の削除〔2026-11-19 に〕に揃えた）。閉じたときの Binding の set では何もしない
        .alert("この録画を削除しますか？", isPresented: Binding(get: { pendingDeletion != nil }, set: { _ in })) {
            Button("削除", role: .destructive) {
                guard let title = pendingDeletion else { return }
                pendingDeletion = nil
                environment.stopIfPlaying(titleID: title.id)
                // 消せなかったときは知らせの帯に出す（前はアラート）
                Task {
                    if let error = await model.delete(title) {
                        environment.notices.post(.error(id: "recordings.deletion", error, prefix: "録画の削除"))
                    }
                }
            }
            Button("キャンセル", role: .cancel) { pendingDeletion = nil }
        } message: {
            if let title = pendingDeletion {
                Text((title.displayStart.map { $0.formatted(date: .abbreviated, time: .shortened) + "　" } ?? "")
                     + title.title + "\nnasne から録画が消えます。取り消せません。")
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        switch model.titles {
        case .idle, .loading, .failed:
            // 読み込み中・読み込めなかったことは知らせの帯に出す
            Color.clear
        case .loaded(let all):
            let visible = model.visibleTitles
            List(selection: $model.selectedID) {
                if model.groupsByName {
                    ForEach(model.visibleGroups) { group in
                        if group.titles.count == 1, let title = group.titles.first {
                            TitleRow(title: title, state: model.viewingState(of: title), isDeleting: model.deletingID == title.id).tag(title.id)
                        } else {
                            DisclosureGroup(isExpanded: expansion(group.id)) {
                                // まとめの中は元の番組名で出す（誤ってまとめたときに分かるように）
                                ForEach(group.titles) { title in TitleRow(title: title, state: model.viewingState(of: title), isDeleting: model.deletingID == title.id).tag(title.id) }
                            } label: {
                                GroupRow(group: group)
                            }
                        }
                    }
                } else {
                    ForEach(visible) { title in TitleRow(title: title, state: model.viewingState(of: title), isDeleting: model.deletingID == title.id).tag(title.id) }
                }
            }
            // 行のダブルクリック・Return で、下の欄の最初のボタンと同じ再生。まとめの行は選べないので開閉のまま。
            // 右クリックのメニューは「削除…」だけ（1 件ずつ。保護・録画中・保存した一覧の間は押せず、理由を添える）
            .contextMenu(forSelectionType: RecordedTitle.ID.self) { ids in
                if ids.count == 1, let id = ids.first, let title = all.first(where: { $0.id == id }) {
                    let blocker = model.deletionBlocker(title)
                    Button("削除…", role: .destructive) { pendingDeletion = title }
                        .disabled(blocker != nil)
                    if let blocker { Text(blocker.text) }
                }
            } primaryAction: { ids in
                guard let id = ids.first, let title = all.first(where: { $0.id == id }) else { return }
                if let action = panel(for: title).primary { play(title, action) }
            }
            .overlay {
                if visible.isEmpty {
                    ContentUnavailableView(all.isEmpty ? "録画はありません" : "当てはまる録画はありません",
                                           systemImage: "film.stack")
                }
            }
            // 再生のボタンは一覧の上に浮かべる（帯にしない。一覧はボタンの下を通って最後の行までスクロールできる）。
            // 押せないときはボタンも理由も出さない（2026-11-21）
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if case .actions(let actions, let fromStart) = panel(for: model.selectedTitle) {
                    RecordingsPanel(actions: actions, fromStart: fromStart,
                                    resume: model.selectedTitle.flatMap { model.viewingState(of: $0).resumeSeconds }) { action in
                        if let title = model.selectedTitle { play(title, action) }
                    }
                }
            }
        }
    }

    /// 選んだ録画の再生のボタンか、押せない理由（行のダブルクリック・Return の再生にも使う）
    private func panel(for title: RecordedTitle?) -> RecordingPlayPanel {
        RecordingPlayPanel.make(title: title, state: title.map { model.viewingState(of: $0) } ?? .unwatched,
                                canPlay: model.canPlay, isStarting: environment.playback.state.isStarting,
                                isRefreshing: model.isRefreshing)
    }

    /// 再生して視聴ウィンドウを開く（前の録画の位置は AppEnvironment が記録する）。
    /// 視聴ウィンドウで再生している録画なら、別の画質のボタンは画質の切り替え・同じ画質は窓を前に出すだけ
    private func play(_ title: RecordedTitle, _ action: RecordingPlayAction) {
        guard model.canPlay, !environment.playback.state.isStarting else { return }
        environment.playFromList(title, action)
        openWindow(id: ViewerWindowID.main)
    }

    /// 一覧の状態：件数と取得日時だけ。上の帯の右（番組表の「… に更新」と同じ位置）に出す。
    /// 前は一覧の下の欄に上限・まとめの行数も出していた（2026-11-21 で件数と取得日時だけにした）。
    /// 絞り込んでいるときは「出している件数 / 全部の件数」
    private var listStatus: String? {
        guard case .loaded(let all) = model.titles else { return nil }
        let visible = model.visibleTitles.count
        var text = visible == all.count ? "\(all.count) 件" : "\(visible) / \(all.count) 件"
        if let fetchedAt = model.fetchedAt { text += "・\(ProgramGuide.receivedLabel(fetchedAt)) に取得" }
        return text
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { expandedGroups.contains(id) },
                set: { open in if open { expandedGroups.insert(id) } else { expandedGroups.remove(id) } })
    }

    @ViewBuilder
    private var detail: some View {
        if let title = model.selectedTitle {
            TitleDetailView(title: title, state: model.viewingState(of: title))
        } else {
            ContentUnavailableView("録画を選んでください", systemImage: "film")
        }
    }
}

/// 一覧の上の帯（2026-11-20 にツールバーから移した）：上の段に検索、下の段に視聴の状態・番組名でまとめる・並べ替え
struct RecordingsFilterBar: View {
    @Bindable var model: RecordingsModel
    @Environment(AppEnvironment.self) private var environment
    /// 検索欄に打てる状態か（編集のメニューの「検索」〔⌘F〕で移る）
    @FocusState private var searchFocused: Bool

    var body: some View {
        // 画面の上の帯（ScreenActionBar）の左に 1 段で並べる（前は一覧の上に 2 段）。検索の欄は並べ替えの右（2026-11-21）
        HStack(spacing: ScreenActionBarLayout.spacing) {
            // 絞り込みに先に幅を渡す（同じ優先度だと検索の欄と幅を分け合い、窓が広くても「番組名でまとめる」が絵だけになった）
            filters
                .layoutPriority(1)
            // 窓が狭いときは検索の欄から縮める（固定の幅だと、最小の窓で帯がはみ出して「更新」が切れた）
            searchField
                .frame(minWidth: RecordingsFilterBarLayout.searchMinimumWidth, idealWidth: RecordingsFilterBarLayout.searchWidth,
                       maxWidth: RecordingsFilterBarLayout.searchWidth)
        }
        .onChange(of: environment.mainCommands.pending, initial: true) {
            if environment.mainCommands.consume(.searchRecordings) { searchFocused = true }
        }
        .onChange(of: searchFocused, initial: true) { environment.mainCommands.isSearchFieldFocused = searchFocused }
        .onDisappear { environment.mainCommands.isSearchFieldFocused = false }
    }

    /// 番組名・局名で絞る（ツールバーの `.searchable` から移した。2026-11-20）
    private var searchField: some View {
        HStack(spacing: RecordingsFilterBarLayout.searchIconSpacing) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("番組名・局名", text: $model.searchText)
                .focused($searchFocused)
                .textFieldStyle(.plain)
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("検索の文字を消す")
            }
        }
        .padding(.horizontal, RecordingsFilterBarLayout.searchPadding)
        .padding(.vertical, RecordingsFilterBarLayout.searchVerticalPadding)
        .background(.background, in: RoundedRectangle(cornerRadius: RecordingsFilterBarLayout.searchCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: RecordingsFilterBarLayout.searchCornerRadius).strokeBorder(.separator))
    }

    /// 視聴の状態・まとめる・並べ替え。メニューの見出し（「視聴の状態」「並べ替え」）は出さない（2026-11-21。マウスを載せると説明が出る）。
    /// 入らなければ「番組名でまとめる」を絵だけにする（最小の窓では文字が途中で切れた）
    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            filters(groupTitle: true)
            filters(groupTitle: false)
        }
    }

    private func filters(groupTitle: Bool) -> some View {
        HStack(spacing: RecordingsFilterBarLayout.spacing) {
            Picker("視聴の状態", selection: $model.viewingFilter) {
                ForEach(RecordingsModel.ViewingFilter.allCases, id: \.self) { Text(RecordingViewingFilterLabel.text($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("視聴の状態：まだ見ていない録画・途中まで見た録画だけを出す")
            Toggle(isOn: $model.groupsByName) { Label("番組名でまとめる", systemImage: "rectangle.stack") }
                .toggleStyle(.button)
                .labelStyle(groupTitle ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
                .fixedSize()
                .help("同じ番組名の録画を 1 行にまとめる（番組マーク・話数・副題を除いた名前で）")
            Picker("並べ替え", selection: $model.sortOrder) {
                ForEach(RecordingsModel.SortOrder.allCases, id: \.self) { Text(RecordingSortLabel.text($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("並べ替え")
        }
    }
}

/// 録画の並べ替えの名前（一覧の上の帯と表示のメニューで同じものを使う）
enum RecordingSortLabel {
    static func text(_ order: RecordingsModel.SortOrder) -> String {
        switch order {
        case .newestFirst: "新しい順"
        case .oldestFirst: "古い順"
        case .channel: "局"
        case .genre: "ジャンル"
        }
    }
}

/// 録画の視聴の状態での絞り込みの名前（一覧の上の帯と表示のメニューで同じものを使う）
enum RecordingViewingFilterLabel {
    static func text(_ filter: RecordingsModel.ViewingFilter) -> String {
        switch filter {
        case .all: "すべて"
        case .unwatched: "未再生"
        case .interrupted: "途中まで"
        }
    }
}

/// 一覧の上の帯の寸法
enum RecordingsFilterBarLayout {
    static let spacing: CGFloat = 8
    static let searchIconSpacing: CGFloat = 4
    static let searchPadding: CGFloat = 6
    static let searchVerticalPadding: CGFloat = 3
    static let searchCornerRadius: CGFloat = 6
    /// 検索の欄の幅（帯の左に 1 段で並べるので幅を決める）。窓が狭いときは最小の幅まで縮む。
    /// 200 から広げた（2026-11-21）。広げすぎると、帯が件数と取得日時を出せる窓の幅が広くなる（帯は左の操作がこの幅で入るときだけ出す）
    static let searchWidth: CGFloat = 240
    static let searchMinimumWidth: CGFloat = 100
}

/// 一覧の上に浮かべる再生のボタン（一覧の下の帯をやめて浮かべた。2026-11-21）。
/// 押せるときだけ出す（押せないときはボタンも理由の文も出さない）。主のボタンは白黒を反転させて目立たせる。
/// 一覧の状態（件数と取得日時）は上の帯の右へ、更新中・更新の失敗は知らせの帯へ移した
struct RecordingsPanel: View {
    let actions: [RecordingPlayAction]
    let fromStart: RecordingPlayAction?
    /// 選んだ録画の続きの位置（途中まで見た録画だけ。ボタンの説明に出す）
    let resume: Double?
    let play: (RecordingPlayAction) -> Void

    var body: some View {
        // 中身は横の中央に寄せる（2026-11-20）
        HStack(spacing: RecordingsPanelLayout.buttonSpacing) {
            ForEach(actions) { action in
                // 三角の絵で再生と分かるので、名前は画質だけ（2026-11-21）
                Button { play(action) } label: { Label(action.buttonLabel ?? action.label, systemImage: "play.fill") }
                    .buttonStyle(FloatingPlayButtonStyle(inverted: true))
                    .help(resume.map { "続きから再生（\(ViewerControls.time($0)) から）" } ?? "番組の開始から再生")
            }
            if let fromStart {
                Button(fromStart.label) { play(fromStart) }
                    .buttonStyle(FloatingPlayButtonStyle(inverted: false))
                    .help("番組の開始から再生（元画質）")
            }
        }
        .padding(.vertical, RecordingsPanelLayout.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// 浮かべるボタンの形：丸い角の板に影を付ける。`inverted` は白黒を反転（ライトモードでは黒地に白文字、ダークモードでは白地に黒文字）。
/// 反転しないもの（「最初から」）はすりガラスの板
struct FloatingPlayButtonStyle: ButtonStyle {
    let inverted: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .foregroundStyle(foreground)
            .padding(.horizontal, RecordingsPanelLayout.buttonHorizontalPadding)
            .padding(.vertical, RecordingsPanelLayout.buttonVerticalPadding)
            .background { Capsule().fill(background) }
            .overlay { if !inverted { Capsule().strokeBorder(.separator) } }
            .shadow(color: .black.opacity(RecordingsPanelLayout.shadowOpacity), radius: RecordingsPanelLayout.shadowRadius,
                    y: RecordingsPanelLayout.shadowOffset)
            .opacity(configuration.isPressed ? RecordingsPanelLayout.pressedOpacity : 1)
            .contentShape(Capsule())
    }

    private var background: AnyShapeStyle {
        inverted ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.regularMaterial)
    }

    private var foreground: AnyShapeStyle {
        inverted ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.primary)
    }
}

/// 浮かべるボタンの寸法（体感の値。画面で見て決める）
enum RecordingsPanelLayout {
    static let buttonSpacing: CGFloat = 10
    /// 一覧の下端からボタンまで
    static let verticalPadding: CGFloat = 12
    static let buttonHorizontalPadding: CGFloat = 16
    static let buttonVerticalPadding: CGFloat = 7
    static let shadowOpacity: Double = 0.25
    static let shadowRadius: CGFloat = 6
    static let shadowOffset: CGFloat = 2
    static let pressedOpacity: Double = 0.7
}

/// 一覧の 1 行
struct TitleRow: View {
    let title: RecordedTitle
    /// 視聴の状態（未再生は頭に青い点、途中までは進み具合の棒と残り、見終わったものは印なし）
    let state: ViewingState
    /// この録画を削除している途中か（回る印と「削除しています…」を出す）
    var isDeleting = false

    var body: some View {
        // 削除している間は、行の右端に回る印を大きく出す（2 行分の高さで、縦の中央。2026-11-21。前は 1 行目の右に小さく）
        HStack(spacing: 8) {
            content
            if isDeleting {
                Spacer(minLength: 4)
                Text("削除しています…").scaledFont(.caption).foregroundStyle(.secondary)
                ProgressView().controlSize(.regular)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(state == .unwatched ? Color.blue : Color.clear)
                    .frame(width: ViewingMark.dotDiameter, height: ViewingMark.dotDiameter)
                    .help(state == .unwatched ? "未再生" : "")
                if title.isRecording { Badge(text: "録画中", tint: .red) }
                Text(title.title.isEmpty ? "（番組名なし）" : title.title).lineLimit(1)
            }
            HStack(spacing: 8) {
                if let start = title.displayStart { Text(start.formatted(date: .abbreviated, time: .shortened)) }
                if let duration = RecordingFormat.duration(title.durationSeconds) { Text(duration) }
                if let channel = title.channelName { Text(channel).lineLimit(1) }
                if let quality = RecordingFormat.quality(title.desiredQualityMode) { Text(quality) }
                if title.isProtected { Image(systemName: "lock.fill").help("保護") }
            }
            .scaledFont(.caption).foregroundStyle(.secondary)
            .padding(.leading, ViewingMark.dotDiameter + 6)
            if let position = state.resumeSeconds {
                HStack(spacing: 6) {
                    ProgressView(value: min(position, Double(title.durationSeconds ?? 0)), total: Double(max(title.durationSeconds ?? 1, 1)))
                        .progressViewStyle(.linear).controlSize(.mini)
                        .frame(maxWidth: ViewingMark.progressWidth)
                    if let remaining = RecordingFormat.remainingSeconds(state, duration: title.durationSeconds),
                       let text = RecordingFormat.duration(remaining) {
                        Text("残り \(text)").scaledFont(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, ViewingMark.dotDiameter + 6)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 一覧の行の視聴の印の大きさ
enum ViewingMark {
    /// 未再生の点の直径
    static let dotDiameter: CGFloat = 8
    /// 途中までの進み具合の棒の最大の幅
    static let progressWidth: CGFloat = 120
}

/// まとめの行：まとめの名前・件数・未再生の件数・いちばん新しい録画の日時（未再生は視聴の状態で数える）
struct GroupRow: View {
    let group: RecordingGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 未再生の印は番組名の後ろ（2026-11-21。前は番組名の前）
            HStack(spacing: 6) {
                Text(group.name).lineLimit(1)
                if group.unwatchedCount > 0 { Badge(text: "未再生 \(group.unwatchedCount)", tint: .blue).fixedSize() }
            }
            HStack(spacing: 8) {
                Text("\(group.titles.count) 件")
                if let latest = group.latestStart { Text("最新 " + latest.formatted(date: .abbreviated, time: .shortened)) }
            }
            .scaledFont(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// 折りたためる区画の見出し：見出しを押すと開け閉めする。右の矢印は開いていれば下向き。
/// `Section(isExpanded:)` は grouped の Form で開閉の印を出さなかった（AX で見えなかった）ので、見出しをボタンにした。iPad でも押せる
struct CollapsibleSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: CollapsibleSectionLayout.animationDuration)) { isExpanded.toggle() }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "\(title)を閉じる" : "\(title)を開く")
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "開いている" : "閉じている")
    }
}

/// 折りたためる区画の寸法
enum CollapsibleSectionLayout {
    /// 開け閉めの動きの長さ（体感の値）
    static let animationDuration: Double = 0.2
}

/// 録画の画面の設定の鍵（UserDefaults）
enum RecordingsSettingsKey {
    /// 詳細の欄の「情報」の区画を開いているか（未設定なら開く）
    static let detailInfoExpanded = "recordingDetailInfoExpanded"
    /// 詳細の欄の「詳細」の区画を開いているか（未設定なら開く）
    static let detailLongExpanded = "recordingDetailLongExpanded"
}

/// 小さな印
struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text).scaledFont(.caption2, weight: .bold).padding(.horizontal, 4).padding(.vertical, 1)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(tint)
    }
}

/// 録画の詳細。再生の res は持っているが、アドレスは画面に出さない。
/// 画質の選択と再生のボタンは置かない（一覧の下の欄に置く）
struct TitleDetailView: View {
    let title: RecordedTitle
    /// 視聴の状態
    let state: ViewingState
    /// 「情報」「詳細」の区画を開いているか（保存して、録画を選び直しても起動し直しても引き継ぐ）
    @AppStorage(RecordingsSettingsKey.detailInfoExpanded) private var infoExpanded = true
    @AppStorage(RecordingsSettingsKey.detailLongExpanded) private var longExpanded = true

    // 題の下に概要（見出しなし）、その下に局〜保護をまとめた「情報」と「詳細」の区画。区画は折りたためる（2026-11-21）
    var body: some View {
        Form {
            Section {
                // 題は title3 からひと回り小さくした（2026-11-21）
                Text(title.title.isEmpty ? "（番組名なし）" : title.title).scaledFont(.headline, weight: .bold).textSelection(.enabled)
                if let description = title.description, !description.isEmpty {
                    Text(description).textSelection(.enabled)
                }
            }
            Section {
                if infoExpanded {
                    if let channel = title.channelName { LabeledContent("局", value: channel) }
                    if let start = title.displayStart {
                        LabeledContent("日時", value: start.formatted(date: .complete, time: .shortened))
                    }
                    if let duration = RecordingFormat.duration(title.durationSeconds) { LabeledContent("長さ", value: duration) }
                    if !title.genres.isEmpty { LabeledContent("ジャンル", value: title.genres.joined(separator: "・")) }
                    if let quality = RecordingFormat.quality(title.desiredQualityMode) { LabeledContent("画質", value: quality) }
                    if !title.playableResources.isEmpty {
                        // ムーブ専用の res は再生に使わないので並べない
                        LabeledContent("再生できる画質",
                                       value: title.playableResources.map { RecordingFormat.resourceQuality($0.quality) }.joined(separator: "・"))
                    }
                    if let copies = RecordingFormat.copyCount(title.copyCountRemaining) { LabeledContent("残りコピー回数", value: copies) }
                    LabeledContent("視聴", value: RecordingFormat.viewing(state, duration: title.durationSeconds))
                    if title.isProtected { LabeledContent("保護", value: "あり") }
                }
            } header: {
                CollapsibleSectionHeader(title: "情報", isExpanded: $infoExpanded)
            }
            if let long = title.longDescription, !long.isEmpty {
                // 改行は CR で届くことがある。Text は CR も改行として出す
                Section {
                    if longExpanded { Text(long).textSelection(.enabled) }
                } header: {
                    CollapsibleSectionHeader(title: "詳細", isExpanded: $longExpanded)
                }
            }
        }
        .formStyle(.grouped)
    }
}
