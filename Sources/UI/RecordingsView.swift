import SwiftUI

/// 録画一覧。選んだ録画の情報と再生・削除のボタンは、一覧の右寄りに選んだ行の高さで重ねるカードに出す（`SelectionCardOverlay`）。
/// 行のダブルクリック・Return（iPad はダブルタップ）でカードの最初の再生のボタンと同じ再生
struct RecordingsView: View {
    @State var model: RecordingsModel
    /// 視聴の画面を開く（OS ごとに違うので、作る側が渡す）。無ければ再生のボタンを出さず、行のダブルクリックでも再生しない
    let openViewer: (() -> Void)?
    @Environment(AppEnvironment.self) private var environment
    /// 行の背景の濃さをライトとダークで変える
    @Environment(\.colorScheme) private var colorScheme
    /// 開いているまとめ（まとめの名前）
    @State private var expandedGroups: Set<String> = []
    /// 最後にまとめを開け閉めしたとき（ダブルクリックの 2 回目を数えないため）
    @State private var lastGroupToggle: (id: String, at: Date)?
    /// 消す前の確かめを出している録画
    @State private var pendingDeletion: RecordedTitle?
    /// 見えている行の枠（カードを選んだ行の高さに置くため）
    @State private var rowFrames = ListRowFrames<RecordedTitle.ID>()
    /// 狭い幅の形（カードはシート）
    @Environment(\.usesCompactLayout) private var compact
    /// カードのシートを閉じ終えてからすること（再生の画面は、シートを出している間は出せない）
    @State private var afterCardSheet: (() -> Void)?

    var body: some View {
        // 消す前の確かめ。カードのシートを出しているときは、シートの側で出す（下の画面からはシートの上に出せない）
        deletionAlert(screen, isPresented: pendingDeletion != nil && !showsCardSheet)
    }

    private var screen: some View {
        // 上の帯（番組表と同じ位置）に検索・絞り込み・並べ替えと件数。帯の下の横線で、左右の仕切りの縦線を止める
        // （仕切りの縦線がツールバーまで突き抜けていた。2026-11-20）
        VStack(spacing: 0) {
            ScreenActionBar(status: listStatus) {
                RecordingsFilterBar(model: model)
            }
            // 一覧は窓の幅いっぱい。選んだ録画の情報は一覧に重ねるカードに出す（2026-11-22。前は右に区切った情報の欄）
            list
                .overlay {
                    if !compact { SelectionCardOverlay(id: model.selectedID, rows: rowFrames) { _ in card } }
                }
        }
        .navigationTitle("録画")
        // 狭い幅では、選んだ録画のカードを下からのシートで出す
        .selectionCardSheet(isPresented: showsCardSheet, close: { model.selectedID = nil }, onDismiss: runAfterCardSheet) {
            deletionAlert(card, isPresented: pendingDeletion != nil)
        }
        // 検索・視聴の状態・まとめる・並べ替えは上の帯（ツールバーから一覧の上へ、のちに画面の上の帯へ移した）
        .task { if model.titles == .idle { await model.reload() } }
        // メニュー：録画を削除…（⌘⌫。選んだ録画で確かめを出す）
        .onChange(of: environment.mainCommands.pending, initial: true) {
            let center = environment.mainCommands
            if center.consume(.deleteRecording), let title = model.selectedTitle, model.deletionBlocker(title) == nil {
                pendingDeletion = title
            }
        }
    }

    /// カードをシートで出すか（狭い幅で、録画を選んでいるとき）
    private var showsCardSheet: Bool { compact && model.selectedTitle != nil }

    /// カードのシートを閉じ終えたら、預けていた操作をする
    private func runAfterCardSheet() {
        let action = afterCardSheet
        afterCardSheet = nil
        action?()
    }

