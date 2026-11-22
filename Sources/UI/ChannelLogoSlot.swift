import Observation
import SwiftUI

// 録画・予約の一覧の行の頭に出す局のロゴ。
// ロゴの PNG（`ChannelLogoModel`）から絵を作るのは、中身が変わったときに 1 回だけ（行を描くたびには作らない）。
// 行の左端に決まった幅の枠を取り、ロゴの無い行（読む前・読めなかった局）も同じ幅を空けて列をそろえる

/// 局のロゴの絵（主画面が持ち、環境で行へ配る）
@MainActor
@Observable
final class ChannelLogoImages {
    private(set) var images: [ChannelLogoKey: Image] = [:]
    @ObservationIgnored private var revision = -1

    /// ロゴが変わっていたら絵を作り直す
    func update(from model: ChannelLogoModel?) {
        guard let model else {
            images = [:]
            revision = -1
            return
        }
        guard model.revision != revision else { return }
        images = model.logos.compactMapValues(GuideLogo.image(from:))
        revision = model.revision
    }
}

/// 行の頭のロゴの寸法（体感の値。画面で見て決める）
enum ChannelLogoLayout {
    /// 「標準」の文字の大きさのときのロゴの高さ（文字の大きさの設定に合わせて伸ばす）
    static let baseHeight: CGFloat = 24
    /// nasne のロゴの縦横比（64×36）
    static let aspectRatio: CGFloat = 64.0 / 36.0

    static func height(textScale: CGFloat) -> CGFloat {
        baseHeight * textScale / MainTextSize.standardScale
    }
}

/// 行の頭のロゴの枠
struct ChannelLogoSlot: View {
    /// 出す局（局が決まらない行は nil で、枠だけ空ける）
    let key: ChannelLogoKey?
    @Environment(ChannelLogoImages.self) private var images: ChannelLogoImages?
    @Environment(\.textScale) private var textScale

    var body: some View {
        let height = ChannelLogoLayout.height(textScale: textScale)
        Group {
            if let key, let image = images?.images[key] {
                image.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .accessibilityHidden(true)
            } else {
                Color.clear
            }
        }
        .frame(width: height * ChannelLogoLayout.aspectRatio, height: height)
    }
}

extension ScheduleChannel {
    /// この局のロゴの鍵
    var logoKey: ChannelLogoKey { ChannelLogoKey(broadcastingType: broadcastingType, serviceID: serviceID) }
}
