import Foundation
import Testing

// 録画のチャプター（X_GetTitleInfo の読み方と確かめ・前後への飛び方・つまみの印）。値は架空

/// Result の文書（item で包まない xsrs。根に 3 つの値）
private func result(count: String, time: String, pts: String = "123456") -> String {
    #"<?xml version="1.0"?><xsrs xmlns="urn:schemas-xsrs-org:metadata-1-0/x_srs/">"#
        + "<chapterNum>\(count)</chapterNum><chapterTime>\(time)</chapterTime><startPTS>\(pts)</startPTS></xsrs>"
}

@Suite("チャプターの読み方と確かめ")
struct TitleChaptersTests {
    @Test("1/45000 秒の点を秒に直し、1 秒未満に近い点は間引く")
    func parses() {
        let points = TitleChapters.usablePoints(result: result(count: "4", time: "0_22500_2700000_5400000"), durationSeconds: 300)
        #expect(points == [0, 60, 120])
    }

    @Test("壊れたデータはチャプターなし：startPTS が 33 ビット以上・数が合わない・数でない（桁あふれ）・減る・長さを超える")
    func rejects() {
        #expect(TitleChapters.points(result: result(count: "2", time: "0_2700000", pts: String(1 << 33)), durationSeconds: 300)
                == .failure(.ptsOutOfRange))
        #expect(TitleChapters.points(result: result(count: "3", time: "0_2700000"), durationSeconds: 300) == .failure(.countMismatch))
        #expect(TitleChapters.points(result: result(count: "2", time: "0_99999999999999999999999"), durationSeconds: 300)
                == .failure(.notNumber))
        #expect(TitleChapters.points(result: result(count: "2", time: "2700000_0"), durationSeconds: 300) == .failure(.decreasing))
        // 300 秒 × 1.02 = 306 秒を超える
        #expect(TitleChapters.points(result: result(count: "2", time: "0_13860000"), durationSeconds: 300) == .failure(.overrun))
        #expect(TitleChapters.points(result: result(count: "2", time: "0_13725000"), durationSeconds: 300) == .success([0, 305]))
        #expect(TitleChapters.points(result: "壊れた", durationSeconds: 300) == .failure(.unreadable))
        // 2 点に満たなければ画面では使わない
        #expect(TitleChapters.usablePoints(result: result(count: "1", time: "0"), durationSeconds: 300).isEmpty)
    }

    @Test("X_PvrControl の X_GetTitleInfo に一覧の ID を送って読む")
    func requests() async throws {
        let http = MockHTTP()
        let body = """
            <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
            <u:X_GetTitleInfoResponse xmlns:u="urn:schemas-s-bras-org:service:X_PvrControl:1">\
            <Result>\(XMLTree.escapeText(result(count: "3", time: "0_2700000_5400000")))</Result>\
            </u:X_GetTitleInfoResponse></s:Body></s:Envelope>
            """
        http.reply("/X_PvrControl", method: "POST", body: Data(body.utf8))
        let catalog = RecordingCatalogService(soap: SOAPTransport(client: http), device: NasneDevice.direct(host: NasneFixture.host))
        #expect(try await catalog.chapters(id: "12", durationSeconds: 300) == [0, 60, 120])
        let sent = String(decoding: try #require(http.sentRequests.first?.httpBody), as: UTF8.self)
        #expect(sent.contains("X_GetTitleInfo"))
        #expect(sent.contains("<TitleID>12</TitleID>"))
    }
}

@Suite("チャプターの前後への飛び方")
struct ChapterNavigationTests {
    let points: [Double] = [0, 60, 120, 300]

    @Test("次：今の位置より後の最初の点。最後の点より後なら無い")
    func next() {
        #expect(ChapterNavigation.next(points, from: 30) == 60)
        #expect(ChapterNavigation.next(points, from: 60) == 120)
        #expect(ChapterNavigation.next(points, from: 300) == nil)
    }

    @Test("前：点を過ぎて 2 秒までは、その前の点。それより後ならその点へ戻る")
    func previous() {
        #expect(ChapterNavigation.previous(points, from: 61) == 0)
        #expect(ChapterNavigation.previous(points, from: 62.5) == 60)
        #expect(ChapterNavigation.previous(points, from: 1) == nil)
    }

    @Test("つまみの印：長さに対する割合（長さを超える点は端）。長さが分からなければ無い")
    func fractions() {
        #expect(ChapterNavigation.fractions([0, 150, 400], duration: 300) == [0, 0.5, 1])
        #expect(ChapterNavigation.fractions(points, duration: nil).isEmpty)
    }
}
