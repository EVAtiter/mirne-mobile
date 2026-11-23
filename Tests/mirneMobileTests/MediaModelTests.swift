import Foundation
import Testing

// メディアの画面のモデル（共有フォルダーの動画・音楽・写真）。

/// 呼ばれた回数を数え、決めた中身か誤りを返す偽のメディアの一覧
fileprivate final class FakeMedia: MediaLibraryService, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    /// 投げる誤り（nil なら中身を返す）
    var failure: Error?

    var requested: [String] { lock.withLock { calls } }

    func root(kind: MediaKind) async throws -> MediaListing {
        lock.withLock { calls.append("root:\(kind.rawValue)") }
        if let failure { throw failure }
        return MediaListing(folders: [MediaFolder(id: "0/\(kind.rawValue)/folder/fol1", title: "share1", kind: kind)], files: [])
    }

    func listing(folderID: String, kind: MediaKind) async throws -> MediaListing {
        lock.withLock { calls.append(folderID) }
        if let failure { throw failure }
        let count = lock.withLock { files }
        return MediaListing(folders: [], files: (1...count).map {
            MediaFile(id: folderID + "/con\($0)", title: "試し\($0)", kind: kind, original: nil)
        })
    }

    /// フォルダーの中のファイルの数（試験の途中で変える）
    private var files = 1
    /// 中身の版（nil なら読めない）
    private var version: Int? = 1
    func setFiles(_ count: Int) { lock.withLock { files = count } }
    func setVersion(_ value: Int?) { lock.withLock { version = value } }

    func updateID() async throws -> Int {
        guard let version = lock.withLock({ version }) else { throw URLError(.timedOut) }
        return version
    }
}

@MainActor
@Suite("メディアの画面")
struct MediaModelTests {
    fileprivate let media = FakeMedia()

    func model() throws -> MediaModel {
        let registration = RegisteredNasne(host: NasneFixture.host, udn: "uuid:test", friendlyName: "test",
                                           macAddress: "00:00:5e:00:53:01")
        let real = try NasneServices.live(registration: registration, device: NasneDevice.direct(host: NasneFixture.host),
                                          client: MockHTTP())
        let services = NasneServices(registration: registration, deviceInfo: real.deviceInfo, schedules: real.schedules,
                                     titles: real.titles, programGuide: real.programGuide, liveCatalog: real.liveCatalog,
                                     media: media, nasneHomeURL: real.nasneHomeURL)
        return MediaModel(services: services)
    }

    @Test("見回り：中身の版が同じなら読まず、変われば今の場所を読み直してほかに覚えた場所を捨てる。版が読めなければ何もしない")
    func refreshWhenUpdateIDChanges() async throws {
        let model = try model()
        let folder = MediaFolder(id: "0/video/folder/fol1", title: "share1", kind: .video)
        await model.show(.root(.video))
        await model.show(.folder(folder))
        let before = media.requested.count
        await model.refreshIfChanged()
        #expect(media.requested.count == before)
        media.setFiles(2)
        media.setVersion(2)
        await model.refreshIfChanged()
        #expect(model.listing(at: .folder(folder)).value?.files.count == 2)
        #expect(model.listing(at: .root(.video)) == .idle)   // 捨てた（次に開いたときに読む）
        media.setFiles(3)
        media.setVersion(nil)
        await model.refreshIfChanged()
        #expect(model.listing(at: .folder(folder)).value?.files.count == 2)
    }

    @Test("種類の根を開くと共有フォルダーを読み、フォルダーを開くとその中を読む")
    func showsRootAndFolder() async throws {
        let model = try model()
        await model.show(.root(.music))
        let share = try #require(model.listing(at: .root(.music)).value?.folders.first)
        #expect(share.title == "share1")
        await model.show(.folder(share))
        #expect(model.listing(at: .folder(share)).value?.files.map(\.id) == ["0/music/folder/fol1/con1"])
        #expect(model.current == .folder(share))
        #expect(media.requested == ["root:music", "0/music/folder/fol1"])
    }

    @Test("読んだ場所へ戻っても読み直さない。更新を押したときだけ読み直す")
    func keepsLoadedListings() async throws {
        let model = try model()
        await model.show(.root(.photo))
        await model.show(.root(.photo))
        #expect(media.requested == ["root:photo"])
        await model.reload()
        #expect(media.requested == ["root:photo", "root:photo"])
    }

    @Test("読めなかった場所は誤りを知らせに出し、開き直すと読み直す。種類の画面へ戻ると知らせを外す")
    func failureAndRetry() async throws {
        let model = try model()
        media.failure = URLError(.timedOut)
        await model.show(.root(.video))
        #expect(model.loadError != nil)
        #expect(MainNotices.media(isLoading: model.isLoading, loadError: model.loadError)?.action == .reloadMedia)
        media.failure = nil
        await model.show(.root(.video))
        #expect(model.loadError == nil)
        #expect(model.listing(at: .root(.video)).value != nil)
        model.leave()
        #expect(model.current == nil)
        #expect(MainNotices.media(isLoading: model.isLoading, loadError: model.loadError) == nil)
    }
}

@Suite("メディアの画面から開くもの")
struct MediaSelectionTests {
    /// 合成の res（元のファイルの在りか）
    static func resource(_ path: String, mime: String) throws -> TitleResource {
        TitleResource(element: try XMLTree.parse(
            #"<res protocolInfo="http-get:*:\#(mime):DLNA.ORG_OP=01">http://192.0.2.1:58890\#(path)</res>"#, source: "test"))
    }

    static func file(_ id: String, _ kind: MediaKind, _ path: String?, mime: String) throws -> MediaFile {
        MediaFile(id: id, title: "試し \(id)", kind: kind, original: try path.map { try resource($0, mime: mime) })
    }

    @Test("写真はそのフォルダーの写真だけを nasne の並びで集め、選んだ 1 枚の位置を持つ（在りかの無い写真と写真でないものは除く）")
    func photoAlbum() throws {
        let files = [try Self.file("con1", .photo, "/web/photo/con1", mime: "image/jpeg"),
                     try Self.file("con2", .photo, nil, mime: "image/png"),
                     try Self.file("con3", .photo, "/web/photo/con3", mime: "image/png"),
                     try Self.file("con4", .photo, "/web/photo/con4", mime: "image/jpeg")]
        let album = try #require(MediaPhotoAlbum(files: files, selected: files[2]))
        #expect(album.photos.map(\.url.path) == ["/web/photo/con1", "/web/photo/con3", "/web/photo/con4"])
        #expect(album.index == 1)
        // 在りかの無い写真を選んでも開かない
        #expect(MediaPhotoAlbum(files: files, selected: files[1]) == nil)
    }

    @Test("動画と音楽は再生できる値を作り、写真と在りかの無いファイルは作らない")
    func playback() throws {
        #expect(MediaPlayback(file: try Self.file("con1", .video, "/web/video/con1", mime: "video/mp4"))?.url.path == "/web/video/con1")
        #expect(MediaPlayback(file: try Self.file("con2", .music, "/web/music/con2", mime: "audio/mpeg")) != nil)
        #expect(MediaPlayback(file: try Self.file("con3", .photo, "/web/photo/con3", mime: "image/jpeg")) == nil)
        #expect(MediaPlayback(file: try Self.file("con4", .music, nil, mime: "audio/mp4")) == nil)
    }
}
