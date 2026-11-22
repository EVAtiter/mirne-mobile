import Foundation

// 再生の状態と、画面が知る再生のサービス（2026-11-21 に PlaybackController.swift から分けた）

/// 再生の段（失敗したときに、どの段かを出す）
public enum PlaybackStage: String, Sendable, Equatable {
    case credentials
    case head
    case authentication
    case request
    case receiving

    /// 画面に出す段の名前
    public var label: String {
        switch self {
        case .credentials: "資格情報"
        case .head: "接続先の確認"
        case .authentication: "認証"
        case .request: "受信の開始"
        case .receiving: "受信"
        }
    }
}

/// 再生の状態
public enum PlaybackState: Sendable, Equatable {
    case idle
    /// 始めている（どの段か）
    case starting(PlaybackStage)
    case playing
    /// 利用者が止めた
    case paused
    /// データが届かず、時計を止めて待っている（届いたら自動で再開する）
    case waiting
    /// 最後まで再生した
    case ended
    case failed(ErrorPresentation, PlaybackStage)

    /// 再生のボタンを押せないか（始めている途中）
    public var isStarting: Bool {
        if case .starting = self { return true }
        return false
    }
}

/// 再生しているものの種類（画質の切り替えはこれで張り直し方を変える）
public enum PlaybackKind: Sendable, Equatable {
    /// 録画（位置がある。時間指定で張り直せる）
    case recording
    /// ライブ（位置が無い。張り直すときは今の放送から。止めると受信を切り、再開すると今の放送から見直す。2026-11-20 に決めた）
    case live
}

/// 録画中の録画の伸びていく長さ（2026-11-20）。
///
/// nasne の一覧の長さは一覧を取った時点のもので、録画中の録画はその先も録れていき、配信も続く（2026-11-20 実機）。
/// 再生している間は、長さを「今 − 録り始めた時刻」として伸ばす（nasne へ問い合わせ直さない）。番組の終わりの時刻が分かれば、そこで伸ばすのを止める
public struct RecordingGrowth: Sendable, Equatable {
    /// 録り始めた時刻（xsrs の `scheduledStartDateTime`。位置はここからの秒）
    public var recordingStart: Date
    /// 伸ばすのを止める時刻（番組の終わり。分からなければ nil）
    public var limit: Date?

    public init(recordingStart: Date, limit: Date?) {
        self.recordingStart = recordingStart
        self.limit = limit
    }

    /// 時刻 `now` での長さ（秒）。一覧の長さ `base` より短くはしない
    public func duration(base: Double?, at now: Date) -> Double {
        let end = limit.map { min(now, $0) } ?? now
        return max(base ?? 0, end.timeIntervalSince(recordingStart))
    }
}

/// 再生のサービス（画面はこれだけを知る）
@MainActor
public protocol PlaybackService: AnyObject {
    var state: PlaybackState { get }
    /// いまの再生位置（秒。録画の頭から）。再生前は nil
    var positionSeconds: Double? { get }
    /// 録画の長さ（秒。分からなければ nil）
    var durationSeconds: Double? { get }
    /// 再生しているもの（録画かライブか）
    var kind: PlaybackKind { get }
    /// 再生する（再生中なら止めてから）。`from` は録画の頭からの秒（続きから・シーク。0 なら頭から）
    func play(_ resource: TitleResource, durationSeconds: Double?, from seconds: Double, growth: RecordingGrowth?)
    /// ライブの局を受信する（再生中なら止めてから。始めている途中でも頼み直せる：局を続けて替えたら最後の局だけを始める）
    func playLive(_ resource: TitleResource)
    /// いま再生している res（画質の切り替えで今の画質を出す）
    var currentResource: TitleResource? { get }
    /// 同じ録画・同じ局の別の画質へ張り直す
    func switchQuality(_ resource: TitleResource)
    func pause()
    func resume()
    func stop()
    /// 次の音声 ES へ切り替える（いまの位置から張り直す）
    func cycleAudio()
    /// 二重音声の主・副を選ぶ（二重音声を再生していれば、いまの位置から張り直す）
    func selectDualMono(_ channel: DualMonoChannel)
    /// 選んでいる二重音声の主・副
    var dualMonoChannel: DualMonoChannel { get }
    /// 再生の速さ（1 が等速。新しく再生するたびに 1 に戻る）
    var playbackRate: Double { get }
    /// 速さを替えられるか（録画だけ。録画中の録画は等速だけ）
    var canChangeRate: Bool { get }
    /// 速さを替える（`PlaybackRatePolicy.rates` のどれか。替えられないときは何もしない）
    func setRate(_ rate: Double)
    /// 次の速さへ（S キー）
    func cycleRate()
    /// 録画の頭からの秒の位置へ飛ぶ（いまの位置から張り直す）
    func seek(to seconds: Double)
    /// いまの位置から前後へ飛ぶ（負なら戻る）
    func skip(by seconds: Double)
    /// 飛べるか（再生している・止めている・待っている・始めている・最後まで、のとき）
    var canSeek: Bool { get }
    /// 画面に出す位置（始め直している間は、頼んだ位置）
    var displaySeconds: Double? { get }
    /// スリープの前に受信と接続を閉じ、一時停止にする（再開を押したら、止めた位置から張り直す）
    func suspendForSleep()
    /// いまの位置を止めどころとして知らせる（この再生で一度でも始まっていれば）。`occasion` は知らせる時機
    func recordCheckpoint(_ occasion: PlaybackCheckpoint.Occasion)
    var volume: Float { get set }
    var isMuted: Bool { get set }
}
