import SwiftUI

/// 診断を渡すボタン（macOS 版）：保存のパネルで書き出す（Mac の共有のメニューには「保存」が無いため）
struct DiagnosticsExportControl: View {
    let file: DiagnosticsFile
    @State private var exporting = false

    var body: some View {
        HStack {
            Spacer()
            Button("診断を書き出す…") { exporting = true }
        }
        .fileExporter(isPresented: $exporting, item: file, contentTypes: [.utf8PlainText],
                      defaultFilename: DiagnosticsReport.fileName) { _ in }
    }
}

/// 診断の見出しに書く OS の名前（macOS 版）
enum DiagnosticsPlatform {
    static let name = "macOS"
}
