import SwiftUI

/// mirne mobile のエントリポイント。
///
/// 主ウィンドウは、登録していなければ発見・登録の画面、登録していれば中央の切り替えの画面（〜）。
@main
struct MirneMobileApp: App {
    /// 終了の前の後始末。部品の組み立て（起動時の 1 か所）もこれが持つ
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var environment: AppEnvironment { delegate.environment }

    var body: some Scene {
        Window("mirne mobile", id: MainWindowID.main) {
            RootView()
                .frame(minWidth: MainWindowLayout.minimumSize.width,
                       minHeight: MainWindowLayout.minimumSize.height)
                .environment(environment)
        }
        .defaultSize(MainWindowLayout.defaultSize)

        // 視聴ウィンドウ（映像だけ・操作部の重ね出し・16:9・全画面）
        Window("再生", id: ViewerWindowID.main) {
            ViewerView()
                .environment(environment)
                // 全画面を許す。ただしこれだけでは窓が「補助の窓」のままで全画面に入れなかったので、
                // 切り替える直前に ViewerView.allowFullScreen で主の窓へ書き換えている（2026-11-19）
                .windowFullScreenBehavior(.enabled)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(ViewerLayout.defaultSize)
        // 異常終了の後に起動すると、macOS の窓の復元が何も再生していない視聴ウィンドウを開いていた（2026-11-22）。
        // 視聴ウィンドウは再生を始めたときに開くものなので、復元しない
        .restorationBehavior(.disabled)
        .commands { AppCommands(environment: environment) }

        // メディア（共有フォルダー）の写真。開いたフォルダーの写真ごとに 1 つ（動画・音楽は「再生」の窓を共有する）
        WindowGroup("写真", id: MediaPhotoWindowID.main, for: MediaPhotoAlbum.self) { $album in
            if let album {
                MediaPhotoView(album: album)
            }
        }
        .defaultSize(MediaPhotoLayout.defaultSize)
        .restorationBehavior(.disabled)
    }
}

/// 主ウィンドウの中身：登録していなければ発見・登録、していれば登録した nasne の画面
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    /// 主ウインドウの文字の大きさ（視聴ウィンドウには配らない）
    @AppStorage(MainWindowSettingsKey.textSize) private var textSize = MainTextSize.initial.rawValue
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            if let services = environment.services, let channels = environment.channels {
                // nasne を探している知らせは、主ウインドウの知らせの帯（MainView）に出す
                // アドレスが変わって作り直したら、主ウインドウも開き直す（画面のモデルが前の部品を持っているため）
                MainView(services: services, channels: channels, logos: environment.channelLogos, library: environment.library, viewing: environment.viewing,
                         openViewer: { openWindow(id: ViewerWindowID.main) })
                    .id(MainViewIdentity(udn: services.registration.udn, host: services.registration.host))
            } else {
                SetupView(model: environment.makeSetupModel())
            }
            // 保存した登録を読めなかったとき（主ウインドウの知らせの帯と同じ形・同じ下端）
            if let restoreError = environment.restoreError {
                MainNoticeBar(notices: [.error(id: "restore", restoreError)], perform: { _ in }, dismiss: { _ in })
            }
        }
        .mainTextSize(MainTextSize.saved(textSize))
        // 位置と大きさの保存と復元
        .background(WindowAccessor(beforeShown: { environment.mainWindowPlacement.conceal($0) }) {
            environment.mainWindowPlacement.attach($0)
        })
    }
}
