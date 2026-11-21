import Foundation

// 再生の決まり（間・飛ばし・速さ・頼み直し）とライブの受信の誤りの形（2026-11-21 に PlaybackController.swift から分けた）

/// ライブの受信の誤りの形
public enum LivePlaybackErrors {
    /// 別の DTCP クライアントが視聴している間の配信の応答（torne mobile HB の plan.md §56.1）
    public static let inUseStatus = 511

    /// 511 か（HEAD の誤りに載った HTTP の状態で見る）
    public static func isInUse(_ error: any Error) -> Bool {
        let code: String? = switch error {
        case let dtcp as DTCPError: dtcp.code
        case let nasne as NasneError: nasne.code
        default: nil
        }
        return code == String(inUseStatus)
    }

    /// ライブの受信で起きた誤りを、画面に出す鍵の付いた形に直す（511 は「ほかの機器が使用中」）
    public static func translate(_ error: any Error) -> any Error {
        guard isInUse(error) else { return error }
        return NasneError(category: .http, code: String(inUseStatus), source: "playback:live", messageKey: "error.liveInUse",
                          detail: "HTTP \(inUseStatus)")
    }

    /// 受信の途中で nasne が配信を終えた（ライブには終わりが無いので、録画の開始などで nasne が止めた見込み）
    public static var stopped: NasneError {
        NasneError(category: .http, source: "playback:live", messageKey: "error.liveStopped", detail: "the live stream ended")
    }
}

/// 再生の決まりの値
public enum PlaybackTimingPolicy {
    /// 上流がこれだけ黙ったら（受信を待っている間だけ数える）、分類付きで終える
    public static let silenceLimit: Duration = .seconds(30)
    /// 先読みがこれより少なくなったら、時計を止めて待つ（90 kHz。0.2 秒）
    static let stallBelow: Int64 = 18_000
    /// 待っている間、先読みがこれだけ溜まったら再開する（90 kHz。1.5 秒）
    static let resumeAbove: Int64 = 135_000
    /// 状態を見に行く間隔
    static let monitorInterval: Duration = .milliseconds(200)
    /// ライブを始めるとき、時計を動かす前に溜める先読み（90 kHz。1.5 秒）。
    /// 再生系は音声が `PlaybackTiming.prerollAudio`（0.2 秒）先まで届いたら始めるが、ライブは放送の速さでしか届かないので、
    /// 先読みが待ちの線（`stallBelow`・0.2 秒）すれすれのまま進み、始めて約 0.2 秒で一度だけ「届くのを待っています」になっていた
    /// （2026-11-20 実機。待つ間に 1.5 秒溜まり、その後は出なかった）。始める前に、待ちから戻るときと同じだけ溜める。
    /// 値は `resumeAbove` と同じだが、ライブの始めの遅れとして別に変えられるように分けておく
    static let liveStartAhead: Int64 = 135_000
    /// 一時停止がこれより長かったら、戻すときにいまの位置から時間指定で張り直す。
    /// nasne は止まった受信を 90〜120 秒で切る（2026-11-18 実測）ので、その手前にする
    public static let reconnectAfterPause: Duration = .seconds(80)
    /// 一時停止のあいだ URLSession に打ち切らせない時間（打ち切りは suspend 中も数えるため）
    static let receiveIdleTimeout: TimeInterval = 3600
    /// 読み終えた後、先読みしたぶんを出し切るのを待つ上限
    static let drainLimit: Duration = .seconds(15)
}

/// シークと前後への飛ばしの決まり
public enum SeekPolicy {
    /// ← → と操作部のボタンで前後へ飛ばす秒（torne mobile HB の「10秒戻し」「10秒スキップ」と同じ。2026-11-20）
    public static let skipSeconds: Double = 10
    /// 録画の終わりからこれより手前までしか飛ばさない（終わりちょうどを時間指定で頼まない）
    public static let endMargin: Double = 1
    /// 録画中の録画では、録れているところ（伸びていく長さの終わり）からこれより手前までしか飛ばさない。
    /// 終わりの間際へ飛ぶと、配信が放送の速さでしか届かず、先読みが溜まらないまま待ちになるため（体感の値。2026-11-20）
    public static let growingEdgeMargin: Double = 10

    /// 飛ばす先を録画の中に収める：0 より前にせず、長さが分かれば終わりの `margin` 手前より後にしない
    public static func clamp(_ seconds: Double, duration: Double?, margin: Double = endMargin) -> Double {
        var target = max(0, seconds)
        if let duration, duration > margin { target = min(target, duration - margin) }
        return target
    }
}

