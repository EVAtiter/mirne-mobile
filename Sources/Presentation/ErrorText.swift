import Foundation

// 誤りを画面の文言に直す変換表。
//
// NasneKit・DTCPKit の誤りは分類と鍵（messageKey）だけを持ち、文言は持たない。ここで画面に出す形に直す。
// AppKit・SwiftUI に依存させない（iOS 版でも使う）。
//
// 画面に出すのは、題・説明・元のコード（HTTP の状態・errorcode・UPnP の errorCode）だけ。
// `detail`（ログ・診断用の詳細）は出さない（秘密は入れない決まりだが、利用者に見せる文ではないため）。

/// 画面に出す誤りの形
public struct ErrorPresentation: Sendable, Equatable {
    /// 短い題
    public let title: String
    /// 何が起きたか・どうすればよいか
    public let message: String
    /// 元のコード（無ければ nil）。問い合わせや記録のために小さく添える
    public let code: String?
    /// もう一度試す操作を出してよいか（届かないときだけ）
    public let canRetry: Bool

    public init(title: String, message: String, code: String? = nil, canRetry: Bool = false) {
        self.title = title
        self.message = message
        self.code = code
        self.canRetry = canRetry
    }
}

public enum ErrorText {
    /// NasneError の鍵 → 題と説明。鍵を足したら、ここにも足す（試験 `ErrorTextTests` が漏れを見つける）
    static let nasneMessages: [String: (title: String, message: String)] = [
        "error.unreachable": ("nasne に届きません",
                              "nasne の電源と、この Mac が同じネットワークにつながっているかを確かめてください。"),
        "error.http": ("nasne が受け付けませんでした",
                       "時間を置いてもう一度試してください。"),
        "error.notImplemented": ("この nasne では使えない機能です",
                                 "nasne のシステムソフトウェアが対応していない可能性があります。"),
        "error.clientNotAllowed": ("この Mac は nasne に許可されていません",
                                   "nasne HOME のメディアサーバーの設定で、この Mac の接続を許可してから、もう一度試してください。"),
        "error.webapi": ("nasne に断られました",
                         "登録をやり直すと直ることがあります。"),
        "error.invalidArgs": ("送った内容が正しくありません",
                              "アプリの不具合の可能性があります。"),
        "error.invalidIdFormat": ("指定した項目が見つかりません",
                                  "一覧を更新してから、もう一度試してください。"),
        // 830・836 の文言（836 は 2026-11-19。830 は 2026-11-20 に直した）
        "error.manualScheduleExists": ("時刻を指定した予約がほかにあります",
                                       "nasne には時刻を指定した予約を 1 件しか置けません。終わった後も一覧に残ります。一覧の時刻を指定した予約を消してから、もう一度試してください。"),
        "error.scheduleLimit": ("予約の数が上限に達しています",
                                "nasne の予約は \(ScheduleLimits.maximumCount) 件までです。要らない予約を消してから、もう一度試してください。"),
        // 録画の削除の 877。一覧を読んだ後にほかの機器で保護されたとき（保護した録画は削除を押せなくしている）
        "error.titleProtected": ("この録画は保護されています",
                                 "保護した録画は消せません。ほかの機器で保護を外してから、一覧を更新してもう一度試してください。"),
        "error.soapFault": ("nasne に断られました",
                            "時間を置いてもう一度試してください。"),
        "error.parse": ("nasne の応答を読めませんでした",
                        "nasne のシステムソフトウェアが想定と違う可能性があります。"),
        "error.validation": ("入力を確かめてください",
                             "入力した内容に誤りがあります。"),
        "error.unsupported": ("まだ対応していません",
                              "この操作はまだ使えません。"),
        "error.notNasne": ("そのアドレスに nasne が見つかりません",
                           "アドレスを確かめてください。nasne 以外の機器は登録できません。"),
        "error.noCredentials": ("資格情報がありません",
                                "録画を見るには、設定で資格情報を取り込んでください。"),
        "error.stalled": ("nasne から届かなくなりました",
                          "30 秒待っても映像が届かなかったので、再生をやめました。nasne とネットワークを確かめて、もう一度試してください。"),
        // ライブ。511 はほかの機器が配信を使っているとき（torne mobile HB の plan.md §56.1）。
        // 配信が途中で終わったときの nasne の理由は読めない（dmsStreamStopReasonListGet の値の意味は未確認）ので、見込みとして書く
        // nasne はチューナーが 1 つで、別の局を録画している間も 511 で断る（2026-11-22・Buffalo 製）。録画中の局が分かれば視聴の画面が別の文言に替える
        "error.liveInUse": ("ほかの機器が nasne の配信を使っています",
                            "ほかの機器での視聴を終えてから、もう一度試してください。nasne が別の局を録画している間も見られません。"),
        "error.liveStopped": ("ライブの受信が止まりました",
                              "nasne が配信を止めました。録画が始まったときなどに止まることがあります。時間を置いてもう一度試してください。"),
        "error.keychain": ("キーチェーンを読み書きできませんでした",
                           "キーチェーンへのアクセスを許可しているかを確かめてください。"),
    ]

    /// 鍵が表に無いときの文言
    static let fallback = (title: "処理を完了できませんでした", message: "時間を置いてもう一度試してください。")

    /// DTCP-IP の誤り（分類ごと）。資格情報の不備・再生の失敗・届かない
    static let dtcpMessages: [DTCPError.Category: (title: String, message: String)] = [
        .validation: ("資格情報を確かめてください",
                      "取り込んだ資格情報が正しくないか、組み合わせが合っていません。設定から取り込み直してください。"),
        .parse: ("再生の準備ができませんでした",
                 "nasne とのやり取りが想定と違いました。時間を置いてもう一度試してください。"),
        .unreachable: ("nasne に届かないので再生できません",
                       "nasne の電源と、この Mac が同じネットワークにつながっているかを確かめてください。"),
    ]

    /// 誤りを画面に出す形に直す
    public static func present(_ error: any Error) -> ErrorPresentation {
        switch error {
        case let nasne as NasneError:
            let text = nasneMessages[nasne.messageKey] ?? fallback
            return ErrorPresentation(title: text.title, message: text.message, code: nasne.code,
                                     canRetry: nasne.category == .unreachable)
        case let dtcp as DTCPError:
            // 配信の HEAD の 403 は、届かないのではなく、この機器を許可していないという応答
            let text = dtcp.code == String(NasneError.clientNotAllowedStatus)
                ? nasneMessages["error.clientNotAllowed"]!
                : dtcpMessages[dtcp.category] ?? fallback
            return ErrorPresentation(title: text.title, message: text.message, code: dtcp.code,
                                     canRetry: dtcp.category == .unreachable)
        case is AKEConnectionClosed:
            // 再生のための AKE では正常な終わり方。ここに来るのは、要る鍵を受け取る前に閉じられたとき
            return ErrorPresentation(title: "再生の準備ができませんでした",
                                     message: "nasne が途中で接続を閉じました。もう一度試してください。", canRetry: true)
        case let url as URLError:
            return ErrorPresentation(title: nasneMessages["error.unreachable"]!.title,
                                     message: nasneMessages["error.unreachable"]!.message,
                                     code: String(url.code.rawValue), canRetry: true)
        default:
            return ErrorPresentation(title: fallback.title, message: fallback.message)
        }
    }
}
