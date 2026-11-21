import Foundation

// SOAP のサービスの説明（SCPD）を読み、アクションと引数の名前・向き・型を出す。
// 録画の削除（`X_DeleteTitle`）がどのサービスにあり、どんな引数を取るかを、送る前に確かめるため。
//
//   mirne-mobile-probe scpd --host <nasne> [--action <名前の一部>]
//
// 守ること:
// - デバイス記述と SCPD を GET するだけ（SOAP の操作は何も送らない）
// - アドレス・UDN は出さない。出すのはサービスの種類・SCPD のパス・アクションと引数の名前と型だけ

@MainActor
enum ScpdCommand {
    /// 引数まで詳しく出すアクション（`--action` が無いとき）。削除と、録画一覧まわりの名前に含まれる語
    static let defaultDetailKeywords = ["Delete", "Title"]

    static func run() async throws {
        let host = requiredHost()
        let device = try await DeviceDescriber(client: client).describe(host: host)
        say("デバイス記述: modelName=\(device.modelName)・サービス \(device.services.count) 件")
        let keywords = option("--action").map { [$0] } ?? defaultDetailKeywords

        for service in device.services.values.sorted(by: { $0.serviceType < $1.serviceType }) {
            guard let scpdURL = service.scpdURL else {
                say("\n\(service.serviceType): SCPD の URL が無い")
                continue
            }
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await client.send(URLRequest(url: scpdURL))
            } catch {
                say("\n\(service.serviceType): SCPD を取れなかった（\(error)）")
                continue
            }
            say("\n\(service.serviceType)（ポート \(scpdURL.port.map(String.init) ?? "既定")・パス \(maskedPath(scpdURL))）: HTTP \(response.statusCode)・\(data.count) バイト")
            guard response.statusCode == 200 else { continue }
            let root = try XMLTree.parse(data, source: "scpd:\(service.serviceType)")
            let types = stateVariableTypes(root)
            let actions = root.firstDescendant(named: "actionList")?.children(named: "action") ?? []
            let names = actions.compactMap { $0.childText("name")?.trimmed }
            say("  アクション \(names.count) 件: \(names.joined(separator: "・"))")
            for action in actions {
                guard let name = action.childText("name")?.trimmed,
                      keywords.contains(where: { name.localizedCaseInsensitiveContains($0) }) else { continue }
                say("  ▸ \(name)")
                let arguments = action.child(named: "argumentList")?.children(named: "argument") ?? []
                if arguments.isEmpty { say("      引数なし") }
                for argument in arguments {
                    let argumentName = argument.childText("name")?.trimmed ?? "?"
                    let direction = argument.childText("direction")?.trimmed ?? "?"
                    let variable = argument.childText("relatedStateVariable")?.trimmed ?? "?"
                    say("      \(direction == "in" ? "入" : direction == "out" ? "出" : direction)  \(argumentName)  ← \(variable)（\(types[variable] ?? "型不明")）")
                }
            }
        }
    }

    /// SCPD のパス。Buffalo 製はパスに機器の UUID を含む（`/UD/<uuid>…`）ので、16 進の長い塊を伏せる（UDN を出さない）
    static func maskedPath(_ url: URL) -> String {
        let path = url.path + (url.query.map { "?" + $0 } ?? "")
        return path.replacingOccurrences(of: "[0-9A-Fa-f]{8}(-?[0-9A-Fa-f]{4}){3}-?[0-9A-Fa-f]{12}", with: "<uuid>",
                                         options: .regularExpression)
    }

    /// 状態変数の名前 → 型（`dataType`。許される値の一覧があれば添える）
    static func stateVariableTypes(_ root: XMLTreeElement) -> [String: String] {
        var types: [String: String] = [:]
        for variable in root.firstDescendant(named: "serviceStateTable")?.children(named: "stateVariable") ?? [] {
            guard let name = variable.childText("name")?.trimmed else { continue }
            var type = variable.childText("dataType")?.trimmed ?? "?"
            let allowed = variable.child(named: "allowedValueList")?.children(named: "allowedValue").map(\.text.trimmed) ?? []
            if !allowed.isEmpty { type += "・値 \(allowed.joined(separator: " / "))" }
            types[name] = type
        }
        return types
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
