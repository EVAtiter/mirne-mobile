import Foundation
import OSLog

// 診断の書き出し：このアプリが書いたログを読み、文字のファイルにする（設定の「診断を書き出す」）。
//
// Mac を持たない人は iPhone・iPad のログを Console で取れないので、アプリが自分のログを読んで渡す（2026-11-25 に決めた）。
// 読めるのは、今のアプリが動き始めてからの、このアプリの subsystem のログだけ（OSLogStore の現在のプロセスの範囲。
// ほかのアプリや OS の部品のログ〔URL を含むことがある〕は読まない）。
// ログの中身はもともとアドレス・MAC・局名・番組名・資格情報を出さない決まりで書いている（`NasneDiagnostics`・`DTCPDiagnostics`）。
// 書き出す前に、アドレス・MAC・URL・UDN の形をした文字をもう一度伏せる（決まりを破るログが紛れても外へ出さない）

/// 診断の書き出し
enum DiagnosticsReport {
    /// ログの 1 行
    struct Entry: Equatable, Sendable {
        let date: Date
        let level: String
        let category: String
        let message: String
    }

    /// 書き出すログの最大の行数（新しいほうから残す。長く動かしたときにファイルが大きくなりすぎないように）
    static let maximumEntries = 20_000

    /// 書き出すファイルの名前
    static let fileName = "mirne-mobile-diagnostics.txt"

    /// 伏せた所に入れる文字
    enum Mask {
        static let address = "<アドレス>"
        static let mac = "<MAC>"
        static let url = "<URL>"
        static let udn = "<UDN>"
    }

    /// 見出し（`header`）と、今のアプリが動き始めてからのログを 1 つの文字にする。読めなかったときは、その旨を書く
    static func make(header: [String], now: Date = Date()) -> String {
        do {
            return render(header: header, entries: try readEntries(), now: now)
        } catch {
            return render(header: header + ["ログを読めませんでした（\(String(describing: type(of: error)))）"],
                          entries: [], now: now)
        }
    }

    /// 今のアプリが動き始めてからの、このアプリの subsystem のログ（古い順。多すぎれば新しいほうから `maximumEntries` 行）
    static func readEntries() throws -> [Entry] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@", AppLog.subsystem)
        var entries: [Entry] = []
        for case let log as OSLogEntryLog in try store.getEntries(matching: predicate) {
            entries.append(Entry(date: log.date, level: levelName(log.level), category: log.category,
                                 message: log.composedMessage))
        }
        return Array(entries.suffix(maximumEntries))
    }

    /// 見出し・書き出した時刻・ログの行を並べる。ログの行は伏せてから書く
    static func render(header: [String], entries: [Entry], now: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        var lines = header
        lines.append("書き出した時刻: \(formatter.string(from: now))")
        lines.append("ログ: \(entries.count) 行")
        lines.append("")
        for entry in entries {
            lines.append("\(formatter.string(from: entry.date)) \(entry.level) \(entry.category) \(redact(entry.message))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// アドレス・MAC・URL・UDN の形をした文字を伏せる（URL を先に。URL の中のアドレスを別々に伏せないため）
    static func redact(_ text: String) -> String {
        var result = text
        for (pattern, mask) in redactions {
            result = result.replacingOccurrences(of: pattern, with: mask, options: .regularExpression)
        }
        return result
    }

    /// 伏せる形（順に当てる）
    private static let redactions: [(String, String)] = [
        (#"[A-Za-z][A-Za-z0-9+.-]*://[^\s（）()「」・、。]+"#, Mask.url),
        (#"uuid:[0-9A-Fa-f-]+"#, Mask.udn),
        (#"(?<![0-9A-Fa-f:-])[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}(?![0-9A-Fa-f:-])"#, Mask.mac),
        (#"(?<![0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])"#, Mask.address),
    ]

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "-"
        }
    }
}
