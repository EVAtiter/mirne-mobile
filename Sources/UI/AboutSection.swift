import SwiftUI

/// 設定の最後の「このアプリについて」：名前・版・権利の表記と、使っている部品の許諾文。
/// iOS には Mac の「mirne mobile について」の画面が無いので、どの OS でも設定に出す（Mac はメニューの画面も残る）。
/// 文字は Info.plist（名前・版・権利）と同梱の文書から読み、ここには書かない
struct AboutSection: View {
    /// 開いている許諾文
    @State private var document: AboutDocument?

    var body: some View {
        Section("このアプリについて") {
            LabeledContent("名前", value: AppInfo.name)
            LabeledContent("版", value: AppInfo.versionLabel)
            if let copyright = AppInfo.copyright {
                Text(copyright)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // 同梱している文書だけ出す（FFmpeg の許諾文は iOS 版だけにある）
            ForEach(AboutDocument.allCases.filter(\.isBundled)) { document in
                Button(document.title) { self.document = document }
            }
        }
        .sheet(item: $document) { document in
            AboutDocumentSheet(document: document) { self.document = nil }
        }
    }
}

/// Info.plist から読むアプリの名前・版・権利の表記
enum AppInfo {
    private static func string(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    static var name: String { string("CFBundleDisplayName") ?? string("CFBundleName") ?? "" }

    /// 「1.2.0（ビルド 11）」
    static var versionLabel: String {
        let version = string("CFBundleShortVersionString") ?? ""
        guard let build = string("CFBundleVersion") else { return version }
        return "\(version)（ビルド \(build)）"
    }

    static var copyright: String? { string("NSHumanReadableCopyright") }
}

/// アプリに同梱している許諾の文書
enum AboutDocument: String, CaseIterable, Identifiable {
    /// 受け継いだソース（mirne・coax・torne mobile HB など）と同梱した部品の一覧と許諾
    case notice
    /// FFmpeg の LGPL-2.1 の全文（iOS 版だけ）
    case ffmpegLicense

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notice: "使っている部品と許諾"
        case .ffmpegLicense: "FFmpeg の許諾（LGPL 2.1）"
        }
    }

    private var resource: (name: String, extension: String?) {
        switch self {
        case .notice: ("NOTICE", nil)
        case .ffmpegLicense: ("FFmpeg-COPYING.LGPLv2.1", "txt")
        }
    }

    var url: URL? { Bundle.main.url(forResource: resource.name, withExtension: resource.extension) }
    var isBundled: Bool { url != nil }

    func text() -> String {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }
}

/// 許諾の文書を読むシート（英文のまま。等幅で、選んで写せる）
private struct AboutDocumentSheet: View {
    let document: AboutDocument
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 閉じる：iPad・iPhone は左上の ×、macOS は下の「閉じる」（設定のシートと同じ）
            if SheetCloseLayout.closesAtTop { SheetTopCloseBar(close: close) }
            ScrollView {
                Text(document.text())
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AboutDocumentLayout.textPadding)
            }
            if !SheetCloseLayout.closesAtTop {
                Divider()
                HStack {
                    Spacer()
                    Button("閉じる", action: close)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(SettingsSheetLayout.barPadding)
            }
        }
        // Mac のシートの窓の大きさ（iOS はシートの大きさを OS が決める）
        .sheetResizableSize(minimum: AboutDocumentLayout.minimumSize, ideal: AboutDocumentLayout.idealSize)
    }
}

/// 許諾の文書のシートの寸法（体感の値。画面で見て決める）
enum AboutDocumentLayout {
    static let textPadding: CGFloat = 16
    /// Mac のシートの窓（NOTICE は 80 桁の英文なので、等幅で 1 行が折り返さない幅を最初の幅にする）
    static let minimumSize = CGSize(width: 480, height: 400)
    static let idealSize = CGSize(width: 680, height: 600)
}
