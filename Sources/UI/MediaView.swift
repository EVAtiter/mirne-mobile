import SwiftUI

/// メディア（nasne の共有フォルダーの動画・音楽・写真）。最初に種類を選び、その下を nasne の木のままたどる。
/// nasne は共有フォルダーを種類ごとに 3 つの木で出すので、種類を選んでから共有フォルダー（share1 など）に入る。
/// たどった道は画面の中で持ち、上の帯の「戻る」で 1 つ上へ戻る（主ウインドウの上の帯とは別にする）
struct MediaView: View {
    @State var model: MediaModel
    /// 再生の窓（画面）を開く。無ければ動画・音楽を押しても再生しない
    let openViewer: (() -> Void)?
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    /// たどった道（空なら種類を選ぶ画面）
    @State private var path: [MediaLocation] = []
    /// 開く写真（そのフォルダーの写真と、選んだ 1 枚）
    @State private var album: MediaPhotoAlbum?

    var body: some View {
        VStack(spacing: 0) {
            ScreenActionBar(hasLeading: !path.isEmpty) {
                if !path.isEmpty {
                    Button { goBack() } label: { Label("戻る", systemImage: MediaSymbol.back) }
                        .help("1 つ上へ戻る")
                        .barButtonChrome()
                    BarStatusText(text: path.last.map(title(of:)) ?? "")
                }
            }
            if let location = path.last {
                listing(location)
            } else {
                kinds
            }
        }
        .navigationTitle("メディア")
        // 開いていて前面にある間、中身の版（SystemUpdateID）を見回り、変わったら今の場所を読み直す
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: MediaRefresh.checkInterval)
                await model.refreshIfChanged()
            }
        }
        .mediaPresentation($album, windowID: MediaPhotoWindowID.main) { MediaPhotoView(album: $0) }
        .onChange(of: environment.mainCommands.pending, initial: true) {
        }
    }

    // MARK: 種類を選ぶ

    private var kinds: some View {
        List {
            ForEach(MediaKind.allCases, id: \.self) { kind in
                Button { open(.root(kind)) } label: {
                    MediaRowLabel(title: kind.title, symbol: kind.symbol, detail: nil, showsDisclosure: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: フォルダーの中身

    @ViewBuilder
    private func listing(_ location: MediaLocation) -> some View {
        let state = model.listing(at: location)
        if let listing = state.value {
            if listing.folders.isEmpty && listing.files.isEmpty {
                ContentUnavailableView("何もありません", systemImage: location.kind.symbol,
                                       description: Text("このフォルダーに\(location.kind.title)のファイルはありません。"))
            } else {
                List {
                    ForEach(listing.folders) { folder in
                        Button { open(.folder(folder)) } label: {
                            MediaRowLabel(title: folder.title, symbol: MediaSymbol.folder, detail: nil, showsDisclosure: true)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(listing.files) { file in
                        if let playback = MediaPlayback(file: file), let openViewer {
                            // 再生の窓は録画・ライブと共有する（録画・ライブを見ていれば止めて替える）
                            Button {
                                environment.playMedia(playback)
                                openViewer()
                            } label: { MediaFileRow(file: file) }
                                .buttonStyle(.plain)
                                .help("再生する")
                        } else if let photos = MediaPhotoAlbum(files: listing.files, selected: file) {
                            Button { album = photos } label: { MediaFileRow(file: file) }
                                .buttonStyle(.plain)
                                .help("写真を開く")
                        } else {
                            MediaFileRow(file: file)
                        }
                    }
                }
            }
        } else {
            // 読み込み中・読めなかったことは知らせの板に出す
            Color.clear
        }
    }

    // MARK: たどる

    private func open(_ location: MediaLocation) {
        path.append(location)
        Task { await model.show(location) }
    }

    private func goBack() {
        path.removeLast()
        if let location = path.last {
            Task { await model.show(location) }
        } else {
            model.leave()
        }
    }

    private func title(of location: MediaLocation) -> String {
        switch location {
        case .root(let kind): kind.title
        case .folder(let folder): folder.title
        }
    }
}

/// 一覧の 1 行の見た目（絵・名前・補足・右端の「>」）
private struct MediaRowLabel: View {
    let title: String
    let symbol: String
    let detail: String?
    let showsDisclosure: Bool

    var body: some View {
        HStack(spacing: MediaLayout.rowSpacing) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: MediaLayout.thumbnailSize, height: MediaLayout.thumbnailSize)
            MediaRowText(title: title, detail: detail)
            if showsDisclosure {
                Image(systemName: MediaSymbol.disclosure).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// 行の名前と補足
private struct MediaRowText: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: MediaLayout.textSpacing) {
            Text(title).lineLimit(1)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// ファイルの行。写真は nasne が作る縮小版を出し、無ければ種類の絵
private struct MediaFileRow: View {
    let file: MediaFile

    var body: some View {
        HStack(spacing: MediaLayout.rowSpacing) {
            thumbnail
                .frame(width: MediaLayout.thumbnailSize, height: MediaLayout.thumbnailSize)
                .clipShape(RoundedRectangle(cornerRadius: MediaLayout.thumbnailCornerRadius))
            MediaRowText(title: file.title, detail: MediaFileDetail.text(file))
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = file.thumbnail.flatMap({ URL(string: $0.url) }) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: file.kind.symbol).foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: file.kind.symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

/// ファイルの行の補足（長さ・解像度・大きさのうち分かるもの）
enum MediaFileDetail {
    static func text(_ file: MediaFile) -> String? {
        guard let original = file.original else { return nil }
        var parts: [String] = []
        if let seconds = original.durationSeconds { parts.append(duration(seconds)) }
        if let resolution = original.resolution { parts.append(resolution.replacingOccurrences(of: "x", with: " × ")) }
        if let size = original.size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }

    /// 長さ（1 時間を超えれば時:分:秒、ほかは分:秒）
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

extension MediaKind {
    /// 画面の名前（nasne の容器の名前と同じ）
    var title: String {
        switch self {
        case .video: "ビデオ"
        case .music: "ミュージック"
        case .photo: "フォト"
        }
    }

    var symbol: String {
        switch self {
        case .video: "film"
        case .music: "music.note.list"
        case .photo: "photo"
        }
    }
}

/// メディアの画面の絵
enum MediaSymbol {
    static let back = "chevron.backward"
    static let folder = "folder"
    static let disclosure = "chevron.forward"
}

/// メディアの画面の寸法（体感の値。画面で見て決める）
enum MediaLayout {
    /// 行の絵（写真は縮小版）の一辺
    static let thumbnailSize: CGFloat = 40
    static let thumbnailCornerRadius: CGFloat = 4
    /// 行の絵と文字の間
    static let rowSpacing: CGFloat = 10
    /// 名前と補足の間
    static let textSpacing: CGFloat = 2
}
