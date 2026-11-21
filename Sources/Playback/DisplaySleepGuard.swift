import Foundation

// ディスプレイのスリープの抑止。
//
// 再生しているもの（視聴ウィンドウなど）が、それぞれの名前で「抑えたい・抑えなくてよい」を伝える。
// 1 つでも抑えたいものがあれば OS に印を出し、全部が抑えなくてよくなったら外す。
// 名前ごとに数えて持つので、重なっても先に終わった再生が、まだ再生中のものの抑止を解かない。
// AppKit・IOKit に依存させない（OS に印を出す中身は App の側の `DisplaySleepAssertion`）。

/// OS にディスプレイのスリープを止める印を出す・外す
@MainActor
public protocol DisplaySleepAssertion: AnyObject {
    /// 印を出す。出せなければ false
    func activate() -> Bool
    /// 印を外す
    func deactivate()
}

/// どの再生が抑えているかを数えて持ち、OS の印を 1 つだけ出す
@MainActor
public final class DisplaySleepGuard {
    private let assertion: any DisplaySleepAssertion
    /// いま抑えたいと言っているものの名前
    public private(set) var holders: Set<String> = []
    /// OS に印を出しているか
    public private(set) var isBlocking = false

    public init(assertion: any DisplaySleepAssertion) {
        self.assertion = assertion
    }

    /// `holder` が抑えたいか（再生中で、窓をしまっていない）を伝える
    public func update(_ holder: String, blocking: Bool) {
        if blocking {
            holders.insert(holder)
        } else {
            holders.remove(holder)
        }
        apply()
    }

    /// 全部の抑止を外す（終了の前）
    public func releaseAll() {
        holders.removeAll()
        apply()
    }

    private func apply() {
        if !holders.isEmpty, !isBlocking {
            // 出せなかったら、次に伝えられたときにもう一度試す
            isBlocking = assertion.activate()
        } else if holders.isEmpty, isBlocking {
            assertion.deactivate()
            isBlocking = false
        }
    }
}
