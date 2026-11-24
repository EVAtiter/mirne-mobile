import SwiftUI

/// iOS 版（iPad・iPhone）の入口。部品の組み立て（`AppEnvironment`）は macOS 版と共通で、ここで 1 回だけ作る
@main
struct MirneMobileiOSApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            IPadRootView()
                .environment(environment)
        }
        // メニューバー（iPadOS 26 から）とキーボードのショートカット：主画面の操作だけ
        .commands { IPadCommands(environment: environment) }
    }
}

/// 最初の画面：登録が無ければ登録の画面、あれば主画面（macOS の主ウインドウと同じ形）
struct IPadRootView: View {
    @Environment(AppEnvironment.self) private var environment
    /// 文字の大きさ（macOS の主ウインドウと同じ設定の鍵）
    @AppStorage(MainWindowSettingsKey.textSize) private var textSize = MainTextSize.initial.rawValue
    /// 再生の画面を出しているか（主画面の上に全画面で重ねる）
    @State private var showsViewer = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack {
                if let services = environment.services, let channels = environment.channels, let liveStatus = environment.liveStatus {
                    // アドレスが変わって作り直したら、主画面も開き直す（画面のモデルが前の部品を持っているため）
                    MainView(services: services, liveStatus: liveStatus, channels: channels, logos: environment.channelLogos, library: environment.library, viewing: environment.viewing,
                             openViewer: { showsViewer = true })
                        .id(MainViewIdentity(udn: services.registration.udn, host: services.registration.host))
                        .navigationBarTitleDisplayMode(.inline)
                } else {
                    SetupView(model: environment.makeSetupModel())
                        .navigationTitle("mirne mobile")
                }
            }
            // 保存した登録を読めなかったとき（主画面の知らせの帯と同じ形・同じ下端）
            if let restoreError = environment.restoreError {
                MainNoticeBar(notices: [.error(id: "restore", restoreError)], perform: { _ in }, dismiss: { _ in })
            }
        }
        .mainTextSize(MainTextSize.saved(textSize))
        // 再生の画面（閉じると再生を終える。macOS で視聴ウィンドウを閉じたときと同じ）
        .fullScreenCover(isPresented: $showsViewer) {
            ViewerView { showsViewer = false }
                .environment(environment)
        }
    }
}
