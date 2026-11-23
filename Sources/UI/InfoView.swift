import SwiftUI

/// 情報（2026-11-19 に「ホーム」から改名）。区画ごとに読み込み、失敗した区画だけ誤りを出す
struct InfoView: View {
    @State var model: InfoModel
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(spacing: 0) {
            // 上の帯（番組表と同じ位置）。情報の画面の操作は「更新」だけ
            ScreenActionBar(refreshHelp: "情報を更新する（⌘R）", isRefreshing: model.isLoading,
                            refresh: { Task { await model.reload() } }) { EmptyView() }
            form
        }
        .navigationTitle("情報")
        .task {
            if model.lastUpdated == nil { await model.reload() }
            #if DEBUG
            // 非機能要件の計測（参考値：全部の区画がそろうまで。起動してから最初の 1 回だけ出す。開発用のビルドだけ）
            if model.lastUpdated != nil { PerformanceLog.infoCompleted() }
            #endif
        }
        #if DEBUG
        // 非機能要件の計測（「起動 → 情報の画面の表示」：最初の区画に値が出たとき。起動してから最初の 1 回だけ出す。開発用のビルドだけ）
        .onChange(of: model.hasAnyValue, initial: true) { _, shown in
            if shown { PerformanceLog.infoShown() }
        }
        #endif
        .onChange(of: environment.mainCommands.pending, initial: true) {
            if environment.mainCommands.consume(.refresh) { Task { await model.reload() } }
        }
    }

    private var form: some View {
        Form {
            Section("本体情報") {
                section(model.device) { device in
                    LabeledContent("名前", value: device.name)
                    LabeledContent("システムソフトウェア", value: device.softwareVersion)
                    if let date = device.currentDate {
                        LabeledContent("本体の時刻", value: date.formatted(date: .abbreviated, time: .standard))
                    }
                    if let area = device.area { LabeledContent("地域", value: area) }
                    if let count = device.titleCount {
                        LabeledContent("録画", value: device.titleMax.map { "\(count) / \($0) 件" } ?? "\(count) 件")
                    }
                    if device.updateExists { LabeledContent("更新", value: "システムソフトウェアの更新があります") }
                }
            }

            Section("HDD") {
                section(model.hdds) { hdds in
                    if hdds.isEmpty { Text("HDD が見つかりません").foregroundStyle(.secondary) }
                    ForEach(hdds) { hdd in hddRow(hdd) }
                }
            }

            Section("状態") {
                section(model.status) { status in
                    if status.recordingTitles.isEmpty {
                        LabeledContent("録画中", value: "なし")
                    } else {
                        ForEach(Array(status.recordingTitles.enumerated()), id: \.offset) { _, title in
                            LabeledContent("録画中", value: title)
                        }
                    }
                    if status.messages.isEmpty {
                        LabeledContent("お知らせ", value: "なし")
                    } else {
                        ForEach(Array(status.messages.enumerated()), id: \.offset) { _, message in
                            Label(message, systemImage: "exclamationmark.bubble")
                        }
                    }
                }
            }

            Section("録画失敗") {
                section(model.recNg) { items in
                    if items.isEmpty { Text("録画失敗はありません").foregroundStyle(.secondary) }
                    ForEach(items, id: \.id) { item in
                        LabeledContent(item.title.isEmpty ? "（番組名なし）" : item.title,
                                       value: item.start?.formatted(date: .abbreviated, time: .shortened) ?? "")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 区画の読み込みの状態を出す
    @ViewBuilder
    private func section<Value, Content: View>(_ state: Loadable<Value>,
                                               @ViewBuilder content: (Value) -> Content) -> some View {
        switch state {
        case .idle, .loading, .failed:
            // 読み込み中・読み込めなかったことは知らせの帯に出す
            EmptyView()
        case .loaded(let value):
            content(value)
        }
    }

    private func hddRow(_ hdd: HDDSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(hdd.isInternal ? "内蔵 HDD" : "外付け HDD")
                Spacer()
                if let free = hdd.freeBytes, let total = hdd.totalBytes {
                    Text("空き \(Self.bytes(free)) / \(Self.bytes(total))").foregroundStyle(.secondary)
                } else if !hdd.isConnected {
                    Text("つながっていません").foregroundStyle(.secondary)
                }
            }
            if let fraction = hdd.usedFraction {
                ProgressView(value: fraction)
                    .help("使用 \(hdd.usedBytes.map(Self.bytes) ?? "-")")
            }
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .decimal)
    }
}
