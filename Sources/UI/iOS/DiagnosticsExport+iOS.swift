import SwiftUI
import UIKit

/// 診断を渡すボタン（iOS 版）：共有のシートを出す（「ファイルに保存」・メールなど）
struct DiagnosticsExportControl: View {
    let file: DiagnosticsFile

    var body: some View {
        ShareLink(item: file, preview: SharePreview(DiagnosticsReport.fileName)) {
            Text("診断を書き出す…")
        }
    }
}

/// 診断の見出しに書く OS の名前（iOS 版）
enum DiagnosticsPlatform {
    @MainActor static var name: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
    }
}