    /// 消す前の確かめ（文は予約の削除〔2026-11-19 に〕に揃えた）。閉じたときの Binding の set では何もしない
    private func deletionAlert<Content: View>(_ content: Content, isPresented: Bool) -> some View {
        content.alert("この録画を削除しますか？", isPresented: Binding(get: { isPresented }, set: { _ in })) {
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
                            titleRow(title)
                        } else {
                            // まとめの行は自前の行にし、開いているときは中の録画の行をすぐ下に並べる（2026-11-22。前は DisclosureGroup で、
                            // macOS は開閉の印が左・ダブルクリックで開閉、iPad は印が右・1 回のタップで開閉と分かれていた。iPad の形にそろえた）。
                            // 1 回のクリック（タップ）で開け閉めし、開閉の印は行の左端（録画の行の局のロゴの場所）。選べない行なので一覧の primaryAction には来ない
                            GroupRow(group: group, isExpanded: expandedGroups.contains(group.id))
                                .contentShape(Rectangle())
                                .onTapGesture { toggleGroup(group.id) }
                                .listRowBackground(RecordingRowTint.groupBackground(scheme: colorScheme))
                            if expandedGroups.contains(group.id) {
                                // まとめの中は元の番組名で出し、一段下げる（誤ってまとめたときに分かるように）
                                ForEach(group.titles) { title in titleRow(title, indented: true) }
                            }
                        }
                    }
                } else {
                    ForEach(visible) { title in titleRow(title) }
                }
            }
            .compactListTopMargin()
            // 一覧を送り始めたら検索のキーボードを閉じる（iPhone のキーボードには閉じるボタンが無い。Mac には効かない。2026-11-24）
            .scrollDismissesKeyboard(.immediately)
            // 行のダブルクリック・Return（iPad は行のダブルタップ）で、カードの最初の再生のボタンと同じ再生。まとめの行は 1 回のクリック（タップ）で開閉する（上）。
            // 右クリックのメニューは「保護」（保護した録画は「解除」）と「削除…」（1 件ずつ。押せないときは理由を添える）。
            // 長押しのメニュー（iPad）も同じ。視聴の画面を開けないときは、行のダブルクリックで再生しない
            .contextMenu(forSelectionType: RecordedTitle.ID.self, menu: { ids in
                if ids.count == 1, let id = ids.first, let title = all.first(where: { $0.id == id }) {
                    let protectionBlocker = model.protectionBlocker(title)
                    Button { toggleProtection(title) } label: { RecordingProtectionLabel(isProtected: title.isProtected) }
                        .disabled(protectionBlocker != nil)
                    if let protectionBlocker { Text(protectionBlocker.text) }
                    Divider()
                    let blocker = model.deletionBlocker(title)
                    Button("削除…", role: .destructive) { pendingDeletion = title }
                        .disabled(blocker != nil)
                    if let blocker { Text(blocker.text) }
                }
            }, primaryAction: ListRowInteraction.usesPrimaryAction ? primaryAction(all) : nil)
            .overlay {
                if visible.isEmpty {
                    ContentUnavailableView(all.isEmpty ? "録画はありません" : "当てはまる録画はありません",
                                           systemImage: "film.stack")
                }
            }
            // カードの外を押したら閉じる（行を押したときは、カードがその行へ移る）。esc でも閉じる（どちらも選択を外す）
            // 狭い幅ではカードはシートなので見張らない（シートの中を押しても閉じてしまう）
            .closesSelectionCardOnOutsideTap(rows: rowFrames, isOpen: model.selectedID != nil && !compact) { model.selectedID = nil }
            .onKeyPress(.escape) {
                guard model.selectedID != nil else { return .ignored }
                model.selectedID = nil
                return .handled
            }
        }
    }

    /// 行のダブルクリック・Return の再生（カードの最初の再生のボタンと同じ）。視聴の画面を開けなければ無い
    private func primaryAction(_ all: [RecordedTitle]) -> ((Set<RecordedTitle.ID>) -> Void)? {
        guard openViewer != nil else { return nil }
        return { ids in
            guard let id = ids.first, let title = all.first(where: { $0.id == id }) else { return }
            if let action = panel(for: title).primary { play(title, action) }
        }
    }

    /// 選んだ録画の再生のボタンか、押せない理由（行のダブルクリック・Return の再生にも使う）
    private func panel(for title: RecordedTitle?) -> RecordingPlayPanel {
        RecordingPlayPanel.make(title: title, state: title.map { model.viewingState(of: $0) } ?? .unwatched,
                                canPlay: model.canPlay, isStarting: environment.playback.state.isStarting,
                                isRefreshing: model.isRefreshing, isOffline: model.isOffline)
    }

    /// カードに出す再生のボタンと、押せないときの理由。押せないとき（一覧の取り直しの途中・再生を始めている途中など）も
    /// ボタンは隠さず、灰色にして理由を説明に出す（2026-11-22。前は隠していて、カードに何も出ず不具合のように見えた）。
    /// 再生できる画質が無い録画と、視聴の画面を開けないときはボタンを出さない
    private func cardButtons(for title: RecordedTitle) -> (panel: RecordingPlayPanel?, disabledReason: String?) {
        guard openViewer != nil else { return (nil, nil) }
        let actual = panel(for: title)
        guard case .blocked(let reason) = actual else { return (actual, nil) }
        // 押せるときに出るはずのボタン（並びと名前を同じにするため、押せる条件にして作る）
        let preview = RecordingPlayPanel.make(title: title, state: model.viewingState(of: title), canPlay: true, isStarting: false)
        guard case .actions = preview else { return (nil, nil) }
        return (preview, reason)
    }

    /// 再生して視聴ウィンドウを開く（前の録画の位置は AppEnvironment が記録する）。
    /// 視聴ウィンドウで再生している録画なら、別の画質のボタンは画質の切り替え・同じ画質は窓を前に出すだけ
    private func play(_ title: RecordedTitle, _ action: RecordingPlayAction) {
        guard let openViewer, model.canPlay, !environment.playback.state.isStarting else { return }
        // カードのシートから押したときは、シートを閉じ終えてから再生の画面を出す
        if showsCardSheet {
            afterCardSheet = { [environment] in
                environment.playFromList(title, action)
                openViewer()
            }
            model.selectedID = nil
            return
        }
        environment.playFromList(title, action)
        openViewer()
    }

    /// 録画の保護を切り替える（確かめは出さない。元に戻せるため）。切り替えられなかったときは知らせの帯に出す
    private func toggleProtection(_ title: RecordedTitle) {
        Task {
            if let error = await model.setProtection(title, protect: !title.isProtected) {
                environment.notices.post(.error(id: "recordings.protection", error, prefix: "録画の保護"))
            }
        }
    }

    /// 一覧の状態：件数だけ。上の帯の右に出す。
    /// 前は一覧の下の欄に上限・まとめの行数も出していた（2026-11-21 で件数と取得日時だけにし、2026-11-24 に取得日時も外した。
    /// 一覧は世代の見回りで自分で読み直すので、いつ取ったかを見せる意味が薄い）。
    /// 絞り込んでいるときは「出している件数 / 全部の件数」
    private var listStatus: String? {
        guard case .loaded(let all) = model.titles else { return nil }
        let visible = model.visibleTitles.count
        return visible == all.count ? "\(all.count) 件" : "\(visible) / \(all.count) 件"
    }

    /// まとめの行を開く・閉じる（ダブルクリック）
    /// まとめの行を開く・閉じる（1 回のクリック・タップ）。ダブルクリック（ダブルタップ）の 2 回目は数えない
    /// （数えると開いてすぐ閉じ、元に戻って見えた）
    private func toggleGroup(_ id: String) {
        let now = Date()
        if let last = lastGroupToggle, last.id == id, now.timeIntervalSince(last.at) < GroupToggleTiming.repeatGuard { return }
        lastGroupToggle = (id, now)
        withAnimation {
            if expandedGroups.contains(id) { expandedGroups.remove(id) } else { expandedGroups.insert(id) }
        }
    }

    /// 一覧の 1 行（行の枠をカードに知らせる。iPad はダブルタップで再生）
    private func titleRow(_ title: RecordedTitle, indented: Bool = false) -> some View {
        // tag は一番外に付ける（内側に付けると一覧の選択が録画に結び付かず、選んでもカードが出なかった）
        TitleRow(title: title, state: model.viewingState(of: title), isDeleting: model.deletingID == title.id,
                 isChangingProtection: model.protectingID == title.id)
            .padding(.leading, indented ? GroupToggleTiming.childIndent : 0)
            .reportsRowFrame(title.id, into: rowFrames)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if let action = panel(for: title).primary { play(title, action) }
            }, including: ListRowInteraction.playsOnRowDoubleTap ? .all : .subviews)
            .tag(title.id)
            // 行の背景も一番外に付ける（tag と同じく、内側に付けると一覧の行に効かない）。
            // 選んだ行は塗らない（塗ると iPad で選んだ印の灰色が消えた）
            .listRowBackground(model.selectedID == title.id ? nil
                               : RecordingRowTint.background(for: model.viewingState(of: title), scheme: colorScheme))
    }

    /// 選んだ録画のカード
    @ViewBuilder
    private var card: some View {
        if let title = model.selectedTitle {
            let buttons = cardButtons(for: title)
            TitleCard(title: title, state: model.viewingState(of: title),
                      panel: buttons.panel, playDisabledReason: buttons.disabledReason,
                      resume: model.viewingState(of: title).resumeSeconds,
                      play: { play(title, $0) },
                      protectionBlocker: model.protectionBlocker(title),
                      isChangingProtection: model.protectingID == title.id,
                      toggleProtection: { toggleProtection(title) },
                      deletionBlocker: model.deletionBlocker(title),
                      delete: { pendingDeletion = title },
                      close: { model.selectedID = nil })
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
            // 窓が狭いときは検索の欄から縮める（固定の幅だと、最小の窓で帯がはみ出して「更新」が切れた）。
            // Mac は窓のタイトルの帯の右に置く（2026-11-24 の試作）
            if MainSearchPlacement.inScreenBar {
                searchField
                    .frame(minWidth: RecordingsFilterBarLayout.searchMinimumWidth, idealWidth: RecordingsFilterBarLayout.searchWidth,
                           maxWidth: RecordingsFilterBarLayout.searchWidth)
            }
        }
        .mainToolbarSearch(text: $model.searchText, focused: $searchFocused, prompt: RecordingsFilterBarLayout.searchPrompt)
        .onChange(of: environment.mainCommands.pending, initial: true) {
            if environment.mainCommands.consume(.searchRecordings) { searchFocused = true }
        }
        .onChange(of: searchFocused, initial: true) { environment.mainCommands.isSearchFieldFocused = searchFocused }
        .onDisappear { environment.mainCommands.isSearchFieldFocused = false }
    }

    /// 番組名・局名で絞る（ツールバーの `.searchable` から移した。2026-11-20）
    private var searchField: some View {
        BarSearchField(prompt: RecordingsFilterBarLayout.searchPrompt, text: $model.searchText, focused: $searchFocused)
    }

    /// 視聴の状態・まとめる・並べ替え。どの幅も絵のメニューと絵だけのボタン（2026-11-24 に Mac・iPad の広い幅も iPhone と同じ形にした。
    /// 前は広い幅では文字のメニュー〔「すべて」「新しい順」など〕。狭い幅は 2026-11-23 から絵。文字のメニューのままでは検索の欄に「更新」が重なった）。
    /// メニューの中の項目と文字はどの幅も同じ。名前はマウスを載せた説明と読み上げの名前で出す
    private var filters: some View {
        HStack(spacing: RecordingsFilterBarLayout.spacing) {
            Menu {
                Picker("視聴の状態", selection: $model.viewingFilter) {
                    ForEach(RecordingsModel.ViewingFilter.allCases, id: \.self) { Text(RecordingViewingFilterLabel.text($0)).tag($0) }
                }
            } label: {
                // 絞っている間は塗った絵。円の中の線が小さく見えるので一段大きく描く（2026-11-24。ほかの絵は大きさを変えない）
                Image(systemName: model.viewingFilter == .all ? RecordingsFilterSymbol.viewing : RecordingsFilterSymbol.viewingActive)
                    .imageScale(RecordingsFilterSymbol.viewingScale)
            }
            .menuIndicator(.hidden)
            .barButtonChrome()
            .fixedSize()
            .accessibilityLabel("視聴の状態：\(RecordingViewingFilterLabel.text(model.viewingFilter))")
            .help("視聴の状態：\(RecordingViewingFilterLabel.text(model.viewingFilter))（まだ見ていない録画・途中まで見た録画だけを出す）")
            Toggle(isOn: $model.groupsByName) { Label("番組名でまとめる", systemImage: RecordingsFilterSymbol.group) }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .barToggleChrome(isOn: model.groupsByName)
                .fixedSize()
                .help("同じ番組名の録画を 1 行にまとめる（番組マーク・話数・副題を除いた名前で）")
            Menu {
                Picker("並べ替え", selection: $model.sortOrder) {
                    ForEach(RecordingsModel.SortOrder.allCases, id: \.self) { Text(RecordingSortLabel.text($0)).tag($0) }
                }
            } label: {
                Image(systemName: RecordingsFilterSymbol.sort)
            }
            .menuIndicator(.hidden)
            .barButtonChrome()
            .fixedSize()
            .accessibilityLabel("並べ替え：\(RecordingSortLabel.text(model.sortOrder))")
            .help("並べ替え：\(RecordingSortLabel.text(model.sortOrder))")
        }
        .fixedSize()
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

/// 録画のカードの狭い幅の絵
enum RecordingCardSymbol {
    /// 「モバイル」の再生のボタン（三角の右に並べる）
    static let mobile = "iphone"
    /// 三角と携帯電話の絵の間
    static let mobileSpacing: CGFloat = 4
    /// 「最初から」の再生のボタン（頭へ戻って再生する、の形）
    static let fromStart = "arrow.counterclockwise"
}

/// 録画のカードのボタンの並び（体感の値。実機で見て決める）
enum CardActionLayout {
    /// 画質ごとの再生のボタンと「最初から」の間（1 段・2 段のどちらでも同じ。中ほどへは離さない）
    static let fromStartGap: CGFloat = 12
}

/// 一覧の上の帯の絵（狭い幅のメニューの絵と、「番組名でまとめる」の絵）
enum RecordingsFilterSymbol {
    /// 視聴の状態（すべてを出しているとき）
    static let viewing = "line.3.horizontal.decrease.circle"
    /// 視聴の状態（未再生・途中までに絞っているとき）
    static let viewingActive = "line.3.horizontal.decrease.circle.fill"
    /// 視聴の状態の絵の大きさ（円の中の線が隣の絵より小さく見えるので一段大きく。2026-11-24 に候補から選んだ）
    static let viewingScale = Image.Scale.large
    static let sort = "arrow.up.arrow.down"
    static let group = "rectangle.stack"
}

/// 一覧の上の帯の寸法
enum RecordingsFilterBarLayout {
    static let spacing: CGFloat = 8
    /// 検索の欄の幅（帯の左に 1 段で並べるので幅を決める）。窓が狭いときは最小の幅まで縮む。
    /// 200 から広げた（2026-11-21）。広げすぎると、帯が件数と取得日時を出せる窓の幅が広くなる（帯は左の操作がこの幅で入るときだけ出す）
    static let searchWidth: CGFloat = 240
    /// 検索の欄の見本の文字（帯の中の欄と、Mac の窓のタイトルの帯の欄で同じもの）
    static let searchPrompt = "番組名・局名"
    static let searchMinimumWidth: CGFloat = 100
}

/// 一覧の 1 行
struct TitleRow: View {
    let title: RecordedTitle
    /// 視聴の状態（未再生は行の右端に青い丸、途中までは進み具合の棒と残り、見終わったものは印なし）
    let state: ViewingState
    /// この録画を削除している途中か（右端の印の代わりに回る印と「削除しています…」を出す）
    var isDeleting = false
    /// この録画の保護を切り替えている途中か（右端の印の代わりに回る印を出す）
    var isChangingProtection = false
    /// 狭い幅の形（2 行目を短くする）
    @Environment(\.usesCompactLayout) private var compact
    /// 行の頭のロゴ（狭い幅では、ロゴの出る局の局名を省く）
    @Environment(ChannelLogoImages.self) private var logos: ChannelLogoImages?

    var body: some View {
        // 右端の印は 2 行分の高さで縦の中央。未再生の丸と、削除している途中の回る印は同じ場所に出す（2026-11-22。前は番組名の左に青い点）
        HStack(spacing: 8) {
            // 左端に局のロゴ（2026-11-22）
            ChannelLogoSlot(key: title.channel?.logoKey)
            content.frame(maxWidth: .infinity, alignment: .leading)
            trailingMark
        }
    }

    @ViewBuilder
    private var trailingMark: some View {
        if isDeleting {
            // 狭い幅では回る印だけ（文は読み上げの名前に回す）
            if !compact { Text("削除しています…").scaledFont(.caption).foregroundStyle(.secondary) }
            ProgressView().controlSize(.regular)
                .accessibilityLabel("削除しています")
        } else if isChangingProtection {
            ProgressView().controlSize(.regular)
                .accessibilityLabel("保護を切り替えています")
        } else if state == .unwatched {
            Image(systemName: "circle.fill")
                .font(.system(size: ViewingMark.unwatchedSymbolSize))
                .foregroundStyle(.blue)
                .frame(width: ViewingMark.trailingSlotWidth)
                .help("未再生")
                .accessibilityLabel("未再生")
        } else {
            // 未再生でない行も同じ幅を空け、行の右端をそろえる
            Color.clear.frame(width: ViewingMark.trailingSlotWidth, height: 1)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if title.isRecording { Badge(text: "録画中", tint: .red) }
                Text(title.title.isEmpty ? "（番組名なし）" : title.title).lineLimit(1)
            }
            HStack(spacing: 8) {
                // 狭い幅では日時を短い形にし、局名は行の頭のロゴで分かるので省く（ロゴの無い局だけ出す。2026-11-23）
                if let start = title.displayStart {
                    Text(compact ? CompactDateText.dateTime(start) : start.formatted(date: .abbreviated, time: .shortened))
                }
                if let duration = RecordingFormat.duration(title.durationSeconds) { Text(duration) }
                if let channel = title.channelName, !(compact && showsLogo) { Text(channel).lineLimit(1) }
                if let quality = RecordingFormat.quality(title.desiredQualityMode) { Text(quality) }
                if title.isProtected { Image(systemName: "lock.fill").help("保護") }
            }
            .scaledFont(.caption).foregroundStyle(.secondary)
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
            }
        }
        .padding(.vertical, 2)
    }

    /// 行の頭にこの局のロゴが出ているか
    private var showsLogo: Bool {
        guard let key = title.channel?.logoKey else { return false }
        return logos?.images[key] != nil
    }
}

