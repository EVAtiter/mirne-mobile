// torne mobile HB（MIT、© mar1mo-41414）の lib/core/token.dart を Swift へ移植したもの。

import CryptoKit
import Foundation

/// X-DTVToken の計算（実機で確かめた式。plan.md §11.5）。
///
///     PIN   = 本体の MAC アドレスの下位 3 オクテット（`status/networkIfInfoGet` の macAddr から
///             コロンを除いた 7 文字目以降。表記は返ってきたまま）
///     token = base64( SHA1( PIN + パス + 本文の先頭 256 バイト ) )
///
/// パスは先頭の / を含む（例：`/config/PINVerify`）。PIN・トークンはログや画面に出さない。
public struct TokenProvider: Sendable {
    /// 本文のうちハッシュに含める長さ
    static let hashedBodyPrefixLength = 256
    /// MAC アドレス（コロンを除く）のうち、PIN にしない上位の文字数（3 オクテット）
    static let macPrefixCharacterCount = 6
    /// コロンを除いた MAC アドレスの長さ
    static let macCharacterCount = 12

    private let pin: String

    public init(pin: String) {
        self.pin = pin
    }

    /// MAC アドレスから作る
    public init(macAddress: String) throws {
        self.init(pin: try Self.derivePIN(macAddress: macAddress))
    }

    /// MAC アドレスの文字列から PIN を導く（例：`00:11:22:33:44:55` → `334455`）
    public static func derivePIN(macAddress: String) throws -> String {
        let stripped = macAddress.replacingOccurrences(of: ":", with: "")
        guard stripped.count >= macCharacterCount else {
            throw NasneError.validation("token", "MAC アドレスの形が思っていたものと違う")
        }
        return String(stripped.dropFirst(macPrefixCharacterCount))
    }

    /// 本文（バイト列）に対するトークン
    public func token(path: String, body: Data = Data()) -> String {
        Self.computeToken(pin: pin, path: path, body: body)
    }

    /// 状態を持たない形（既知値の試験用）
    public static func computeToken(pin: String, path: String, body: Data) -> String {
        var input = Data((pin + path).utf8)
        input.append(body.prefix(hashedBodyPrefixLength))
        let digest = Insecure.SHA1.hash(data: input)
        return Data(digest).base64EncodedString()
    }
}
