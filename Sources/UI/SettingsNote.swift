import SwiftUI

/// 設定の欄の説明。1 行だけ出し、続きは「?」を押すと吹き出しで出す（1 行に収まる説明は `details` を空にする）。
///
/// mirne の `SettingsNote`（Sources/mirne/SettingsView.swift）を写した。文字の大きさは主ウインドウの文字の大きさに合わせる（`scaledFont`）。
/// 吹き出しは iPad にもある部品で、「?」はボタンなので、タップでも届く
struct SettingsNote: View {
    let summary: String
    let details: [String]
    @State private var showsDetails = false

    init(_ summary: String, details: [String] = []) {
        self.summary = summary
        self.details = details
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsNoteLayout.spacing) {
            Text(summary)
            if !details.isEmpty {
                Button {
                    showsDetails.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("説明を表示")
                .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: SettingsNoteLayout.detailSpacing) {
                        ForEach(details, id: \.self) { Text($0) }
                    }
                    .scaledFont(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: SettingsNoteLayout.popoverWidth, alignment: .leading)
                    .padding()
                }
            }
        }
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
    }
}

/// 設定の欄の説明の寸法
enum SettingsNoteLayout {
    /// 1 行の説明と「?」の間
    static let spacing: CGFloat = 4
    /// 吹き出しの中の段落の間
    static let detailSpacing: CGFloat = 8
    /// 吹き出しの幅（設定のシートの最小の幅 480 より狭く。mirne と同じ値）
    static let popoverWidth: CGFloat = 380
}
