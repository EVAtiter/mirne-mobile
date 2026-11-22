import SwiftUI

/// 発見・登録の画面。流れは `DeviceSetupModel` が持ち、ここは出すだけ。
///
/// nasne のアドレスは画面に出さない（`NasneDevice.host` の決まり）。見分けには nasne に付けた名前と型番を出す
struct SetupView: View {
    @State var model: DeviceSetupModel
    /// ローカルネットワークの使用が許可されていない（iPad で、探す前に聞いて断られたとき）
    @State private var localNetworkDenied = false

    var body: some View {
        Form {
            Section {
                Text("同じネットワークにある nasne を探して登録します。登録すると、録画を見たり番組表を読んだりできます。")
                    .foregroundStyle(.secondary)
            }

            if localNetworkDenied {
                Section {
                    Text("ローカルネットワークの使用が許可されていないので、nasne を探せません。設定の「プライバシーとセキュリティ」→「ローカルネットワーク」で mirne mobile を許可してください。")
                }
            }

            Section("見つかった nasne") {
                if model.devices.isEmpty {
                    emptyState
                } else {
                    ForEach(model.devices, id: \.descriptionURL) { device in
                        deviceRow(device)
                    }
                }
                HStack {
                    Button("もう一度探す") { Task { await model.searchAutomatically() } }
                        .disabled(model.isBusy)
                    if model.canScan {
                        Button("このネットワークを順に調べる") { Task { await model.scan() } }
                            .disabled(model.isBusy)
                            .help("見つからないときに使います。このネットワークのアドレスに 1 つずつ（254 個）問い合わせます")
                    }
                    Spacer()
                    if case .searching(let kind) = model.activity {
                        ProgressView().controlSize(.small)
                        Text(kind == .scan ? "調べています…" : "探しています…").foregroundStyle(.secondary)
                            .help("すぐに見つからないときは、nasne からの知らせを最長 35 秒待ちます")
                    }
                }
            }

            Section("アドレスで登録") {
                HStack {
                    TextField("nasne の IP アドレス、またはデバイス記述の URL", text: $model.manualAddress)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await model.registerManualAddress() } }
                    Button("登録") { Task { await model.registerManualAddress() } }
                        .disabled(model.isBusy || model.manualAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if model.activity == .registering {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("登録しています…").foregroundStyle(.secondary)
                    }
                }
            }

            if let error = model.error {
                Section { ErrorBanner(error: error) }
            }
        }
        .formStyle(.grouped)
        .task {
            // 画面を開いたら、最初の方法（macOS は SSDP、iPad は /24 の走査）で自動で探す。
            // iPad は先にローカルネットワークの許可を聞き、答えが出てから探す（聞いている間に探すと 0 台になる）
            if !model.searchedAutomatically {
                localNetworkDenied = !(await LocalNetworkPermission.request())
                await model.searchAutomatically()
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.searchedAutomatically, !model.isBusy {
            // 走査した後（iPad は自動で探す方法が走査）なら、走査を勧めない
            Text(model.scanned || !model.canScan
                 ? "見つかりませんでした。nasne の電源と、\(DeviceWording.thisDevice) が同じネットワークにつながっているかを確かめて、アドレスで登録してください。"
                 : "見つかりませんでした。「このネットワークを順に調べる」を試すか、アドレスで登録してください。")
                .foregroundStyle(.secondary)
        } else {
            Text("探しています…").foregroundStyle(.secondary)
        }
    }

    private func deviceRow(_ device: NasneDevice) -> some View {
        HStack {
            Image(systemName: "externaldrive.connected.to.line.below")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(device.friendlyName)
                Text(device.modelName).scaledFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("登録") { Task { await model.register(device) } }
                .disabled(model.isBusy)
        }
    }
}

/// 誤りを出す帯（題・説明・元のコード）
struct ErrorBanner: View {
    let error: ErrorPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title).bold()
                Text(error.message).foregroundStyle(.secondary)
                if let code = error.code {
                    Text("コード \(code)").scaledFont(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
