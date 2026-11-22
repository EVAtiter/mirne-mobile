import Foundation

// 録画の保護を 1 回切り替えて、nasne の振る舞いを測る。
//
//   mirne-mobile-probe protect-title --host <nasne> --at "yyyy-MM-dd HH:mm"                      （選んで形を見るだけ。何も送らない）
//   mirne-mobile-probe protect-title --host <nasne> --at "yyyy-MM-dd HH:mm" --send --protect     （保護する。1 回だけ送る）
//   mirne-mobile-probe protect-title --host <nasne> --at "yyyy-MM-dd HH:mm" --send --unprotect   （保護を外す。1 回だけ送る）
//
// 守ること:
// - **使う人が指定した試しの録画だけを、そのたび確かめてから切り替える。** 録画は始まった分（日本時間）で
//   1 件に決まるときだけ選ぶ。`--send` が無ければ、選んだ録画の形と、送る文書の形を出すだけで何も送らない
// - 録画中の録画には送らない。今と同じ状態にする頼みも送らない
// - 送るのは 1 回だけで、自動で再試行しない。送るのはアプリと同じ作り（一覧を読み直して item を受け取ったまま送り返す）
// - 番組名・タイトル ID・アドレス・要素の値は出さない。出すのは要素の名前・長さ・保護・録画中・応答の形・件数だけ

@MainActor
enum ProtectTitleCommand {
    /// 送った後に読み直すまでの間（すぐの読み直しに加えて、遅れて変わらないかを見る）
    static let recheckDelay: Duration = .seconds(2)

    static func run() async throws {
        guard let at = option("--at") else { fail("--at \"yyyy-MM-dd HH:mm\"（日本時間で録画の始まった分）で試しの録画を指定する") }
        let (device, _) = try await connect(requiredHost())
        let catalog = RecordingCatalogService(soap: SOAPTransport(client: client), device: device)
        let vocabulary = catalog.profile.xsrs

        let before = try await catalog.titles(withMetadata: false)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = NasneDateTime.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let matched = before.filter { $0.start.map(formatter.string) == at }
        guard matched.count == 1, let title = matched.first else { fail("--at \(at) に始まった録画が \(matched.count) 件（1 件のときだけ選ぶ）") }
        say("選んだ録画: 長さ \(title.durationSeconds ?? 0) 秒・保護 \(title.isProtected ? "あり" : "なし")・録画中 \(title.isRecording ? "はい" : "いいえ")"
            + "（番組名・タイトル ID は出さない）・一覧 \(before.count) 件")

        // 一覧の item を受け取ったまま切り出し、形を見る
        guard let itemXML = try await catalog.listedTitleXML(id: title.id) else { fail("一覧から item を切り出せなかった") }
        guard let item = try XSRSItem.parseDocument(wrapped(itemXML), source: "probe").first else { fail("切り出した item を読めなかった") }
        say("item: \(itemXML.utf8.count) バイト・子の要素 \(childNames(itemXML).count) 個")
        say("  要素の並び: \(childNames(itemXML).joined(separator: " "))")
        say("  属性を持つ要素: \(item.attributes.keys.sorted().map { "\($0)[\(item.attributes[$0]!.keys.sorted().joined(separator: ","))]" }.joined(separator: " "))")
        say("  保護の印: \(flagShape(itemXML, element: vocabulary.titleProtectElement))")

        // 送る文書を組み立て、保護の印のほかは受け取ったままかを確かめる
        let target = !title.isProtected
        let document = vocabulary.protectionDocument(itemXML: itemXML, protect: flag("--unprotect") ? false : (flag("--protect") ? true : target))
        let sentItem = unwrap(document)
        say("送る文書: \(document.utf8.count) バイト・保護の印のほかは受け取ったまま \(maskFlag(sentItem, vocabulary) == maskFlag(itemXML, vocabulary) ? "はい" : "いいえ")")

        guard flag("--send") else {
            say("（--send が無いので何も送らない）")
            return
        }
        guard flag("--protect") != flag("--unprotect") else { fail("--send には --protect か --unprotect のどちらか 1 つを付ける") }
        let protect = flag("--protect")
        guard !title.isRecording else { fail("録画中の録画には送らない") }
        guard title.isProtected != protect else { fail("もう\(protect ? "保護されている" : "保護されていない")ので送らない") }

        let start = Date()
        do {
            try await catalog.setProtection(id: title.id, protect: protect)
            say("\(catalog.profile.soap.updateTitle.name)（\(protect ? "保護する" : "保護を外す")）: 通った（\(elapsed(start))）")
        } catch {
            say("\(catalog.profile.soap.updateTitle.name)（\(protect ? "保護する" : "保護を外す")）: 断られた（\(elapsed(start))）・\(error)")
        }

        try await report("送った直後", catalog: catalog, title: title, before: item, vocabulary: vocabulary)
        try await Task.sleep(for: recheckDelay)
        try await report("\(recheckDelay) 後", catalog: catalog, title: title, before: item, vocabulary: vocabulary)
    }

