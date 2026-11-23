import SwiftUI

/// 写真を大きく出す。前後の写真へ送る（ボタン・← →・iPhone と iPad は横のスワイプ）、拡大（つまむ・ダブルクリック〔タップ〕で 2 倍と元の大きさ）。
/// 前後へ送ると拡大を戻す
struct MediaPhotoView: View {
    let album: MediaPhotoAlbum
    @State private var index: Int
    /// 拡大の倍率（1 が画面に合わせた大きさ）
    @State private var scale: CGFloat = 1
    /// つまんでいる間の倍率（指を離したら `scale` に掛ける）
    @GestureState private var pinch: CGFloat = 1

    init(album: MediaPhotoAlbum) {
        self.album = album
        _index = State(initialValue: min(max(album.index, 0), max(album.photos.count - 1, 0)))
    }

    private var photo: MediaPhoto? { album.photos.indices.contains(index) ? album.photos[index] : nil }

    var body: some View {
        ZStack {
            Color.black
            if let photo {
                AsyncImage(url: photo.url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                            .scaleEffect(min(max(scale * pinch, MediaPhotoLayout.minimumScale), MediaPhotoLayout.maximumScale))
                    case .failure:
                        Label("写真を読み込めませんでした", systemImage: "exclamationmark.triangle").foregroundStyle(.white)
                    default:
                        ProgressView().tint(.white)
                    }
                }
                .id(photo.url)
            }
        }
        .contentShape(Rectangle())
        .gesture(MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                scale = min(max(scale * value.magnification, MediaPhotoLayout.minimumScale), MediaPhotoLayout.maximumScale)
            })
        .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : MediaPhotoLayout.doubleTapScale } }
        .simultaneousGesture(DragGesture(minimumDistance: MediaPhotoLayout.swipeDistance).onEnded { value in
            // 拡大していないときだけ、横のスワイプで前後へ送る
            guard scale <= 1, abs(value.translation.width) > abs(value.translation.height) else { return }
            move(value.translation.width < 0 ? 1 : -1)
        })
        .overlay(alignment: .bottom) { controls }
        .navigationTitle(photo.map { "\($0.title)（\(index + 1) / \(album.photos.count)）" } ?? "写真")
    }

    /// 下の「前へ」「n / N」「次へ」
    private var controls: some View {
        HStack(spacing: MediaPhotoLayout.controlSpacing) {
            Button { move(-1) } label: { Image(systemName: "chevron.backward") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(index <= 0)
                .help("前の写真")
            Text("\(index + 1) / \(album.photos.count)")
                .monospacedDigit()
            Button { move(1) } label: { Image(systemName: "chevron.forward") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(index >= album.photos.count - 1)
                .help("次の写真")
        }
        .padding(.horizontal, MediaPhotoLayout.controlPadding)
        .padding(.vertical, MediaPhotoLayout.controlPadding / 2)
        .mainFloatingBackground(Capsule())
        .padding(.bottom, MediaPhotoLayout.controlBottomMargin)
    }

    private func move(_ step: Int) {
        let next = index + step
        guard album.photos.indices.contains(next) else { return }
        index = next
        scale = 1
    }
}

/// Mac の写真の窓
enum MediaPhotoWindowID {
    static let main = "media-photo"
}

/// 写真の画面の寸法と倍率（体感の値。画面で見て決める）
enum MediaPhotoLayout {
    /// Mac の窓の最初の大きさ
    static let defaultSize = CGSize(width: 900, height: 650)
    static let minimumScale: CGFloat = 1
    static let maximumScale: CGFloat = 5
    /// ダブルクリック（タップ）で拡大するときの倍率
    static let doubleTapScale: CGFloat = 2
    /// 横のスワイプと見なす動きの長さ
    static let swipeDistance: CGFloat = 30
    /// 下の操作の板
    static let controlSpacing: CGFloat = 16
    static let controlPadding: CGFloat = 16
    static let controlBottomMargin: CGFloat = 20
}