/// 一覧の行の視聴の印の大きさ
enum ViewingMark {
    /// 未再生の丸（`circle.fill`）の大きさ（体感の値。画面で見て決める）
    static let unwatchedSymbolSize: CGFloat = 10
    /// 行の右端の印の枠の幅（未再生でない行も空けて、右端をそろえる）
    static let trailingSlotWidth: CGFloat = 20
    /// 途中までの進み具合の棒の最大の幅
    static let progressWidth: CGFloat = 120
}

/// まとめの行の開け閉め（体感の値）
enum GroupToggleTiming {
    /// これより短い間の 2 回目のクリック（タップ）は数えない（ダブルクリックでも 1 回だけ開け閉めする）
    static let repeatGuard: TimeInterval = 0.5
    /// 開いたまとめの中の録画の行を下げる幅
    static let childIndent: CGFloat = 16
}

/// 録画の行の背景の塗り分け：視聴の状態とまとめの行を、文字の妨げにならないごく淡い色で見分ける（2026-11-22）。
/// 色は不透明度の低い重ね色にして、ライトとダークの両方で背景になじませる（ダークは少し濃くしないと見えない）。
/// 値は体感（画面で見て決める）。見終わった録画は塗らない
enum RecordingRowTint {
    /// 未再生：淡い青（右端の未再生の丸と同じ系統）
    static let unwatchedLight = 0.07
    static let unwatchedDark = 0.13
    /// 途中まで：淡い琥珀
    static let interruptedLight = 0.09
    static let interruptedDark = 0.11
    /// まとめの行：淡い藤色
    static let groupLight = 0.07
    static let groupDark = 0.12