/// 再生速度の決まり（2026-11-21。torne mobile HB §86.7 に倣う）
public enum PlaybackRatePolicy {
    /// 選べる速さ。公式 torne の早見（1.5〜2 倍）を覆い、会話の多い番組向けに 1.25 倍を足した。2 倍より上は音が聞き取りにくくなるので出さない
    public static let rates: [Double] = [1, 1.25, 1.5, 2]
    /// 等速
    public static let normal: Double = 1

    /// 次の速さ（S キー。2 倍の次は 1 倍。知らない速さなら等速へ）
    public static func next(after rate: Double) -> Double {
        guard let index = rates.firstIndex(of: rate) else { return normal }
        return rates[(index + 1) % rates.count]
    }

    /// 速さを替えられるか：録画だけ（ライブは追いつく蓄積が無い）。録画中の録画は等速だけ
    /// （nasne は録画中の録画を実時間に絞らずに流し、録れているところの先端に追いつくと切れる。torne mobile HB §90.3）
    public static func canChange(kind: PlaybackKind, isGrowing: Bool) -> Bool {
        kind == .recording && !isGrowing
    }

    /// 表示の名前（「1倍」「1.25倍」。画質の「3倍」と同じ書き方）
    public static func label(_ rate: Double) -> String {
        var text = String(format: "%.2f", rate)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "倍"
    }
}

/// nasne が配信の枠の空きを待たせるときの HTTP 512 を、間を置いて頼み直す（torne mobile HB の plan.md §78.3・§80.4）。
///
/// 時間指定の新しい GET は、前の応答を読み捨てている途中や、読まずに捨てた応答があると 512 で断られることがある
/// （nasne の同時の配信の枠が空いていないためと見られる。nasne 側の規則は未測定）。前の受信は読み切らずに閉じる
/// （`cancelAndWait`）ので起きにくいが、閉じた接続を nasne が片付けるのが遅れると出る
public enum BusyRetryPolicy {
    /// 一時的な断りとして頼み直す HTTP の状態
    public static let busyStatus = 512
    /// 頼み直す前に置く間（回数はこの数。torne mobile HB と同じ 500 ms・1 秒・2 秒）
    public static let delays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]

    /// `attempt` で要求を開き、512 なら `discard` で閉じてから間を置いて開き直す。
    /// 512 でない応答（200 を含む）か、頼み直しを使い切ったときの応答を返す（状態の判定は呼び出し側）
    static func open<Value>(delays: [Duration] = delays,
                            sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                            onRetry: (Int) -> Void = { _ in },
                            attempt: () async throws -> (value: Value, status: Int),
                            discard: (Value) -> Void) async throws -> (value: Value, status: Int) {
        var retries = 0
        while true {
            let opened = try await attempt()
            guard opened.status == busyStatus, retries < delays.count else { return opened }
            discard(opened.value)
            try await sleep(delays[retries])
            retries += 1
            onRetry(retries)
        }
    }
}

/// 配信の HEAD の HTTP 511 を、間を置いて頼み直す（2026-11-20）。
///
/// こちらの受信を止めた・局を替えた直後（0.8〜2 秒）の HEAD は、ほかの機器が使っていなくても 511 になることがある
/// （止めたばかりの受信を nasne がまだ放していないと見ている。少し後の頼みは通った）。
/// 頼み直しを使い切っても 511 なら、そのとき初めて「ほかの機器が使っています」を出す。
/// 間は 512 の頼み直し（`BusyRetryPolicy`）と同じ値で始めたが、意味が違うので別の定数にする
public enum InUseRetryPolicy {
    /// 頼み直す前に置く間（回数はこの数。合わせて 3.5 秒。実機では 2 秒後の頼みが通った）
    public static let delays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]

    /// `attempt` を行い、511 で失敗したら間を置いてやり直す。511 でない誤りと、使い切ったときの 511 はそのまま投げる
    static func run<Value>(delays: [Duration] = delays,
                           sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                           onRetry: (Int) -> Void = { _ in },
                           attempt: () async throws -> Value) async throws -> Value {
        var retries = 0
        while true {
            do {
                return try await attempt()
            } catch let error where LivePlaybackErrors.isInUse(error) && retries < delays.count {
                try await sleep(delays[retries])
                retries += 1
                onRetry(retries)
            }
        }
    }
}
