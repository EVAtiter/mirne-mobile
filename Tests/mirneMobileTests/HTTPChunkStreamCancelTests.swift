import Foundation
import Testing

// 受信（HTTPChunkStream）を作ってから start() までの間に止めたとき（2026-11-21）。
// 前は cancel() が空振りし、その後の start() が要求を送っていた
struct HTTPChunkStreamCancelTests {
    /// 送れば接続を断られる宛先（要求を送らないことを確かめるので、届かなくてよい）
    private static let request = URLRequest(url: URL(string: "http://localhost:9/never")!)

    @Test("start() の前に cancel() したら、要求を送らずに CancellationError を投げ、本文も終わる")
    func cancelBeforeStart() async throws {
        let stream = HTTPChunkStream(request: Self.request)
        stream.cancel()
        await #expect(throws: CancellationError.self) { _ = try await stream.start() }
        await #expect(throws: CancellationError.self) {
            for try await _ in stream.chunks {}
        }
    }

    @Test("取り消したタスクから start() を呼んだら、要求を送らずに CancellationError を投げる")
    func startFromCancelledTask() async throws {
        let stream = HTTPChunkStream(request: Self.request)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await stream.start()
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
