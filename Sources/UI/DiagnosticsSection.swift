import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// 設定の「診断」：このアプリのログを文字のファイルに書き出す（iPhone・iPad・Mac で同じ手順）。
/// 渡し方は OS ごと（`DiagnosticsExportControl`。iOS は共有、Mac は保存のパネル）
struct DiagnosticsSection: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Section("診断") {
            DiagnosticsExportControl(file: DiagnosticsFile(header: header))
            SettingsNote("うまく動かないときに、このアプリの記録を書き出します。",
                         details: ["アプリを起動してからの記録です。起きたことを、アプリを終えずにそのまま書き出してください。",
                                   "nasne のアドレス・MAC アドレス・名前、局名・番組名、資格情報は含みません。"])
        }
    }

    /// OS の版（「27.2.1 (Build 24B156)」。OS の文字の頭の「Version 」は外す）
    private static var osVersion: String {
        let text = ProcessInfo.processInfo.operatingSystemVersionString
        return text.hasPrefix(osVersionPrefix) ? String(text.dropFirst(osVersionPrefix.count)) : text
    }

    /// OS の版の文字の頭の語
    private static let osVersionPrefix = "Version "

    /// 見出し：アプリの版・OS・登録した nasne の台数と作り手（本体名は書かない）
    private var header: [String] {
        let entries = environment.registrations.entries
        let makers = entries.map { NasneDisplayName.maker(of: $0.device) ?? DiagnosticsWording.unknownMaker }
        let counts = Dictionary(grouping: makers, by: { $0 }).map { "\($0.key) \($0.value.count)" }.sorted()
        let selected = environment.registrations.selected
            .map { NasneDisplayName.maker(of: $0.device) ?? DiagnosticsWording.unknownMaker } ?? "なし"
        return ["\(AppInfo.name) \(AppInfo.versionLabel)",
                "OS: \(DiagnosticsPlatform.name) \(Self.osVersion)",
                "登録した nasne: \(entries.count) 台（\(counts.joined(separator: "・"))）・見ている台: \(selected)"]
    }
}

/// 診断の見出しの言葉
enum DiagnosticsWording {
    /// 型番から作り手が分からない台
    static let unknownMaker = "不明"
}

/// 書き出す診断のファイル（中身は渡す時に作る。保存・共有を選んだ時点までのログが入る）
struct DiagnosticsFile: Transferable {
    let header: [String]

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .utf8PlainText) { file in
            Data(DiagnosticsReport.make(header: file.header).utf8)
        }
        .suggestedFileName(DiagnosticsReport.fileName)
    }
}
