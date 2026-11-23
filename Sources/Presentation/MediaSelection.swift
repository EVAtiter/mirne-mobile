import Foundation

// メディアの画面から開くもの（動画・音楽の再生、写真）。Mac は窓を開く値に使うので、保存できる形にする

/// 再生するメディアのファイル（動画・音楽）。Mac は窓を開く値に使うので、保存できる形にする
struct MediaPlayback: Codable, Hashable, Identifiable {
    var title: String
    /// 元のファイルの在りか（nasne の 58890 番。DTCP-IP は掛かっていない）
    var url: URL

    var id: URL { url }

    /// 再生できるファイルなら、その値（写真と、在りかの無いファイルは nil）
    init?(file: MediaFile) {
        guard file.kind != .photo, let url = file.original.flatMap({ URL(string: $0.url) }) else { return nil }
        title = file.title
        self.url = url
    }
}

/// 写真 1 枚（題と元のファイルの在りか）
struct MediaPhoto: Codable, Hashable {
    var title: String
    var url: URL
}

/// 開く写真：そのフォルダーの写真（nasne の並びのまま）と、選んだ 1 枚。Mac は窓を開く値に使うので、保存できる形にする
struct MediaPhotoAlbum: Codable, Hashable, Identifiable {
    var photos: [MediaPhoto]
    var index: Int

    var id: Self { self }

    /// フォルダーのファイルから作る（写真でない・在りかの無いファイルは除く）。選んだファイルが写真でなければ nil
    init?(files: [MediaFile], selected: MediaFile) {
        var photos: [MediaPhoto] = []
        var index: Int?
        for file in files where file.kind == .photo {
            guard let url = file.original.flatMap({ URL(string: $0.url) }) else { continue }
            if file.id == selected.id { index = photos.count }
            photos.append(MediaPhoto(title: file.title, url: url))
        }
        guard let index else { return nil }
        self.photos = photos
        self.index = index
    }
}
