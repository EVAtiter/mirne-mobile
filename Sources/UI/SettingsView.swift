import SwiftUI

/// 設定（登録した nasne と資格情報）
/// 設定のシート（主ウィンドウの中で開く。iPad と同じ形にするため）
struct SettingsSheet: View {
    let services: NasneServices
    let credentials: CredentialsModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 閉じる：iPad は左上の ×、macOS は下の「閉じる」
            if SheetCloseLayout.closesAtTop { SheetTopCloseBar(close: close) }
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
        .frame(minWidth: SettingsSheetLayout.minimumSize.width, idealWidth: SettingsSheetLayout.idealSize.width,
               minHeight: SettingsSheetLayout.minimumSize.height, idealHeight: SettingsSheetLayout.idealSize.height)
    }
}

/// シートの上に置く「閉じる」（左上の ×。iPad の閉じる操作は左上の × に揃える）。Esc でも閉じる
struct SheetTopCloseBar: View {
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
        .padding(.horizontal, SheetCloseLayout.horizontalPadding)
        .padding(.top, SheetCloseLayout.topPadding)
    }
}

/// 設定のシートの大きさ
enum SettingsSheetLayout {
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
        }
        .formStyle(.grouped)
        .settingsScrollerMargins()
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
            Text("保存した登録と、\(DeviceWording.thisDevice) に保存した番組表・録画一覧を消します。\(DeviceWording.thisDevice) の視聴の記録（見終わった・途中まで見た位置）も消えます。nasne の録画や予約は消えません。")
        }
    }
}
