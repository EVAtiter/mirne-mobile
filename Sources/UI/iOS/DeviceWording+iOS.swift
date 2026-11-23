import UIKit

/// 画面の文言で、この端末と画面を指す言い方（iOS 版）
enum DeviceWording {
    /// この端末（iPhone では「この iPhone」、それ以外〔iPad〕は「この iPad」。前は iPhone でも「この iPad」だった。2026-11-23）
    @MainActor static var thisDevice: String {
        UIDevice.current.userInterfaceIdiom == .phone ? "この iPhone" : "この iPad"
    }
    /// 主画面（番組表・予約・録画・情報）
    static let mainScreen = "主画面"
    /// 再生の画面（再生とライブ）
    static let viewerScreen = "再生の画面"
    /// 再生の画面を短く言うとき（「… を閉じるまで」）
    static let viewerScreenShort = "画面"
}
