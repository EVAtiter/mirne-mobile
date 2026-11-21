import Foundation
import Observation
import os

// 局の一覧（nasne のチャンネル一覧。地上。`status/channelListGet`）を、録画・予約・番組表・ライブの画面で 1 つだけ持つ。
//
// 前は 4 つのモデルがそれぞれ nasne から取っていた（起動の後に最大 4 回、録画の ⌘R のたびにも 1 回）。
// ここで 1 回だけ取り、どの画面もこれを読む。録画の ⌘R・ライブのボタンで読み直すと、ほかの画面も同じ新しい一覧になる
// （2026-11-21）。AppKit・SwiftUI に依存させない。

/// 局の一覧（地上のチャンネル一覧）
@MainActor
@Observable
public final class ChannelCatalog {
    /// 地上のチャンネル一覧（並べ替える前の nasne の順）
    public private(set) var channels: Loadable<[Channel]> = .idle

    private let deviceInfo: any DeviceInfoService
    /// 読んでいる途中の読み込み（続けて頼まれたら、同じものを待つ）
    @ObservationIgnored private var loading: Task<Void, Never>?
    private static let logger = Logger(subsystem: AppLog.subsystem, category: "webapi")

    public init(deviceInfo: any DeviceInfoService) {
        self.deviceInfo = deviceInfo
    }

    /// 読む。読めていれば `reload` のときだけ読み直す（読めていなければ、失敗していても読み直す）。
    /// 読んでいる途中に呼ばれたら、同じ読み込みを待つ。読み直しに失敗したら、前の一覧を残す（一度も読めていなければ失敗にする）
    public func load(reload: Bool = false) async {
        if let loading {
            await loading.value
            return
        }
        guard channels.value == nil || reload else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.fetch()
        }
        loading = task
        await task.value
        loading = nil
    }

    private func fetch() async {
        if channels.value == nil { channels = .loading }
        do {
            channels = .loaded(try await deviceInfo.channels(broadcastingType: BroadcastingType.terrestrial))
        } catch {
            Self.logger.error("局の一覧を読めない: \(NasneDiagnostics.summary(error), privacy: .public)")
            if channels.value == nil { channels = .failed(ErrorText.present(error)) }
        }
    }
}
