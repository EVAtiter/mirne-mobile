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
        .commands { AppCommands(environment: environment) }
    }
}

/// 主ウィンドウの大きさ
enum MainWindowLayout {
    /// 初めて開くときの大きさ
    static let defaultSize = CGSize(width: 960, height: 640)
    /// これより小さくできない大きさ
    static let minimumSize = CGSize(width: 640, height: 420)
    /// これより狭いと、ツールバーの「ライブ」「設定」を文字なしのシンボルだけにする（体感の値。画面を見て決める）
    static let compactToolbarWidth: CGFloat = 860
}

/// 主ウィンドウの中身：登録していなければ発見・登録、していれば登録した nasne の画面
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    /// 主ウインドウの文字の大きさ（視聴ウィンドウには配らない）
    @AppStorage(MainWindowSettingsKey.textSize) private var textSize = MainTextSize.initial.rawValue

    var body: some View {
        VStack(spacing: 0) {
            if let services = environment.services, let channels = environment.channels {
                // nasne を探している知らせは、主ウインドウの知らせの帯（MainView）に出す
                // アドレスが変わって作り直したら、主ウインドウも開き直す（画面のモデルが前の部品を持っているため）
                MainView(services: services, channels: channels, library: environment.library, viewing: environment.viewing)
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

/// 主ウインドウを作り直す鍵（登録した nasne と、そのアドレス）
struct MainViewIdentity: Hashable {
    let udn: String
    let host: String
}

/// 主ウインドウの上の知らせの帯（nasne を探している帯を、全部の画面の読み込み中・誤り・操作の結果の知らせに広げた）。
/// 知らせを 1 行ずつ並べる。誤りとうまくいった知らせは閉じられる。窓の下端に置くので、線は各行の上に引く（2026-11-21 に上から下端へ移した）。
/// iPad でも同じ形にできる部品だけ
struct MainNoticeBar: View {
    let notices: [MainNotice]
    let perform: (MainNoticeAction) -> Void
    let dismiss: (MainNotice) -> Void

    var body: some View {
        if !notices.isEmpty {
            VStack(spacing: 0) {
                ForEach(notices) { notice in
                    Divider()
                    MainNoticeRow(notice: notice, perform: perform, dismiss: dismiss)
                }
            }
            .background(.bar)
        }
    }
}

/// 知らせの 1 行：印・題・説明（1 行。マウスを載せると全部）・ボタン・閉じる
private struct MainNoticeRow: View {
    let notice: MainNotice
    let perform: (MainNoticeAction) -> Void
    let dismiss: (MainNotice) -> Void

    var body: some View {
        HStack(spacing: MainNoticeLayout.spacing) {
            switch notice.kind {
            case .progress:
                ProgressView().controlSize(.small)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text(notice.title)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail = notice.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if let action = notice.action {
                Button(action.title) { perform(action) }
            }
            if notice.isDismissible {
                Button { dismiss(notice) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("この知らせを閉じる")
            }
        }
        .help(notice.detail.map { notice.title + "\n" + $0 } ?? notice.title)
        .padding(.horizontal, MainNoticeLayout.horizontalPadding)
        .padding(.vertical, MainNoticeLayout.verticalPadding)
    }
}

/// 知らせの帯の寸法（左右は画面の上の帯と同じ）
enum MainNoticeLayout {
    static let spacing: CGFloat = 8
    static let horizontalPadding: CGFloat = ScreenActionBarLayout.horizontalPadding
    static let verticalPadding: CGFloat = 6
}
