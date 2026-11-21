// torne mobile HB（MIT、© mar1mo-41414）の lib/core/json_util.dart を Swift へ移植したもの。

import Foundation

/// WebAPI の JSON の 1 オブジェクト。数と文字列が入れ替わってもよいように、寛容に読む。
public struct JSONObject: @unchecked Sendable {
    public let values: [String: Any]

    public init(_ values: [String: Any]) {
        self.values = values
    }

    /// バイト列から作る。オブジェクトでなければ投げる
    public init(data: Data, source: String) throws {
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw NasneError.parse(source, "JSON として読めない")
        }
        guard let object = decoded as? [String: Any] else {
            throw NasneError.parse(source, "応答が JSON のオブジェクトでない")
        }
        self.init(object)
    }

    public func string(_ key: String) -> String? {
        switch values[key] {
        case let value as String: return value
        case let value as NSNumber: return value.stringValue
        default: return nil
        }
    }

    public func int(_ key: String) -> Int? {
        switch values[key] {
        case let value as NSNumber: return value.intValue
        case let value as String: return Int(value)
        default: return nil
        }
    }

    /// 0 / 1 の旗。無ければ false
    public func flag(_ key: String) -> Bool {
        switch values[key] {
        case let value as NSNumber: return value.intValue != 0
        case let value as String: return value == "1" || value.lowercased() == "true"
        default: return false
        }
    }

    public func object(_ key: String) -> JSONObject? {
        (values[key] as? [String: Any]).map(JSONObject.init)
    }

    /// オブジェクトの配列。配列でなければ空
    public func objects(_ key: String) -> [JSONObject] {
        guard let array = values[key] as? [Any] else { return [] }
        return array.compactMap { ($0 as? [String: Any]).map(JSONObject.init) }
    }

    public func requiredString(_ key: String, source: String) throws -> String {
        guard let value = string(key) else { throw NasneError.parse(source, "\"\(key)\" が無い") }
        return value
    }

    public func requiredInt(_ key: String, source: String) throws -> Int {
        guard let value = int(key) else { throw NasneError.parse(source, "\"\(key)\" が無い") }
        return value
    }
}
