// torne mobile HB（MIT、© mar1mo-41414）の lib/core/errors.dart を Swift へ移植したもの。

import Foundation

/// nasne との通信で起きた誤りを、経路（WebAPI・SOAP・SSDP）によらない 1 つの形にしたもの。
///
/// 画面は経路ごとの誤りの形（HTTP の状態・WebAPI の errorcode・UPnP の Fault）を知らない。
/// 変換は各転送層の境目で行う。
public struct NasneError: Error, Sendable, Equatable, CustomStringConvertible {
    /// 誤りの分類
    public enum Category: String, Sendable {
        /// 届かない（ソケットの誤り・時間切れ）
        case unreachable
        /// HTTP の状態が 200 でない（ほかの形に当てはまらないとき）
        case http
        /// WebAPI の JSON の誤り（errorcode ≠ 0、または POST の 400 の拒否）
        case webapi
        /// UPnP SOAP の Fault（errorCode・errorDescription）
        case soapFault
        /// 応答の形が思っていたものと違う
        case parse
        /// 送る前の入力の検査で弾いた
        case validation
        /// まだ作っていない・この機器に無い
        case unsupported
    }

    public var category: Category
    /// 元のコード（HTTP の状態・errorcode・UPnP の errorCode）を文字列のまま。無ければ nil
    public var code: String?
    /// どこで起きたか（例：`webapi:/status/boxNameGet`・`soap:X_GetTitleList`・`ssdp:search`）
    public var source: String
    /// 自動で再試行してよいか。冪等な読み取りの到達の誤りだけが true（書き込みは再試行しない）
    public var retryable: Bool
    /// 画面に出す説明の鍵。文言そのものは画面の層が持つ
    public var messageKey: String
    /// ログ・診断用の詳細。**秘密（鍵・トークン・PIN・MAC アドレス）を入れない**
    public var detail: String?

    public init(category: Category, code: String? = nil, source: String, retryable: Bool = false,
                messageKey: String, detail: String? = nil) {
        self.category = category
        self.code = code
        self.source = source
        self.retryable = retryable
        self.messageKey = messageKey
        self.detail = detail
    }

    public static func unreachable(_ source: String, cause: (any Error)? = nil) -> NasneError {
        NasneError(category: .unreachable, source: source, retryable: true, messageKey: "error.unreachable",
                   detail: cause.map { String(describing: $0) })
    }

    /// nasne が「クライアントとして許可していない機器」に返す HTTP の状態（pydtcpip の `profiles/nasne.py`。
    /// 一覧・配信の要求に、nasne HOME で許可していない機器から送ると返る）
    public static let clientNotAllowedStatus = 403

    public static func http(_ statusCode: Int, _ source: String) -> NasneError {
        let key = switch statusCode {
        case 404: "error.notImplemented"
        case clientNotAllowedStatus: "error.clientNotAllowed"
        default: "error.http"
        }
        return NasneError(category: .http, code: String(statusCode), source: source, messageKey: key,
                          detail: "HTTP \(statusCode)")
    }

    public static func webapi(_ errorCode: Int, _ source: String) -> NasneError {
        NasneError(category: .webapi, code: String(errorCode), source: source, messageKey: "error.webapi",
                   detail: "errorcode=\(errorCode)")
    }

    /// 予約の作成で、時刻を指定した予約（eventId 0）がほかにあるときの Fault。終わった手動の予約が残っているとき
    /// （torne mobile HB §74.7）だけでなく、始まる前の手動の予約があるときも返る。局が違っても返る（2026-11-20 実機）
    public static let manualScheduleExistsFault = "830"
    /// 予約の数が上限（100 件）のときの Fault（torne mobile HB §74.7）
    public static let scheduleLimitFault = "836"
    /// 保護した録画を消そうとしたときの Fault（`X_DeleteTitle`。torne mobile HB 1.4.4 が SIE 製で測った）。
    /// ほかの操作で返ったときの意味は分からないので、コードだけでは鍵を分けず、録画の削除のときだけ `titleProtected` に直す
    public static let titleProtectedFault = "877"

    /// 録画の削除で、保護した録画だったとき
    public static func titleProtected(from fault: NasneError) -> NasneError {
        NasneError(category: fault.category, code: fault.code, source: fault.source, retryable: false,
                   messageKey: "error.titleProtected", detail: fault.detail)
    }

    /// UPnP の Fault から作る。実測で意味が分かったコードは鍵を分ける
    /// （402 = 要求の形の誤り、803 = ID の形の誤り。どちらも利用者の操作ではなく実装の誤り。
    /// 830 = 時刻を指定した予約がほかにあって作れない、836 = 予約の数の上限）
    public static func soapFault(errorCode: String, errorDescription: String?, source: String) -> NasneError {
        let key: String
        switch errorCode {
        case "402": key = "error.invalidArgs"
        case "803": key = "error.invalidIdFormat"
        case manualScheduleExistsFault: key = "error.manualScheduleExists"
        case scheduleLimitFault: key = "error.scheduleLimit"
        default: key = "error.soapFault"
        }
        return NasneError(category: .soapFault, code: errorCode, source: source, messageKey: key,
                          detail: errorDescription)
    }

    public static func parse(_ source: String, _ detail: String) -> NasneError {
        NasneError(category: .parse, source: source, messageKey: "error.parse", detail: detail)
    }

    public static func validation(_ source: String, _ detail: String) -> NasneError {
        NasneError(category: .validation, source: source, messageKey: "error.validation", detail: detail)
    }

    public static func unsupported(_ source: String, _ detail: String? = nil) -> NasneError {
        NasneError(category: .unsupported, source: source, messageKey: "error.unsupported", detail: detail)
    }

    public var description: String {
        var parts = ["NasneError(\(category.rawValue)", "source=\(source)"]
        if let code { parts.append("code=\(code)") }
        parts.append("key=\(messageKey)")
        if retryable { parts.append("retryable") }
        if let detail { parts.append("detail=\(detail)") }
        return parts.joined(separator: ", ") + ")"
    }
}
