import SwiftUI

/// 設定（登録した nasne と資格情報）
/// 設定のシート（主ウィンドウの中で開く。iPad と同じ形にするため）
struct SettingsSheet: View {
    let services: NasneServices
    let credentials: CredentialsModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 閉じる：iPad は左上の ×（題は同じ段の真ん中）、macOS は下の「閉じる」（題は上に置く）
            if SheetCloseLayout.closesAtTop {
                SheetTopCloseBar(title: SettingsSheetLayout.title, close: close)
            } else {
                Text(SettingsSheetLayout.title)
                    .scaledFont(.headline)
                    .padding(.top, SettingsSheetLayout.barPadding)
            }
            SettingsView(services: services, credentials: credentials)
            if !SheetCloseLayout.closesAtTop {
                Divider()
                HStack {
                    Spacer()
                    Button("閉じる", action: close)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(SettingsSheetLayout.barPadding)
            }
        }
        // Mac のシートの窓の大きさ（iOS はシートの大きさを OS が決める）
        .sheetResizableSize(minimum: SettingsSheetLayout.minimumSize, ideal: SettingsSheetLayout.idealSize)
    }
}

/// シートの上に置く「閉じる」（左上の ×。iPad の閉じる操作は左上の × に揃える）。Esc でも閉じる
struct SheetTopCloseBar: View {
    /// 段の真ん中に出す題（無ければ出さない）
    var title: String?
    let close: () -> Void

    var body: some View {
        HStack {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: SheetCloseLayout.buttonSize, height: SheetCloseLayout.buttonSize)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("閉じる")
            Spacer()
        }
        .overlay {
            if let title {
                Text(title).scaledFont(.headline).accessibilityAddTraits(.isHeader)
            }
        }
        .padding(.horizontal, SheetCloseLayout.horizontalPadding)
        .padding(.top, SheetCloseLayout.topPadding)
    }
}

