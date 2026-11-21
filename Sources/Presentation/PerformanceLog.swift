import Darwin
import Foundation
import os

// 非機能要件の計測のログ。
//
// 出すのは時間と数値だけ（番組名・局名・アドレス・ID は出さない）。読むときは
// `log stream --predicate 'subsystem == "com.slack-kingdom.mirne-mobile" AND category == "measure"' --level info`。
// AppKit・SwiftUI に依存させない。

// 計測は開発用のビルド（Debug）だけに入れる。公開版（Release）には入れない（2026-11-21）
#if DEBUG

/// 計測のログ
public enum PerformanceLog {
    public static let logger = Logger(subsystem: AppLog.subsystem, category: "measure")

    /// このプロセスが始まった時刻（カーネルの記録。起動から画面に出るまでの計測の起点）。読めなければ nil
    public static let processStart: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    /// プロセスが始まってからのミリ秒（始まりが読めなければ nil）
    public static func millisecondsSinceProcessStart(now: Date = Date()) -> Int? {
        processStart.map { Int((now.timeIntervalSince($0) * 1000).rounded()) }
    }

    /// 起動してから情報の画面に値が出たこと・全部の区画がそろったことを、1 回ずつ記録する
    @MainActor private static var launchToInfoLogged = false
    @MainActor private static var launchToInfoCompleteLogged = false

    /// 情報の画面の最初の区画に値が出た（起動してから最初の 1 回だけログに出す。「起動 → 情報の画面の表示」。
    /// 区画は読めたものから出すので、最初の区画に値が出たときを表示とする。2026-11-21）
    @MainActor public static func infoShown() {
        guard !launchToInfoLogged else { return }
        launchToInfoLogged = true
        logLaunch("起動から情報の画面に値が出るまで")
    }

    /// 情報の画面の全部の区画を読み終えた（起動してから最初の 1 回だけ。参考値）
    @MainActor public static func infoCompleted() {
        guard !launchToInfoCompleteLogged else { return }
        launchToInfoCompleteLogged = true
        logLaunch("起動から情報の画面の全部の区画がそろうまで")
    }

    private static func logLaunch(_ label: String) {
        if let elapsed = millisecondsSinceProcessStart() {
            logger.info("計測: \(label, privacy: .public) \(elapsed, privacy: .public) ms")
        } else {
            logger.info("計測: \(label, privacy: .public)（プロセスの開始時刻が読めない）")
        }
    }
}

#endif
