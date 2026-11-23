import Foundation

/// XML の小さな木構造。デバイス記述・SOAP・xsrs・DIDL を読むのに使う。
///
/// macOS の `XMLDocument` は iOS に無いので使わない（iOS 版で同じ部品を使うため）。
/// `XMLParser` で組み立てる。名前は接頭辞を外したローカル名で引く
/// （nasne はサービスによって接頭辞付きと既定の名前空間を混ぜて使うため）。
public final class XMLTreeElement: @unchecked Sendable {
    /// 接頭辞を外した名前
    public let name: String
    /// 接頭辞付きの名前（例：`av:COGCount`）
    public let qualifiedName: String
    /// 属性。鍵は接頭辞を外した名前
    public let attributes: [String: String]
    public fileprivate(set) var children: [XMLTreeElement] = []
    fileprivate var textParts: [String] = []

    init(name: String, qualifiedName: String, attributes: [String: String]) {
        self.name = name
        self.qualifiedName = qualifiedName
        self.attributes = attributes
    }

    /// 自分と子孫の文字をつなげたもの（実体参照は解いたあと）
    public var text: String {
        var output = textParts.joined()
        for child in children {
            output += child.text
        }
        return output
    }

    /// 直下の子のうち、名前が合うもの
    public func children(named name: String) -> [XMLTreeElement] {
        children.filter { $0.name == name }
    }

    /// 直下の子のうち、名前が合う最初のもの
    public func child(named name: String) -> XMLTreeElement? {
        children.first { $0.name == name }
    }

    /// 直下の子の文字
    public func childText(_ name: String) -> String? {
        child(named: name)?.text
    }

    /// 子孫のうち、名前が合う最初のもの（自分を含む・深さ優先）
    public func firstDescendant(named name: String) -> XMLTreeElement? {
        if self.name == name { return self }
        for child in children {
            if let found = child.firstDescendant(named: name) { return found }
        }
        return nil
    }
}

/// XML 1.0 の文字の決まり（W3C XML 1.0 の Char）のうち、制御文字にかかわる値
enum XMLControlCharacters {
    /// これより小さい値は、下の 3 つを除いて使えない
    static let firstAllowed: UInt8 = 0x20
    /// 使える制御文字（TAB・LF・CR）
    static let allowed: Set<UInt8> = [0x09, 0x0A, 0x0D]
    /// 文字参照の頭
    static let referencePrefix = "&#"
    /// 使えない制御文字を指す文字参照（16 進：0〜8・B・C・E〜1F、10 進：0〜8・11・12・14〜31。頭の 0 は何個でも）
    static let invalidReference = try! NSRegularExpression(
        pattern: "&#(?:[xX]0*(?:[0-8bBcCeEfF]|1[0-9a-fA-F])|0*(?:[0-8]|1[1-24-9]|2[0-9]|3[01]));")
}

/// XML の文字列を木にする
public enum XMLTree {
    /// 読めなければ投げる（source は誤りの出所の名前）
    public static func parse(_ text: String, source: String) throws -> XMLTreeElement {
        try parse(Data(text.utf8), source: source)
    }

    public static func parse(_ data: Data, source: String) throws -> XMLTreeElement {
        let builder = Builder()
        let parser = XMLParser(data: removingInvalidControlCharacters(data))
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            let reason = parser.parserError.map { String(describing: $0) } ?? "根の要素が無い"
            throw NasneError.parse(source, "XML として読めない：\(reason)")
        }
        return root
    }

    /// XML 1.0 で使えない制御文字（U+0000〜U+001F のうち TAB・LF・CR を除くもの）を、生の値と文字参照
    /// （`&#x1B;`・`&#27;` など）の両方から取り除く。
    ///
    /// `XMLParser` はどちらに当たっても文書全体を読むのをやめる（2026-11-23 に確かめた。誤り 111）。録画の説明文などに
    /// まれに混じることが外部の記事で報告されていて（DLNA の DIDL の `dc:description`）、そのままだと Browse の 1 頁が丸ごと
    /// 読めなくなる。どれも表示に意味の無い文字なので、読む前に除いて残りを読む。UTF-8 では 0x00〜0x1F の 1 バイトが
    /// ほかの文字の途中に現れないので、バイト単位で除いてよい。入れ子の文書（SOAP の `Result` に入った DIDL）は、
    /// 外と中のそれぞれを読むときにここを通る
    static func removingInvalidControlCharacters(_ data: Data) -> Data {
        let hasRawControl = data.contains { $0 < XMLControlCharacters.firstAllowed && !XMLControlCharacters.allowed.contains($0) }
        let hasReference = data.range(of: Data(XMLControlCharacters.referencePrefix.utf8)) != nil
        guard hasRawControl || hasReference else { return data }
        var bytes = data.filter { $0 >= XMLControlCharacters.firstAllowed || XMLControlCharacters.allowed.contains($0) }
        if hasReference, let text = String(data: bytes, encoding: .utf8) {
            let cleaned = XMLControlCharacters.invalidReference.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            bytes = Data(cleaned.utf8)
        }
        return bytes
    }

    /// 接頭辞を外す（`u:Browse` → `Browse`）
    static func localName(_ qualified: String) -> String {
        guard let colon = qualified.lastIndex(of: ":") else { return qualified }
        return String(qualified[qualified.index(after: colon)...])
    }

    /// 要素の文字として埋め込むためのエスケープ
    public static func escapeText(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// 二重引用符の属性として埋め込むためのエスケープ
    public static func escapeAttribute(_ value: String) -> String {
        escapeText(value).replacingOccurrences(of: "\"", with: "&quot;")
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTreeElement?
        private var stack: [XMLTreeElement] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            var attributes: [String: String] = [:]
            for (key, value) in attributeDict where !key.hasPrefix("xmlns") {
                attributes[XMLTree.localName(key)] = value
            }
            let element = XMLTreeElement(name: XMLTree.localName(elementName), qualifiedName: elementName,
                                     attributes: attributes)
            if let parent = stack.last {
                parent.children.append(element)
            } else if root == nil {
                root = element
            }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.textParts.append(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.textParts.append(String(decoding: CDATABlock, as: UTF8.self))
        }
    }
}
