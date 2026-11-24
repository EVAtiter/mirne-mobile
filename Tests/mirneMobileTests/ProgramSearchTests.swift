import Foundation
import Testing

// 番組の検索。番組名と短い説明・大文字と小文字と全角と半角を区別しない・放送中とこれからだけ・放送の始まりの順・ジャンルで絞る・空の語

struct ProgramSearchTests {
    /// 局（地上・テスト局1・テスト局2）
    private func station(_ serviceID: Int, name: String) -> Channel {
        Channel(broadcastingType: BroadcastingType.terrestrial, networkID: 0x7e00, transportStreamID: 0x7e00,
                serviceID: serviceID, serviceType: Channel.televisionServiceType, channelNumber: 1,
                serviceName: name, remoteControlKeyID: 1)
    }

    /// 基準の時刻（2026-11-25 18:00 JST）
    private let now = Date(timeIntervalSince1970: 1_795_597_200)

    /// `now` から `offsetMinutes` 分後に始まる番組
    private func event(_ id: UInt16, offsetMinutes: Int, minutes: Int? = 30, title: String, text: String = "",
                       genre: ProgramGenre? = nil) -> BroadcastEvent {
        BroadcastEvent(tableID: 0x50, serviceID: 0x41f0, eventID: id, start: now.addingTimeInterval(TimeInterval(offsetMinutes * 60)),
                       duration: minutes.map { $0 * 60 }, title: title, text: text, lossless: true, genre: genre)
    }

    @Test("番組名か短い説明に語を含む番組を出す")
    func titleOrText() {
        let source = ProgramSearchIndex.Source(channel: station(0x41f0, name: "テスト局1"), events: [
            event(1, offsetMinutes: 0, title: "朝の天気", text: ""),
            event(2, offsetMinutes: 30, title: "ドラマ", text: "天気の話"),
            event(3, offsetMinutes: 60, title: "ドラマ", text: "旅の話"),
        ])
        let results = ProgramSearchIndex(sources: [source]).results(for: "天気", now: now)
        #expect(results.map(\.event.eventID) == [1, 2])
    }

    @Test("大文字と小文字・全角と半角を区別しない")
    func caseAndWidthInsensitive() {
        let source = ProgramSearchIndex.Source(channel: station(0x41f0, name: "テスト局1"), events: [
            event(1, offsetMinutes: 0, title: "ＮＨＫスペシャル"),
            event(2, offsetMinutes: 30, title: "news ７"),
            event(3, offsetMinutes: 60, title: "ﾃｽﾄ番組"),
        ])
        #expect(ProgramSearchIndex(sources: [source]).results(for: "nhk", now: now).map(\.event.eventID) == [1])
        #expect(ProgramSearchIndex(sources: [source]).results(for: "ＮＥＷＳ 7", now: now).map(\.event.eventID) == [2])
        #expect(ProgramSearchIndex(sources: [source]).results(for: "テスト", now: now).map(\.event.eventID) == [3])
    }

    @Test("終わった番組は出さない。放送中は出す。終わりの分からない番組は始まりが後なら出す")
    func upcomingOnly() {
        let source = ProgramSearchIndex.Source(channel: station(0x41f0, name: "テスト局1"), events: [
            event(1, offsetMinutes: -60, title: "終わった番組"),
            event(2, offsetMinutes: -30, title: "終わりが今の番組"),
            event(3, offsetMinutes: -10, title: "放送中の番組"),
            event(4, offsetMinutes: 30, minutes: nil, title: "長さの分からない番組"),
            event(5, offsetMinutes: -30, minutes: nil, title: "長さの分からない始まった番組"),
        ])
        #expect(ProgramSearchIndex(sources: [source]).results(for: "番組", now: now).map(\.event.eventID) == [3, 4])
    }

    @Test("放送の始まりの順。同じ時刻なら局の並びの順")
    func order() {
        let first = ProgramSearchIndex.Source(channel: station(0x41f0, name: "テスト局1"), events: [
            event(1, offsetMinutes: 60, title: "番組A"),
            event(2, offsetMinutes: 0, title: "番組B"),
        ])
        let second = ProgramSearchIndex.Source(channel: station(0x41f1, name: "テスト局2"), events: [
            event(3, offsetMinutes: 0, title: "番組C"),
            event(4, offsetMinutes: 30, title: "番組D"),
        ])
        let results = ProgramSearchIndex(sources: [first, second]).results(for: "番組", now: now)
        #expect(results.map(\.event.eventID) == [2, 3, 4, 1])
        #expect(results.map(\.channel.serviceName) == ["テスト局1", "テスト局2", "テスト局2", "テスト局1"])
    }

    @Test("ジャンルで絞る（渡した判定が真を返す番組だけ）")
    func genreFilter() {
        let drama = ProgramGenre(major: 0x3, minor: 0x0)
        let anime = ProgramGenre(major: 0x7, minor: 0x0)
        let index = ProgramSearchIndex(sources: [ProgramSearchIndex.Source(channel: station(0x41f0, name: "テスト局1"), events: [
            event(1, offsetMinutes: 0, title: "番組", genre: drama),
            event(2, offsetMinutes: 30, title: "番組", genre: anime),
            event(3, offsetMinutes: 60, title: "番組"),
        ])])
        #expect(index.results(for: "番組", now: now).map(\.event.eventID) == [1, 2, 3])
        #expect(index.results(for: "番組", now: now, genre: { $0?.major == 0x7 }).map(\.event.eventID) == [2])
    }

    @Test("番組名の終わりと短い説明の始まりをまたいで当てない")
    func doesNotSpanFields() {
        let source = ProgramSearchIndex.Source(channel: station(0x41f0, name: "テスト局1"), events: [
            event(1, offsetMinutes: 0, title: "朝の", text: "天気"),
        ])
        #expect(ProgramSearchIndex(sources: [source]).results(for: "の天", now: now).isEmpty)
    }

    @Test("語は前後の空白を除く。空の語では何も出さない")
    func emptyQuery() {
        let source = ProgramSearchIndex.Source(channel: station(0x41f0, name: "テスト局1"), events: [event(1, offsetMinutes: 0, title: "番組")])
        #expect(ProgramSearchIndex(sources: [source]).results(for: "", now: now).isEmpty)
        #expect(ProgramSearchIndex(sources: [source]).results(for: "  \n", now: now).isEmpty)
        #expect(ProgramSearchIndex(sources: [source]).results(for: " 番組 ", now: now).count == 1)
    }

    @Test("結果の行の日時は日付と時間帯")
    func timeText() {
        #expect(ProgramSearchIndex.timeText(event(1, offsetMinutes: 0, title: "番組")) == "11/25(水) 18:00〜18:30")
    }
}
