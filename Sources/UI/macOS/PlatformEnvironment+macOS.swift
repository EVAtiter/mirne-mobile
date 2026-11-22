/// OS ごとの部品（macOS 版）。視聴ウィンドウの窓・主ウインドウの位置・スリープの見張りを持つ
@MainActor
final class PlatformEnvironment {
    /// 視聴ウィンドウの窓（標準の大きさに戻す。メニューからも届くようにここに置く）
    let viewerWindow = ViewerWindowController()
    /// 主ウインドウの位置と大きさの保存と復元
    let mainWindowPlacement = WindowPlacementController(key: WindowPlacementKey.main, name: "主ウインドウ",
                                                        minimumSize: MainWindowLayout.minimumSize)
    /// スリープの前に受信を閉じる
    private let powerObserver: PowerObserver

    init(playback: PlaybackController, renderer: VideoRenderer?) {
        powerObserver = PowerObserver(playback: playback, renderer: renderer)
    }
}

extension AppEnvironment {
    /// 視聴ウィンドウの窓
    var viewerWindow: ViewerWindowController { platform.viewerWindow }
    /// 主ウインドウの位置と大きさの保存と復元
    var mainWindowPlacement: WindowPlacementController { platform.mainWindowPlacement }

    /// 実機に向けた組み立て（ディスプレイのスリープは IOPMAssertion で止める。nasne は SSDP で探し、/24 の走査は選んだときだけ）
    static func live() -> AppEnvironment {
        live(displaySleepAssertion: IOPMDisplaySleepAssertion(), usesSSDP: true)
    }
}