    /// 録画の行の背景（塗らないなら nil で、一覧のもとの背景のまま）
    static func background(for state: ViewingState, scheme: ColorScheme) -> AnyView? {
        let dark = scheme == .dark
        switch state {
        case .unwatched: return layered(Color.blue.opacity(dark ? unwatchedDark : unwatchedLight))
        case .interrupted: return layered(Color.orange.opacity(dark ? interruptedDark : interruptedLight))
        case .completed: return nil
        }
    }

    /// まとめの行の背景
    static func groupBackground(scheme: ColorScheme) -> AnyView {
        layered(Color.purple.opacity(scheme == .dark ? groupDark : groupLight))
    }

    /// 行のもとの背景の上に淡い色を重ねる
    private static func layered(_ tint: Color) -> AnyView {
        AnyView(ZStack { Color.listRowBase; tint })
    }
}

/// まとめの行：まとめの名前・件数・未再生の件数・いちばん新しい録画の日時（未再生は視聴の状態で数える）
struct GroupRow: View {
    let group: RecordingGroup
    /// 開いているか（左端の印の形）
    var isExpanded = false
    @Environment(\.textScale) private var textScale

    var body: some View {
        HStack(spacing: 8) {
            // 左端（録画の行の局のロゴと同じ場所・同じ大きさの枠）に開閉の印：閉じていれば重なった板、開いていれば塗った板。
            // 局のロゴは出さない。右端の「›」は先へ移るように見えるのでやめた（2026-11-22）
            Image(systemName: isExpanded ? "rectangle.stack.fill" : "rectangle.stack")
                .font(.system(size: ChannelLogoLayout.height(textScale: textScale) * GroupMarkLayout.symbolScale))
                .foregroundStyle(.secondary)
                .frame(width: ChannelLogoLayout.height(textScale: textScale) * ChannelLogoLayout.aspectRatio,
                       height: ChannelLogoLayout.height(textScale: textScale))
                .accessibilityHidden(true)
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isExpanded ? "開いている" : "閉じている")
        .accessibilityAddTraits(.isButton)
    }
}

