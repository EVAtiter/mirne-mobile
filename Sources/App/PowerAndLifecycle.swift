import AppKit
import IOKit.pwr_mgt
import os

// 電源とライフサイクル。
//
// - 再生中はディスプレイのスリープを抑える（数えるのは Playback の `DisplaySleepGuard`。ここは OS の印の中身）
// - スリープの前に受信と接続を閉じ、復帰後は一時停止のまま待つ（`PowerObserver`）
// - 終了の前に受信を止め終わる（接続を閉じ、鍵を捨てる）のを待つ（`AppDelegate`）

/// 終了の決まり
enum TerminationTiming {
    /// 終了の前に受信を止め終わるのを待つ上限。nasne に届かないときに終了が止まったままにならないように
    static let shutdownLimit: Duration = .seconds(3)
}

/// ディスプレイのスリープを止める印（`IOPMAssertion`）。印は `deactivate` で外すまで残る（プロセスが終われば OS も外す）
@MainActor
final class IOPMDisplaySleepAssertion: DisplaySleepAssertion {
    /// 印の名前（`pmset -g assertions` に出る）。日本語にすると `pmset` が空として出すので英字にする（mirne と同じ）
    static let reason = "mirne mobile is playing a recording"

    private var assertion: IOPMAssertionID?
    private let logger = Logger(subsystem: AppLog.subsystem, category: "power")

    func activate() -> Bool {
        guard assertion == nil else { return true }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), Self.reason as CFString, &id)
        guard result == kIOReturnSuccess else {
            logger.error("ディスプレイのスリープを止められない: \(result, privacy: .public)")
            return false
        }
        assertion = id
        logger.info("ディスプレイのスリープを止めた")
        return true
    }

    func deactivate() {
        guard let id = assertion else { return }
        IOPMAssertionRelease(id)
        assertion = nil
        logger.info("ディスプレイのスリープの抑止をやめた")
    }
}

/// スリープと復帰を見張る
@MainActor
final class PowerObserver {
    private var observers: [NSObjectProtocol] = []
    private let logger = Logger(subsystem: AppLog.subsystem, category: "power")

    init(playback: PlaybackController, renderer: VideoRenderer?) {
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [logger] _ in
                MainActor.assumeIsolated {
                    logger.notice("スリープの前に受信と接続を閉じる（再生の状態 \(String(describing: playback.state), privacy: .public)）")
                    playback.suspendForSleep()
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [logger] _ in
                MainActor.assumeIsolated {
                    // 勝手に再生を始めない。止めた絵を描き直せるよう、表示のタイミングだけ作り直す（mirne と同じ）
                    logger.notice("スリープから復帰した（再生の状態 \(String(describing: playback.state), privacy: .public)）")
                    renderer?.restartDrawing(reason: "スリープから復帰した")
                }
            },
        ]
    }

    isolated deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }
}

/// 終了の前の後始末。組み立て（`AppEnvironment`）もここで持つ（終了の問い合わせで再生に届くように）
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 部品の組み立て（起動時の 1 か所）
    let environment = AppEnvironment.live()
    private let logger = Logger(subsystem: AppLog.subsystem, category: "power")
    private var terminating = false
    private var replied = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let environment = environment
        environment.displaySleep.releaseAll()
        guard environment.playback.needsShutdown else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        logger.notice("終了の前に受信と接続を閉じる")
        // 止め終わるか、上限の時間が過ぎるか、早いほうで終了する
        Task { @MainActor [weak self] in
            await environment.playback.shutdown()
            await environment.flushViewing()
            self?.finishTermination(sender, finished: true)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: TerminationTiming.shutdownLimit)
            self?.finishTermination(sender, finished: false)
        }
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication, finished: Bool) {
        guard !replied else { return }
        replied = true
        if finished {
            logger.notice("受信と接続を閉じたので終了する")
        } else {
            logger.error("受信を止め終わる前に上限の時間が過ぎたので、そのまま終了する")
        }
        sender.reply(toApplicationShouldTerminate: true)
    }
}
