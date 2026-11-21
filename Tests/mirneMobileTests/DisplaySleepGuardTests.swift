import Foundation
import Testing

// ディスプレイのスリープの抑止。OS の印は出さず、出す・外すの回数だけを見る

@MainActor
private final class CountingAssertion: DisplaySleepAssertion {
    var activations = 0
    var deactivations = 0
    var fails = false
    func activate() -> Bool {
        activations += 1
        return !fails
    }
    func deactivate() { deactivations += 1 }
}

@MainActor
@Suite("ディスプレイのスリープの抑止")
struct DisplaySleepGuardTests {
    @Test("重なっても、先に終わった再生は、まだ再生中のものの抑止を解かない")
    func countsHolders() {
        let assertion = CountingAssertion()
        let guardian = DisplaySleepGuard(assertion: assertion)
        guardian.update("viewer", blocking: true)
        guardian.update("live", blocking: true)
        guardian.update("viewer", blocking: true)   // 見直しで同じことを何度伝えても印は 1 つ
        #expect(assertion.activations == 1)
        guardian.update("viewer", blocking: false)
        #expect(guardian.isBlocking)
        #expect(assertion.deactivations == 0)
        guardian.update("live", blocking: false)
        #expect(!guardian.isBlocking)
        #expect(assertion.deactivations == 1)
        guardian.update("live", blocking: false)    // 外した後に外しても何もしない
        #expect(assertion.deactivations == 1)
    }

    @Test("印を出せなかったら、次に伝えられたときにもう一度試す")
    func retriesWhenActivationFails() {
        let assertion = CountingAssertion()
        assertion.fails = true
        let guardian = DisplaySleepGuard(assertion: assertion)
        guardian.update("viewer", blocking: true)
        #expect(!guardian.isBlocking)
        assertion.fails = false
        guardian.update("viewer", blocking: true)
        #expect(guardian.isBlocking)
        #expect(assertion.activations == 2)
    }

    @Test("終了の前に全部の抑止を外す")
    func releaseAll() {
        let assertion = CountingAssertion()
        let guardian = DisplaySleepGuard(assertion: assertion)
        guardian.update("viewer", blocking: true)
        guardian.update("live", blocking: true)
        guardian.releaseAll()
        #expect(!guardian.isBlocking)
        #expect(guardian.holders.isEmpty)
        #expect(assertion.deactivations == 1)
    }
}