/// 設定のシートの大きさ（Mac のシートの窓）
enum SettingsSheetLayout {
    /// シートの題
    static let title = "設定"
    static let minimumSize = CGSize(width: 480, height: 400)
    static let idealSize = CGSize(width: 560, height: 600)
    static let barPadding: CGFloat = 12
}

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    let services: NasneServices
    let credentials: CredentialsModel
    @State private var error: ErrorPresentation?
    @State private var confirming = false
    /// nasne を足す（登録の画面をシートで出す）
    @State private var adding = false
    @AppStorage(GuideSettingsKey.showsSubchannels) private var showsSubchannels = false
    @AppStorage(ViewerSettingsKey.captionsByDefault) private var captionsByDefault = false
    /// 止めた位置を nasne へ書き戻すか（既定は書き戻す）
    @AppStorage(ViewingSettingsKey.writesResumePosition) private var writesResumePosition = true
    /// ライブを始めるときの画質（既定は DR）
    @AppStorage(LiveSettingsKey.defaultQuality) private var liveDefaultQuality = LiveQuality.initial.rawValue
    /// 主ウインドウの文字の大きさ
    @AppStorage(MainWindowSettingsKey.textSize) private var textSize = MainTextSize.initial.rawValue

    var body: some View {
        Form {
            Section("表示") {
                Picker("文字の大きさ", selection: Binding(get: { MainTextSize.saved(textSize) }, set: { textSize = $0.rawValue })) {
                    ForEach(MainTextSize.allCases) { size in Text(size.label).tag(size) }
                }
                SettingsNote("\(DeviceWording.mainScreen)の文字の大きさです。", details: ["\(DeviceWording.viewerScreen)と字幕は変わりません。"])
            }
            // 登録した nasne の一覧（印の付いた台を見る。押すと切り替わる）と、足す・外す（外すのは印の付いた台）、
            // 印の付いた台の登録の日時と nasne HOME を 1 つの節にまとめる（2026-11-25 に決めた）。
            // 足す・外すの置き方は OS ごと（`SettingsActionLayout`）
            Section("nasne") {
                NasneRegistrationList(registrations: environment.registrations, current: services.registration.storageKey) { key in
                    Task { await environment.selectNasne(key: key) }
                }
                if SettingsActionLayout.usesRows {
                    Button("nasne を追加…") { adding = true }
                } else {
                    HStack {
                        Spacer()
                        Button("登録を外す…", role: .destructive) { confirming = true }
                        Button("nasne を追加…") { adding = true }
                    }
                }
                SettingsNote("印の付いた nasne を見ます。行を押すと切り替わります。",
                             details: ["番組表・予約・録画・メディア・情報は、印の付いた nasne のものを出します。",
                                       "切り替えると、再生は止まります。",
                                       "「登録を外す…」は、印の付いた nasne の登録を外します。"])
                if let date = services.registration.registeredAt {
                    LabeledContent("登録した日時", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("nasne HOME") {
                    Link("ブラウザで開く", destination: services.nasneHomeURL)
                }
                SettingsNote("印の付いた nasne の設定画面を Web ブラウザで開きます。",
                             details: ["nasne と同じネットワークにいるときに開けます。"])
                if SettingsActionLayout.usesRows {
                    Button("登録を外す…", role: .destructive) { confirming = true }
                }
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
                Toggle("続きの位置を nasne に保存する", isOn: $writesResumePosition)
                SettingsNote("録画を止めた位置を nasne に書き込み、ほかの端末や torne と続きを共有します。",
                             details: ["見終わった録画は、nasne の続きの位置を消します。",
                                       "切っても、\(DeviceWording.thisDevice)の中の続きの位置は残ります。",
                                       "録画中の録画は書き込みません。"])
            }
            Section("ライブ") {
                Picker("始めるときの画質", selection: Binding(get: { LiveQuality.saved(liveDefaultQuality) },
                                                        set: { liveDefaultQuality = $0.rawValue })) {
                    ForEach(LiveQuality.allCases, id: \.self) { quality in Text(quality.label).tag(quality) }
                }
                SettingsNote("ライブを始めるときの画質です。",
                             details: ["\(DeviceWording.viewerScreen)で切り替えた画質は、\(DeviceWording.viewerScreenShort)を閉じるまで局を替えても引き継ぎます。"])
            }
            CredentialsSection(model: credentials)
            if let error { Section { ErrorBanner(error: error) } }
            DiagnosticsSection()
            // 名前・版・権利と、使っている部品の許諾文（iOS には Mac の「について」の画面が無いので、どの OS でも最後に）
            AboutSection()
        }
        .formStyle(.grouped)
        .settingsScrollerMargins()
        .navigationTitle("設定")
        // 確かめはアラート（録画・予約の削除と同じ形。確かめの選択肢の形は iPad でボタンの吹き出しになった。2026-11-25）
        .alert("「\(currentName)」の登録を外しますか？", isPresented: $confirming) {
            Button("キャンセル", role: .cancel) {}
            Button("登録を外す", role: .destructive) {
                let key = services.registration.storageKey
                Task {
                    do {
                        try await environment.unregister(key: key)
                    } catch {
                        self.error = ErrorText.present(error)
                    }
                }
            }
        } message: {
            Text("保存した登録と、\(DeviceWording.thisDevice) に保存したこの nasne の番組表・録画一覧を消します。\(DeviceWording.thisDevice) の視聴の記録（見終わった・途中まで見た位置）も消えます。nasne の録画や予約は消えません。")
        }
        .sheet(isPresented: $adding) {
            // 登録が通ったら閉じる（設定のシートは開いたまま、足した台に印が付く）
            AddNasneSheet(model: environment.makeSetupModel { adding = false }) { adding = false }
        }
    }

    /// 選んでいる nasne の呼び名
    private var currentName: String {
        NasneDisplayName.names(for: environment.registrations.entries)[services.registration.storageKey]
            ?? services.registration.friendlyName
    }
}

/// 登録した nasne の一覧（行を押すと、その台を見る）。選んでいる台に印を付ける
private struct NasneRegistrationList: View {
    let registrations: RegistrationList
    let current: String
    let select: (String) -> Void

    var body: some View {
        let names = NasneDisplayName.names(for: registrations.entries)
        ForEach(registrations.entries, id: \.key) { entry in
            Button { select(entry.key) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: NasneRegistrationListLayout.rowSpacing) {
                        Text(names[entry.key] ?? entry.registration.friendlyName)
                        if let maker = NasneDisplayName.maker(of: entry.device) {
                            Text(maker).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if entry.key == current {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            .accessibilityLabel("選んでいる")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private enum NasneRegistrationListLayout {
    /// 行の中の名前と作り手の間
    static let rowSpacing: CGFloat = 2
}

/// nasne を足すシート（登録の画面を使い回す。登録が通ると足した台へ切り替わり、このシートを閉じる）
private struct AddNasneSheet: View {
    let model: DeviceSetupModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if SheetCloseLayout.closesAtTop { SheetTopCloseBar(close: close) }
            SetupView(model: model)
            if !SheetCloseLayout.closesAtTop {
                Divider()
                HStack {
                    Spacer()
                    Button("閉じる", action: close)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(SettingsSheetLayout.barPadding)
            }
        }
        .sheetResizableSize(minimum: SettingsSheetLayout.minimumSize, ideal: SettingsSheetLayout.idealSize)
    }
}
