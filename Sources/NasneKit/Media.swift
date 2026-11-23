// nasne のメディアサーバー（共有フォルダーの動画・音楽・写真）の一覧を読む。
//
// nasne は共有フォルダー（share1。外付け HDD は share2 の見込み）のファイルを、DMS の「ビデオ」「ミュージック」「フォト」
// それぞれの `…/folder` の木に、種類ごとに分けて出す（その種類のファイルが入ったフォルダーだけが出る。2026-11-23 に
// Buffalo 製で確かめた）。res は 58890 番の `/web/{video,music,photo}/con<n>` で、DTCP-IP は掛かっていない（ふつうの HTTP）。
// 一覧を読むのは録画やライブと同じ Browse で、別の読み方は作らない。

import Foundation

/// メディアの種類（DMS の木の 1 つ）
public enum MediaKind: String, Sendable, CaseIterable, Codable {
    case video
    case music
    case photo
}

/// メディアのフォルダー 1 つ（DIDL の container）
public struct MediaFolder: Sendable, Hashable, Identifiable {
    /// 例：`0/music/folder/fol1/fol6`
    public var id: String
    /// Finder のフォルダーの名前のまま（共有フォルダーの直下は「share1」など）
    public var title: String
    public var kind: MediaKind
}

/// メディアのファイル 1 つ（DIDL の item）
public struct MediaFile: Sendable, Equatable, Identifiable {
    /// 例：`0/photo/folder/fol1/fol5/con6`
    public var id: String
    /// ファイルの名前（nasne が拡張子を外したもの）
    public var title: String
    public var kind: MediaKind
    /// 元のファイルの res（縮小版でないもの）
    public var original: TitleResource?
    /// 写真の縮小版（nasne が作る。JPEG にだけ付く。無ければ nil）
    public var thumbnail: TitleResource?

    init(item: DIDLItem, kind: MediaKind, thumbnailConversion: String) {
        id = item.id
        title = item.title
        self.kind = kind
        original = item.resources.first { $0.conversion == nil }
        thumbnail = item.resources.first { $0.conversion == thumbnailConversion }
    }

    /// 値から作る（試験・プレビュー）
    public init(id: String, title: String, kind: MediaKind, original: TitleResource?, thumbnail: TitleResource? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.original = original
        self.thumbnail = thumbnail
    }
}

/// フォルダー 1 つの中身（nasne の並びのまま）
public struct MediaListing: Sendable, Equatable {
    public var folders: [MediaFolder]
    public var files: [MediaFile]

    public init(folders: [MediaFolder], files: [MediaFile]) {
        self.folders = folders
        self.files = files
    }
}

/// メディアの一覧を読む（DLNA の Browse だけ）
public struct DLNAMediaLibraryService: Sendable {
    private let catalog: RecordingCatalogService

    public init(catalog: RecordingCatalogService) {
        self.catalog = catalog
    }

    /// 木の在りか（種類ごとのフォルダーの木の根・縮小版の名前。機器の表）
    private var dlna: DLNATable { catalog.profile.dlna }

    /// 中身の版（ContentDirectory の SystemUpdateID）
    public func updateID() async throws -> Int {
        try await catalog.systemUpdateID()
    }

    /// 種類の木の根の中身（共有フォルダー。share1 など）
    public func root(kind: MediaKind) async throws -> MediaListing {
        try await listing(folderID: dlna.mediaFolderContainers[kind] ?? "", kind: kind)
    }

    /// フォルダー 1 つの中身
    public func listing(folderID: String, kind: MediaKind) async throws -> MediaListing {
        var folders: [MediaFolder] = []
        var files: [MediaFile] = []
        for entry in try await catalog.browseEntries(folderID) {
            switch entry {
            case .container(let container):
                folders.append(MediaFolder(id: container.id, title: container.title, kind: kind))
            case .item(let item):
                files.append(MediaFile(item: item, kind: kind, thumbnailConversion: dlna.mediaThumbnailConversion))
            }
        }
        return MediaListing(folders: folders, files: files)
    }
}
