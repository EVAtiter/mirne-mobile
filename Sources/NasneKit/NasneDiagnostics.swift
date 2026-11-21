import Foundation
import os

// nasne とのやり取りの診断ログ。
//
// DTCPKit の `DTCPDiagnostics` と同じ形：書き出し口を差し替えられるので、試験で中身を受け取って
// 「秘密が出ていない」ことを確かめられる（試験 `DiagnosticsAuditTests`）。

/// ログのカテゴリ
public enum NasneLogCategory: String, Sendable {
    case discovery
    case webapi
    case soap
}

/// 診断ログの出口。
///
/// **書いてよいのはエンドポイントのパス・SOAP のアクション名・応答コード・バイト数・所要時間・件数だけ。**
/// MAC アドレス・PIN・X-DTVToken・要求のパラメータと本文・アドレス（IP・URL）は、呼び出す側がそもそも渡さない。
/// 誤りは `summary` で分類・コード・出どころだけにする（`detail` は URL を含みうるので出さない）
public struct NasneDiagnostics: Sendable {
    public let write: @Sendable (NasneLogCategory, String) -> Void

    public init(_ write: @escaping @Sendable (NasneLogCategory, String) -> Void) {
        self.write = write
    }

    func callAsFunction(_ category: NasneLogCategory, _ message: String) {
        write(category, message)
    }

    /// 何も書かない
    public static let none = NasneDiagnostics { _, _ in }

    /// os.Logger へ書く（サブシステムは Bundle ID）。中身は上の決まりの値だけなので .public で出す
    public static let osLog = NasneDiagnostics { category, message in
        Logger(subsystem: AppLog.subsystem, category: category.rawValue)
            .info("\(message, privacy: .public)")
    }

    /// 誤りの要約（分類・コード・出どころ）。`detail` と下にある誤り（URL を含む）は出さない
    public static func summary(_ error: any Error) -> String {
        switch error {
        case let nasne as NasneError:
            "\(nasne.category.rawValue)\(nasne.code.map { " \($0)" } ?? "")（\(nasne.source)）"
        case let url as URLError:
            "URLError \(url.code.rawValue)"
        default:
            String(describing: type(of: error))
        }
    }
}
