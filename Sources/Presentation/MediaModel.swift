import Foundation
import Observation

/// メディアの画面で見ている場所（種類の木の根か、その下のフォルダー）
public enum MediaLocation: Hashable, Sendable {
    /// 種類の木の根（直下が共有フォルダー）
    case root(MediaKind)
    case folder(MediaFolder)

    public var kind: MediaKind {
        switch self {
        case .root(let kind): kind
        case .folder(let folder): folder.kind
        }
    }
}

/// メディアの画面のモデル。最初に種類（ビデオ・ミュージック・フォト）を選び、その下を nasne の木のままたどる。
/// 読んだ場所の中身は覚えておき、戻ったときは読み直さない。開いている間は中身の版（SystemUpdateID）を見回り、
/// 変わったら今の場所を読み直して、ほかに覚えている場所は捨てる（次に開いたときに読む）
@MainActor
@Observable
public final class MediaModel {
    /// 読んだ場所の中身
    public private(set) var listings: [MediaLocation: Loadable<MediaListing>] = [:]
    /// いま見ている場所（知らせと「もう一度読み込む」の対象）。種類を選ぶ前は nil
    public private(set) var current: MediaLocation?

    private let services: NasneServices
    /// 集約ステータスの見回り（つながっていない間は読まない。無ければいつでも読む）
    private let link: LiveStatusMonitor?
    /// 覚えている中身を読んだときの中身の版（読めなかったら nil）
    @ObservationIgnored private var knownUpdateID: Int?

    public init(services: NasneServices, link: LiveStatusMonitor? = nil) {
        self.services = services
        self.link = link
    }

    /// 場所の中身（まだ読んでいなければ idle）
    public func listing(at location: MediaLocation) -> Loadable<MediaListing> {
        listings[location] ?? .idle
    }

    /// 場所を開く。まだ読んでいない（か、読めなかった）ときだけ読む
    public func show(_ location: MediaLocation) async {
        current = location
        guard link.allowsNasneRequests else { return }
        switch listing(at: location) {
        case .loaded, .loading: return
        case .idle, .failed: await load(location)
        }
    }

    /// 種類を選ぶ画面へ戻った（知らせの対象を外す）
    public func leave() {
        current = nil
    }

    /// いま見ている場所を読み直す
    public func reload() async {
        guard let current, link.allowsNasneRequests else { return }
        await load(current)
    }

    /// 見回り：中身の版が前に読んだときと違えば、今の場所を読み込み中を挟まずに読み直し（中身が変わったときだけ差し替える）、
    /// ほかに覚えている場所は捨てる。版が読めない・今の場所をまだ読めていない・読んでいる途中は何もしない。
    /// 今の場所が読めなかったときは今の中身を残し、版も覚えない（次の見回りでもう一度）
    public func refreshIfChanged() async {
        guard link.allowsNasneRequests, let current, case .loaded(let shown) = listing(at: current),
              let version = try? await services.media.updateID(), version != knownUpdateID else { return }
        guard let latest = try? await read(current) else { return }
        // 待っている間に場所を移った・読み直したなら使わない
        guard self.current == current, case .loaded = listing(at: current) else { return }
        listings = listings.filter { $0.key == current }
        if latest != shown { listings[current] = .loaded(latest) }
        knownUpdateID = version
    }

    /// いま見ている場所の読み込みの状態（知らせに使う）
    public var isLoading: Bool { current.map { listing(at: $0).isLoading } ?? false }
    public var loadError: ErrorPresentation? { current.flatMap { listing(at: $0).error } }

    private func load(_ location: MediaLocation) async {
        // 読み直すときは前の中身を出したままにせず、読み込み中にする（一覧が古いまま操作されないように）
        listings[location] = .loading
        // 版は中身より先に読む（読んでいる間に変わったら、次の見回りで版の違いとして見つかる）
        let version = try? await services.media.updateID()
        do {
            listings[location] = .loaded(try await read(location))
            // 版が変わっていたら、ほかに覚えている場所は古いかもしれないので捨てる
            if let version, version != knownUpdateID {
                if knownUpdateID != nil { listings = listings.filter { $0.key == location } }
                knownUpdateID = version
            }
        } catch {
            listings[location] = .failed(ErrorText.present(error))
        }
    }

    /// 場所の中身を読む
    private func read(_ location: MediaLocation) async throws -> MediaListing {
        let media = services.media
        return switch location {
        case .root(let kind): try await media.root(kind: kind)
        case .folder(let folder): try await media.listing(folderID: folder.id, kind: folder.kind)
        }
    }
}

/// メディアの画面の見回り（体感の値）
public enum MediaRefresh {
    /// 開いている間に中身の版を読む間（頼みは ContentDirectory の GetSystemUpdateID を 1 回・約 15 ms）
    public static let checkInterval: Duration = .seconds(5)
}