/// まとめの行の開閉の印の寸法（体感の値）
enum GroupMarkLayout {
    /// 印の大きさ（ロゴの枠の高さに対する割合）
    static let symbolScale: CGFloat = 0.8
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
    /// カードの「情報」の区画を開いているか（未設定なら開く。鍵の名前は情報の欄だったときのまま）
    static let detailInfoExpanded = "recordingDetailInfoExpanded"
    /// カードの「詳細」（長い説明）を開いているか（未設定なら開く。鍵の名前は情報の欄だったときのまま）
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

/// 保護の切り替えの名前と絵（カードのボタンと右クリック・長押しのメニューで同じものを使う）。
/// 絵は今の状態（保護ありは閉じた鍵・保護なしは開いた鍵）、名前は押すとすること（「保護」／「解除」）。
/// 絵も名前もすることにすると、保護していないのに閉じた鍵が出て、状態が逆に見えた（2026-11-22）
struct RecordingProtectionLabel: View {
    static let protectTitle = "保護"
    static let unprotectTitle = "解除"
    let isProtected: Bool

    var body: some View {
        Label(isProtected ? Self.unprotectTitle : Self.protectTitle, systemImage: isProtected ? "lock" : "lock.open")
    }
}

/// 録画のカード：情報と、再生・保護・削除のボタン。再生の res は持っているが、アドレスは画面に出さない
struct TitleCard: View {
    let title: RecordedTitle
    /// 視聴の状態
    let state: ViewingState
    /// 再生のボタン（視聴の画面を開けない・再生できる画質が無ければ nil で、ボタンを出さない）
    let panel: RecordingPlayPanel?
    /// 再生のボタンを押せない理由（押せるなら nil。押せないときはボタンを灰色にし、理由を説明に出す）
    let playDisabledReason: String?
    /// 続きの位置（途中まで見た録画だけ。ボタンの説明に出す）
    let resume: Double?
    let play: (RecordingPlayAction) -> Void
    /// 保護を切り替えられない理由（切り替えられるなら nil）
    let protectionBlocker: RecordingProtection.Blocker?
    /// この録画の保護を切り替えている途中か（ボタンに回る印を出す）
    let isChangingProtection: Bool
    let toggleProtection: () -> Void
    /// 消せない理由（消せるなら nil）
    let deletionBlocker: RecordingDeletion.Blocker?
    let delete: () -> Void
    let close: () -> Void
    /// 「情報」「詳細」の区画を開いているか（保存して、録画を選び直しても起動し直しても引き継ぐ）
    @AppStorage(RecordingsSettingsKey.detailInfoExpanded) private var infoExpanded = true
    @AppStorage(RecordingsSettingsKey.detailLongExpanded) private var longExpanded = true

