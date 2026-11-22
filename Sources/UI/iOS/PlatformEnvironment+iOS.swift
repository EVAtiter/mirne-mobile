import AVFAudio
import os
import UIKit

/// OS ごとの部品（iOS / iPadOS 版）。アプリが裏へ回ったとき・前へ戻ったときを見張る。
///
/// 裏へ回ったら、再生を止めて nasne との接続を閉じ（位置は覚える。ライブはチューナーを放す）、映像も描かない。
/// 前へ戻ったら描き直し、裏へ回るときに再生していたなら、止めた位置から張り直す。
/// 電話・Siri などで音が割り込まれたら一時停止する（終わっても自動では再開しない。動画のアプリと同じ）
@MainActor
final class PlatformEnvironment {
    private var observers: [NSObjectProtocol] = []
    /// 裏へ回るときに再生していたか（戻ったら続きから張り直す）
    private var resumesOnForeground = false
    private let logger = Logger(subsystem: AppLog.subsystem, category: "power")

    init(playback: PlaybackController, renderer: VideoRenderer?) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.resumesOnForeground = playback.state == .playing || playback.state == .waiting || playback.state.isStarting
                    self.logger.notice("裏へ回った：受信と接続を閉じる（再生の状態 \(String(describing: playback.state), privacy: .public)）")
                    playback.suspendForSleep()
                    renderer?.isOnScreen = false
                }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.logger.notice("前へ戻った（再生の状態 \(String(describing: playback.state), privacy: .public)）")
                    renderer?.isOnScreen = true
                    renderer?.restartDrawing(reason: "前へ戻った")
                    if self.resumesOnForeground {
                        self.resumesOnForeground = false
                        playback.resume()
                    }
                }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
                let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                MainActor.assumeIsolated {
                    guard let self, rawType.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else { return }
                    let playing = playback.state == .playing || playback.state == .waiting
                    self.logger.notice("音が割り込まれた（再生の状態 \(String(describing: playback.state), privacy: .public)）")
                    if playing { playback.pause() }
                }
            },
        ]
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

extension AppEnvironment {
    /// 実機に向けた組み立て（ディスプレイのスリープは `isIdleTimerDisabled` で止める。
    /// nasne は SSDP を送れないので /24 の走査だけで探す。登録の画面を開いたら、ローカルネットワークの許可を聞いてから走査する）
    static func live() -> AppEnvironment {
        live(displaySleepAssertion: IdleTimerDisplaySleepAssertion(), usesSSDP: false)
    }
}

/// ディスプレイのスリープを止める印（`UIApplication.isIdleTimerDisabled`）。
/// 入れたつもりにせず、読み戻して効いたかを確かめる（端末の設定によっては効かないことがある）
@MainActor
final class IdleTimerDisplaySleepAssertion: DisplaySleepAssertion {
    private let logger = Logger(subsystem: AppLog.subsystem, category: "power")

    func activate() -> Bool {
        UIApplication.shared.isIdleTimerDisabled = true
        let applied = UIApplication.shared.isIdleTimerDisabled
        if applied {
            logger.info("画面のスリープを止めた")
        } else {
            logger.error("画面のスリープを止められない（isIdleTimerDisabled を読み戻すと false）")
        }
        return applied
    }

    func deactivate() {
        UIApplication.shared.isIdleTimerDisabled = false
        logger.info("画面のスリープの抑止をやめた")
    }
}
