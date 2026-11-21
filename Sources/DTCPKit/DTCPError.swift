// DTCP-IP の誤りの表現と、診断ログの出口。
//
// torne mobile HB（MIT、© mar1mo-41414）の lib/core/errors.dart・lib/core/diagnostics.dart の考え方を
// Swift へ移したもの。統一エラー（NasneKit 側）への変換は呼び出し側で行う。

import Foundation
import os

/// DTCP-IP の処理で起きた誤り。分類は torne mobile HB の統一エラーに合わせてある
public struct DTCPError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Category: String, Sendable {
        /// 資格情報・入力の不備（証明書の形・署名・鍵の範囲・ペアの不一致など）
        case validation
        /// 受け取ったデータの形の誤り・プロトコル違反・失効
        case parse
        /// 相手に届かない・切れた・時間切れ
        case unreachable
    }

    public let category: Category
    /// 発生元（例: `dtcp:ake`）
    public let source: String
    /// 何が起きたか。**鍵・証明書・ノンスの値は入れない**
    public let detail: String
    /// 元のコード（HTTP の状態など）。無ければ nil。画面に添える
    public let code: String?

    public init(_ category: Category, _ source: String, _ detail: String, code: String? = nil) {
        self.category = category
        self.source = source
        self.detail = detail
        self.code = code
    }

    static func validation(_ source: String, _ detail: String) -> DTCPError { .init(.validation, source, detail) }
    static func parse(_ source: String, _ detail: String) -> DTCPError { .init(.parse, source, detail) }
    static func unreachable(_ source: String, _ detail: String) -> DTCPError { .init(.unreachable, source, detail) }

    public var description: String { "\(category.rawValue) (\(source)): \(detail)" }
}

/// AKE の接続が、待っている操作の途中で終わった（相手が閉じた）。
///
/// 再生のための AKE では**正常な終わり方**。nasne は認証が終わった直後、コンテンツの GET を出す前に
/// AKE の接続を閉じる（torne mobile HB の計画書 §29 で実測）。参照実装の pydtcpip も同じところで
/// 自分から閉じる。終わったセッションが渡していないラベルの鍵が要るときは、新しい接続で認証し直す
public struct AKEConnectionClosed: Error, Sendable, Equatable, CustomStringConvertible {
    public init() {}
    public var description: String { "the AKE connection closed" }
}

/// 診断ログの分類
public enum DTCPLogCategory: String, Sendable {
    case ake
    case pcp
    case playback
}

/// 診断ログの出口。
///
/// **書いてよいのは段の遷移・フレームのヘッダ（コマンド・種別・状態・長さ）・ラベル・バイト数・所要時間だけ。**
/// 資格情報・認証鍵・交換鍵・コンテンツ鍵・ノンス・署名・MAC の値は、呼び出す側がそもそも渡さない
/// （試験 `DTCPDiagnosticsAuditTests` が実行時と静的の両方で確かめる）
public struct DTCPDiagnostics: Sendable {
    public let write: @Sendable (DTCPLogCategory, String) -> Void

    public init(_ write: @escaping @Sendable (DTCPLogCategory, String) -> Void) {
        self.write = write
    }

    func callAsFunction(_ category: DTCPLogCategory, _ message: String) {
        write(category, message)
    }

    /// 何も書かない
    public static let none = DTCPDiagnostics { _, _ in }

    /// os.Logger へ書く（サブシステムは Bundle ID）。中身は段の遷移だけなので .public で出す
    public static let osLog = DTCPDiagnostics { category, message in
        Logger(subsystem: AppLog.subsystem, category: category.rawValue)
            .info("\(message, privacy: .public)")
    }
}
