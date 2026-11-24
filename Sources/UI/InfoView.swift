import SwiftUI

/// 情報（2026-11-19 に「ホーム」から改名）。区画ごとに読み込み、失敗した区画だけ誤りを出す
struct InfoView: View {
    @State var model: InfoModel
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    /// nasne に届くか（オフラインなら値の代わりに「nasne が見つかりません」と「探し直す」を出す。2026-11-24）
    @Environment(\.nasneLink) private var link

    var body: some View {
        VStack(spacing: 0) {
            // 上の帯（番組表と同じ位置）。情報の画面の操作は無い（右端の「ライブ」「設定」だけ）
            ScreenActionBar(hasLeading: false) { EmptyView() }
            if link == .offline {
                offline
            } else {
                form
            }
        }
        .navigationTitle("情報")
        // 見回り（MainView が回す）が読んだ世代や選局の状態が変わったら読み直す
        .onChange(of: model.observedSignature) { Task { await model.refreshIfChanged() } }
        // HDD の使用量など世代に出ない変化のために、開いていて前面にある間は決まった間で読み直す
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(InfoRefresh.periodicInterval))
                await model.refreshQuietly()
            }
        }
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
        }
    }

    /// オフラインのとき：値の代わりに出す（前の値は古いので出さない）。探している間は押せない
    private var offline: some View {
        ContentUnavailableView {
            Label("nasne が見つかりません", systemImage: InfoOfflineSymbol.name)
        } description: {
            Text("電源と、\(DeviceWording.thisDevice) が nasne と同じネットワークにつながっているかを確かめてください。")
        } actions: {
            Button(environment.connection == .searching ? "探しています…" : MainNoticeAction.retryConnection.title) {
                environment.retryConnection()
            }
            .disabled(environment.connection == .searching)
        }
        // 残りの高さいっぱいに広げる（macOS では中身の高さにしかならず、上の帯ごと窓の縦の真ん中に寄る）
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// 情報の画面のオフラインの絵
enum InfoOfflineSymbol {
    static let name = "wifi.exclamationmark"
}
