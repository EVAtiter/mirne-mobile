import Foundation
import Testing

// 主ウインドウの上の帯の知らせ。モデルの状態から作る知らせと、操作の結果の知らせ・閉じた知らせの扱い

@Suite("知らせの帯")
@MainActor
struct MainNoticeTests {
    private let failure = ErrorPresentation(title: "nasne に届きません", message: "確かめてください。", code: "unreachable", canRetry: true)

    @Test("nasne を探している間は読み込み中、見つからなければ探し直すのボタン付きの誤り")
    func connectionNotices() {
        #expect(MainNotices.connection(.connected) == nil)
        #expect(MainNotices.connection(.searching)?.kind == .progress)
        let notFound = MainNotices.connection(.notFound)
        #expect(notFound?.kind == .error)
        #expect(notFound?.action == .retryConnection)
    }

    @Test("録画一覧：読み込み中・更新中は進み具合、誤りは題に「録画一覧」を付けてもう一度読み込むのボタン、削除中は別の行")
    func recordingsNotices() {
        let loading = MainNotices.recordings(isLoading: true, loadError: nil, isRefreshing: false, refreshError: nil,
                                             isShowingSavedList: false, isDeleting: false)
        #expect(loading.map(\.title) == ["録画一覧を読み込んでいます…"])
        let failed = MainNotices.recordings(isLoading: false, loadError: failure, isRefreshing: false, refreshError: nil,
                                            isShowingSavedList: false, isDeleting: true)
        #expect(failed.count == 2)
        #expect(failed[0].title == "録画一覧：nasne に届きません")
        #expect(failed[0].detail == "確かめてください。（unreachable）")
        #expect(failed[0].action == .reloadRecordings)
        #expect(failed[1].title == "録画を削除しています…")
        // 更新できなかったときは、出している一覧が前回のものだと添える
        let stale = MainNotices.recordings(isLoading: false, loadError: nil, isRefreshing: false, refreshError: failure,
                                           isShowingSavedList: true, isDeleting: false)
        #expect(stale.first?.detail?.hasSuffix("前回取得した一覧を表示しています。") == true)
        #expect(MainNotices.recordings(isLoading: false, loadError: nil, isRefreshing: false, refreshError: nil,
                                       isShowingSavedList: false, isDeleting: false).isEmpty)
    }

    @Test("番組表：開けなければ誤り、更新中は進み具合、更新できなければ更新のボタン、済めば出さない")
    func guideNotices() {
        #expect(MainNotices.guide(canOpen: false, refreshState: nil)?.title == "番組表を開けません")
        #expect(MainNotices.guide(canOpen: true, refreshState: .fetching)?.kind == .progress)
        #expect(MainNotices.guide(canOpen: true, refreshState: .failed(failure))?.action == .refreshGuide)
        #expect(MainNotices.guide(canOpen: true, refreshState: .updated(at: Date(), changed: false)) == nil)
    }

    @Test("情報：読み込めなかった区画の最初の誤りを 1 つ出す")
    func infoNotices() {
        #expect(MainNotices.info(isLoading: true, errors: [failure])?.kind == .progress)
        #expect(MainNotices.info(isLoading: false, errors: [failure, failure])?.title == "情報：nasne に届きません")
        #expect(MainNotices.info(isLoading: false, errors: []) == nil)
    }

    @Test("閉じた状態の知らせは、同じ知らせが続く間は出さず、消えたら忘れる（また起きたら出す）")
    func dismissesStateNotices() {
        let center = MainNoticeCenter()
        let notice = MainNotices.schedules(isLoading: false, loadError: failure)!
        #expect(center.visible(state: [notice]) == [notice])
        center.dismiss(notice)
        #expect(center.visible(state: [notice]).isEmpty)
        center.forgetDismissed(notIn: [])
        #expect(center.visible(state: [notice]) == [notice])
    }

    @Test("操作の結果の知らせは状態の知らせの後ろに並び、同じ出どころは置き換え、閉じれば消える")
    func postsEvents() {
        let center = MainNoticeCenter()
        let first = MainNotice.error(id: "recordings.deletion", failure, prefix: "録画の削除")
        let second = MainNotice(id: "recordings.deletion", kind: .error, title: "別の誤り")
        let state = MainNotices.connection(.searching)!
        center.post(first)
        center.post(second)
        #expect(center.visible(state: [state]) == [state, second])
        center.dismiss(second)
        #expect(center.visible(state: [state]) == [state])
    }
}
