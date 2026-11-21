import os
import SwiftUI
import UniformTypeIdentifiers

/// 設定の資格情報の区画。
///
/// 出すのは「取り込み済みか」・機器 ID・証明書のフィンガープリント（SHA-1）だけ。ペアの値は出さない。
/// 取り込みは、利用者が選んだファイルをアプリが読み、DTCPKit の関門を通ったものだけを Keychain に入れる
struct CredentialsSection: View {
    let model: CredentialsModel
    /// どちらの取り込みか。選ぶ画面を閉じても、結果を受け取るまで残す
    @State private var importer: ImportKind?
    /// 選ぶ画面を出しているか。SwiftUI は選び終えたときに先にこれを false にしてから結果を渡すので、
    /// 種類（`importer`）とは別に持つ（一緒にしていたら、結果を受け取る時点で種類が消えていて何もしなかった。2026-11-19）
    @State private var showsImporter = false
    @State private var confirmingDelete = false
    private let logger = Logger(subsystem: AppLog.subsystem, category: "ui")

    enum ImportKind: Identifiable {
        case files
        case dotEnv
        var id: Self { self }
        /// ログに書く種類の名前
        var logName: String {
            switch self {
            case .files: "2 つのファイル"
            case .dotEnv: "env ファイル"
            }
        }
    }

    var body: some View {
        Section {
            switch model.summary {
            case .idle, .loading:
                HStack { ProgressView().controlSize(.small); Text("読み込んでいます…").foregroundStyle(.secondary) }
            case .failed(let error):
                ErrorBanner(error: error)
            case .loaded(let summary?):
                LabeledContent("状態", value: "取り込み済み")
                LabeledContent("機器 ID", value: summary.deviceIDHex).textSelection(.enabled)
                // 文字の大きさと書体はほかの項目（機器 ID など）と同じにする（前は等幅で、ラベルまで等幅になっていた）
                LabeledContent("証明書のフィンガープリント（SHA-1）", value: summary.certificateSHA1Hex)
                    .textSelection(.enabled)
            case .loaded(nil):
                LabeledContent("状態", value: "まだ取り込んでいません")
                SettingsNote("録画を見るには、資格情報を取り込みます。",
                             details: ["利用者が自分の機器から得た自分の資格情報（証明書と秘密鍵）です。"])
            }
            HStack {
                Button(model.summary.value.flatMap { $0 } == nil ? "ファイルから取り込む…" : "取り込み直す…") {
                    importer = .files
                    showsImporter = true
                }
                .help("証明書と秘密鍵の 2 つのファイルを一緒に選びます（バイナリ・16 進・base64）")
                Button("credentials.env から取り込む…") {
                    importer = .dotEnv
                    showsImporter = true
                }
                Spacer()
                if model.summary.value.flatMap({ $0 }) != nil {
                    Button("削除…", role: .destructive) { confirmingDelete = true }
                }
            }
            .disabled(model.isWorking)
            if model.isWorking {
                HStack { ProgressView().controlSize(.small); Text("処理しています…").foregroundStyle(.secondary) }
            }
            if let error = model.error { ErrorBanner(error: error) }
        } header: {
            Text("資格情報（DTCP-IP）")
        } footer: {
            SettingsNote("資格情報はこの Mac のキーチェーンにだけ保存します。",
                         details: ["iCloud には同期しません。元のファイルは消しません。"])
        }
        .task { if model.summary == .idle { await model.load() } }
        .fileImporter(isPresented: $showsImporter,
                      allowedContentTypes: [.data, .text, .item],
                      allowsMultipleSelection: importer == .files) { result in
            let kind = importer
            importer = nil
            guard case .success(let urls) = result, let kind else { return }
            let contents = urls.compactMap(Self.read)
            // パスと中身は書かない（種類と数だけ）
            logger.info("資格情報のファイルを選んだ: \(kind.logName, privacy: .public)・選んだ \(urls.count, privacy: .public)・読めた \(contents.count, privacy: .public)")
            Task {
                switch kind {
                case .files: await model.importFiles(contents)
                case .dotEnv: if let first = contents.first { await model.importDotEnv(first) }
                }
            }
        }
        .confirmationDialog("資格情報を削除しますか？", isPresented: $confirmingDelete) {
            Button("削除", role: .destructive) { Task { await model.delete() } }
        } message: {
            Text("キーチェーンから消します。録画を見るには、もう一度取り込む必要があります。")
        }
    }

    /// 選んだファイルを読む（パスは画面にもログにも出さない）
    private static func read(_ url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url)
    }
}