    /// 読み直して、保護の印・件数・変わった要素の名前を出す
    static func report(_ label: String, catalog: RecordingCatalogService, title: RecordedTitle, before: XSRSItem,
                       vocabulary: XSRSRequestVocabulary) async throws {
        let titles = try await catalog.titles(withMetadata: false)
        guard let now = titles.first(where: { $0.id == title.id }),
              let xml = try await catalog.listedTitleXML(id: title.id),
              let after = try XSRSItem.parseDocument(wrapped(xml), source: "probe").first else {
            say("\(label): 一覧 \(titles.count) 件・選んだ録画が一覧に無い")
            return
        }
        let names = Set(before.fields.keys).union(after.fields.keys).union(before.attributes.keys).union(after.attributes.keys)
        let changed = names.sorted().filter { before.fields[$0] != after.fields[$0] || before.attributes[$0] != after.attributes[$0] }
        say("\(label): 一覧 \(titles.count) 件・保護 \(now.isProtected ? "あり" : "なし")・値が変わった要素 \(changed.isEmpty ? "なし" : changed.joined(separator: " "))")
    }

    // MARK: - 形を見るための小物（値は出さない）

    /// item を xsrs の文書に包む（読むため）
    static func wrapped(_ item: String) -> String { "<xsrs>\(item)</xsrs>" }

    /// 送る文書から item の要素だけを取り出す
    static func unwrap(_ document: String) -> String {
        guard let open = document.range(of: "<item"), let close = document.range(of: "</item>", options: .backwards) else { return "" }
        return String(document[open.lowerBound..<close.upperBound])
    }

    /// item の直下の子の要素の名前（並びのまま）
    static func childNames(_ item: String) -> [String] {
        guard let root = try? XMLTree.parse(item, source: "probe") else { return [] }
        return root.children.map(\.name)
    }

    /// 保護の印の要素の書き方（値は 0 / 1 なので出す）
    static func flagShape(_ item: String, element: String) -> String {
        if let range = item.range(of: "<\(element)>[^<]*</\(element)>", options: .regularExpression) {
            return "開きと閉じのタグ・値 \(item[range].dropFirst(element.count + 2).prefix { $0 != "<" })"
        }
        if item.range(of: "<\(element)\\s*/>", options: .regularExpression) != nil { return "空の要素" }
        return "無い"
    }

    /// 保護の印の要素を伏せた文字（送る文書が、印のほかは受け取ったままかを比べる）
    static func maskFlag(_ item: String, _ vocabulary: XSRSRequestVocabulary) -> String {
        let element = vocabulary.titleProtectElement
        return item.replacingOccurrences(of: "<\(element)\\s*/>|<\(element)>[^<]*</\(element)>", with: "<flag/>",
                                         options: .regularExpression)
    }
}
