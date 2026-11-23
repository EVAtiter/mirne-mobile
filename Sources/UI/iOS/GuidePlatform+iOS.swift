import SwiftUI
import UIKit

// 番組表の OS ごとの部分（iPad 版）：スクロールバーの右の余白・マウスを置いたときの吹き出し・局のロゴの絵

extension View {
    /// 番組表の右端の余白（iPad 版：スクロールバーは細く、押すものに重ならないので余らせない）
    func guideTrailingScrollerInset() -> some View {
        self
    }

    /// マウスを置いたときの吹き出しのための見張り（iPad 版：吹き出しは出さないので見張らない。番組を押すとシートを出す）
    func guidePointerHover(_ action: @escaping (HoverPhase) -> Void) -> some View {
        self
    }

    /// 斜めのスワイプでも自由に動かす（iOS 版：OS のスクロールは元から向きを絞らないので何もしない）
    func guideFreeScrolling() -> some View {
        self
    }

    /// 吹き出しの窓がスクロールの操作を受けたら知らせる（iPad 版：吹き出しを出さないので見張らない）
    func popoverScrollWatcher(_ onScroll: @escaping () -> Void) -> some View {
        self
    }
}

/// 番組表の帯の前後の日のボタン（iOS 版）：ふつうのボタン 2 つを、帯のほかのボタンと同じ丸い板にまとめる。
/// macOS と同じ `ControlGroup` は、上の帯を出さない iPad の帯で押しても動かなかった（日付のメニューは動いた。2026-11-23）
struct GuideDaySteppers: View {
    let canGoBack: Bool
    let canGoForward: Bool
    let move: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button("前の日", systemImage: "chevron.left") { move(-1) }
                .disabled(!canGoBack)
            Button("次の日", systemImage: "chevron.right") { move(1) }
                .disabled(!canGoForward)
        }
        .labelStyle(.iconOnly)
        .barButtonGroupChrome()
        .fixedSize()
    }
}

/// 局のロゴの絵（iPad 版）
enum GuideLogo {
    static func image(from data: Data) -> Image? {
        UIImage(data: data).map { Image(uiImage: $0) }
    }
}
