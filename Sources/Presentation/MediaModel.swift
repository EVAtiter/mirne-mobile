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
/// 読んだ場所の中身は覚えておき、戻ったときは読み直さない（更新を押したときだけ読み直す）
@MainActor
@Observable
public final class MediaModel {
    /// 読んだ場所の中身
    public private(set) var listings: [MediaLocation: Loadable<MediaListing>] = [:]
    /// いま見ている場所（知らせと「もう一度読み込む」の対象）。種類を選ぶ前は nil
    public private(set) var current: MediaLocation?

    private let services: NasneServices

    public init(services: NasneServices) {
        self.services = services
    }

    /// 場所の中身（まだ読んでいなければ idle）
    public func listing(at location: MediaLocation) -> Loadable<MediaListing> {
        listings[location] ?? .idle
    }

    /// 場所を開く。まだ読んでいない（か、読めなかった）ときだけ読む
    public func show(_ location: MediaLocation) async {
        current = location
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
        guard let current else { return }
        await load(current)
    }

    /// いま見ている場所の読み込みの状態（知らせに使う）
    public var isLoading: Bool { current.map { listing(at: $0).isLoading } ?? false }
    public var loadError: ErrorPresentation? { current.flatMap { listing(at: $0).error } }

    private func load(_ location: MediaLocation) async {
        // 読み直すときは前の中身を出したままにせず、読み込み中にする（一覧が古いまま操作されないように）
        listings[location] = .loading
        let media = services.media
        do {
            let listing: MediaListing = switch location {
            case .root(let kind): try await media.root(kind: kind)
            case .folder(let folder): try await media.listing(folderID: folder.id, kind: folder.kind)
            }
            listings[location] = .loaded(listing)
        } catch {
            listings[location] = .failed(ErrorText.present(error))
        }
    }
}