    var body: some View {
        SelectionCardContent(title: title.title.isEmpty ? "（番組名なし）" : title.title, close: close) {
            if let description = title.description, !description.isEmpty {
                Text(description).scaledFont(.callout).textSelection(.enabled)
            }
            // 題の下に概要（見出しなし）、その下に局〜保護をまとめた「情報」と「詳細」の区画。どちらも折りたためる（前の情報の欄と同じ）
            VStack(alignment: .leading, spacing: 6) {
                CollapsibleSectionHeader(title: "情報", isExpanded: $infoExpanded)
                    .scaledFont(.callout, weight: .semibold)
                if infoExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        if let channel = title.channelName { SelectionCardField("局", value: channel) }
                        if let start = title.displayStart {
                            SelectionCardField("日時", value: start.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let duration = RecordingFormat.duration(title.durationSeconds) { SelectionCardField("長さ", value: duration) }
                        if !title.genres.isEmpty { SelectionCardField("ジャンル", value: title.genres.joined(separator: "・")) }
                        if let quality = RecordingFormat.quality(title.desiredQualityMode) { SelectionCardField("画質", value: quality) }
                        if !title.playableResources.isEmpty {
                            // ムーブ専用の res は再生に使わないので並べない
                            SelectionCardField("再生できる画質",
                                               value: title.playableResources.map { RecordingFormat.resourceQuality($0.quality) }.joined(separator: "・"))
                        }
                        if let copies = RecordingFormat.copyCount(title.copyCountRemaining) { SelectionCardField("残りコピー回数", value: copies) }
                        SelectionCardField("視聴", value: RecordingFormat.viewing(state, duration: title.durationSeconds))
                        if title.isProtected { SelectionCardField("保護", value: "あり") }
                    }
                }
            }
            if let long = title.longDescription, !long.isEmpty {
                // 改行は CR で届くことがある。Text は CR も改行として出す
                VStack(alignment: .leading, spacing: 6) {
                    CollapsibleSectionHeader(title: "詳細", isExpanded: $longExpanded)
                        .scaledFont(.callout, weight: .semibold)
                    if longExpanded {
                        Text(long).scaledFont(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } actions: {
            // 1 段に収まらなければ、保護と削除を下の段の右へ回す（ボタンの名前が折り返して 2 行になっていた）
            // 1 段に収まるときは、「最初から」を画質ごとの再生のボタンから離し、残りの幅の中ほどに置く（右へ寄せても「保護」とは
            // くっつけない。最も右でも「最初から」の右端が「保護」の左端まで）。「保護」は「削除…」の左隣
            // 「最初から」は再生のボタンから決まった間で置く（中ほどに置くと iPhone の横向きで浮いて見えた。2026-11-23）
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    playButtons
                    fromStartButton.padding(.leading, CardActionLayout.fromStartGap - 8)
                    Spacer(minLength: 8)
                    protectButton
                    deleteButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        playButtons
                        fromStartButton.padding(.leading, CardActionLayout.fromStartGap - 8)
                    }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        protectButton
                        deleteButton
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var playButtons: some View {
        if case .actions(let actions, _) = panel {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                let button = Button { play(action) } label: {
                    if action.resource.quality == TitleResource.mobileQuality {
                        // 「モバイル」は携帯電話の絵にする（文字では間延びして見えた。2026-11-23。どの OS も）
                        HStack(spacing: RecordingCardSymbol.mobileSpacing) {
                            Image(systemName: "play.fill")
                            Image(systemName: RecordingCardSymbol.mobile)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(action.buttonLabel ?? action.label)
                    } else {
                        // 三角の絵で再生と分かるので、名前は画質だけ（2026-11-21）
                        Label(action.buttonLabel ?? action.label, systemImage: "play.fill").lineLimit(1)
                    }
                }
                .fixedSize()
                .disabled(playDisabledReason != nil)
                .help(playDisabledReason ?? resume.map { "続きから再生（\(PlaybackTimeFormat.text($0)) から）" } ?? "番組の開始から再生")
                if index == 0 { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
            }
        }
    }

    /// 「最初から」（続きのある録画だけ）
    @ViewBuilder
    private var fromStartButton: some View {
        if case .actions(_, let fromStart?) = panel {
            Button { play(fromStart) } label: {
                // 絵だけ（読み上げの名前は文字のまま）
                Image(systemName: RecordingCardSymbol.fromStart)
            }
            .accessibilityLabel(fromStart.label)
                .lineLimit(1).fixedSize()
                .buttonStyle(.bordered)
                .disabled(playDisabledReason != nil)
                .help(playDisabledReason ?? "番組の開始から再生（元画質）")
        }
    }

    /// 「保護」／「解除」（鍵の絵は今の状態）。切り替えている途中は、鍵の絵の代わりに回る印を出す。
    /// 行の右端にも回る印を出す（右クリック・長押しのメニューで切り替えたときは、カードを開いていないことがあるため）
    private var protectButton: some View {
        Button(action: toggleProtection) {
            if isChangingProtection {
                // 回る印だけ（鍵の絵のボタンと同じ幅に近づける）
                ProgressView().controlSize(.small)
            } else {
                // どの OS・幅でも鍵の絵だけ（絵は今の状態。2026-11-23。名前は読み上げと説明に回す）
                RecordingProtectionLabel(isProtected: title.isProtected)
                    .labelStyle(.iconOnly)
            }
        }
        .accessibilityLabel(title.isProtected ? RecordingProtectionLabel.unprotectTitle : RecordingProtectionLabel.protectTitle)
        .lineLimit(1).fixedSize()
        .buttonStyle(.bordered)
        .disabled(protectionBlocker != nil)
        .help(protectionBlocker?.text ?? (title.isProtected ? "保護を解除する（削除できるようになる）" : "保護する（削除できなくなる）"))
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: delete) {
            // ゴミ箱の絵だけ（2026-11-23。どの OS も）
            Image(systemName: CardDeleteSymbol.name)
        }
        .accessibilityLabel("削除…")
        // 鍵のボタンと同じく地のあるボタンにする（絵だけでは押せるものに見えにくい）
        .buttonStyle(.bordered)
            .lineLimit(1).fixedSize()
            .disabled(deletionBlocker != nil)
            .help(deletionBlocker?.text ?? "この録画を削除する")
    }
}
