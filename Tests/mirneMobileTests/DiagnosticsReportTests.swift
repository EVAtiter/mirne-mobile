import Foundation
import os
import Testing

// 診断の書き出し（設定の「診断を書き出す」）の整形と伏せ方。
// 私設のアドレスは漏れ検査に掛からないよう、数の並びから組み立てる

@Suite("診断の書き出し")
struct DiagnosticsReportTests {
    private static let privateAddress = [192, 168, 1, 23].map(String.init).joined(separator: ".")
    private static let documentationAddress = [203, 0, 113, 5].map(String.init).joined(separator: ".")

    @Test("アドレス・URL・UDN・MAC の形を伏せる。URL の中のアドレスは URL ごと伏せる")
    func redactsIdentifiers() {
        let address = Self.privateAddress
        let text = "記述 http://\(address):64210/XD/uuid-x（取得）・\(Self.documentationAddress) へ・uuid:4c494e55-0000-0001・MAC 00:00:5e:00:53:01・00-00-5E-00-53-02"
        let redacted = DiagnosticsReport.redact(text)
        #expect(!redacted.contains(address))
        #expect(!redacted.contains(Self.documentationAddress))
        #expect(!redacted.contains("uuid:4c49"))
        #expect(!redacted.contains("00:00:5e"))
        #expect(!redacted.contains("00-00-5E"))
        #expect(redacted == "記述 \(DiagnosticsReport.Mask.url)（取得）・\(DiagnosticsReport.Mask.address) へ・\(DiagnosticsReport.Mask.udn)・MAC \(DiagnosticsReport.Mask.mac)・\(DiagnosticsReport.Mask.mac)")
    }

    @Test("版・時間・件数・SOAP のアクションなど、伏せなくてよいものは変えない")
    func keepsOrdinaryText() {
        let text = "走査: /24 の 1 / 2 個目・nasne 3 台・3204 ms・HTTP 200・版 1.6.1（ビルド 18）・27.2.1・X_GetTitleList 200 件"
        #expect(DiagnosticsReport.redact(text) == text)
    }

    @Test("見出し・書き出した時刻・行数のあとに、時刻・水準・カテゴリ・伏せた本文を 1 行ずつ並べる")
    func rendersLines() {
        let utc = TimeZone(identifier: "UTC")!
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = [
            DiagnosticsReport.Entry(date: base, level: "info", category: "discovery", message: "走査: nasne 3 台"),
            DiagnosticsReport.Entry(date: base.addingTimeInterval(1.25), level: "error", category: "playback",
                                    message: "届かない \(Self.privateAddress)"),
        ]
        let text = DiagnosticsReport.render(header: ["mirne mobile 1.6.1（ビルド 18）"], entries: entries,
                                            now: base.addingTimeInterval(60), timeZone: utc)
        #expect(text == """
        mirne mobile 1.6.1（ビルド 18）
        書き出した時刻: 2027-01-15 08:01:00.000
        ログ: 2 行

        2027-01-15 08:00:00.000 info discovery 走査: nasne 3 台
        2027-01-15 08:00:01.250 error playback 届かない \(DiagnosticsReport.Mask.address)

        """)
    }

    @Test("このアプリの subsystem で書いたログを、同じプロセスの中から読める")
    func readsOwnLogs() throws {
        let marker = "診断の試験 \(UUID().uuidString.prefix(8))"
        Logger(subsystem: AppLog.subsystem, category: "test").notice("\(marker, privacy: .public)")
        Logger(subsystem: "com.example.other", category: "test").notice("\(marker, privacy: .public) ほか")
        let entries = try DiagnosticsReport.readEntries()
        #expect(entries.contains { $0.message == marker && $0.category == "test" && $0.level == "notice" })
        #expect(!entries.contains { $0.message.hasSuffix("ほか") })
    }
}
