import Foundation

/// HTTP の本文を、届いた塊（Data）のまま順に渡す。読み手が遅れたら受信を止める。
///
/// `URLSession.bytes` の AsyncBytes は 1 バイトずつ await するので、nasne の録画の受信で 0.17 MB/s しか出なかった
/// （2026-11-18 の実機。3倍の再生に要る約 1 MB/s に届かない）。塊で受け取る `URLSessionDataDelegate` に替えた。
///
/// 録画の再生では読み手（`RecordingFeeder`）が先読みに合わせて待つ。その間も URLSession が受け取り続けると
/// メモリに溜まり続けるので、読み手が受け取っていない量が `highWater` を超えたらタスクを止め（`suspend`。
/// TCP の窓が埋まって nasne も送るのを止める）、`lowWater` を下回ったら再開する。
final class HTTPChunkStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// 読み手が受け取っていない量がこれを超えたら、受信を止める
    static let highWater = 8 * 1024 * 1024
    /// 止めた後、これを下回ったら受信を再開する
    static let lowWater = 2 * 1024 * 1024
    /// データが届かないまま、これだけ経ったら打ち切る（URLSession の既定と同じ 60 秒）。
    /// **受信を止めている（suspend）間もこの時間は数えられる**（2026-11-18 の実機で、120 秒の一時停止が
    /// -1001 で終わった。nasne ではなくこちらの打ち切り）。長く止める見込みなら、呼び出し側が長くする
    static let defaultIdleTimeout: TimeInterval = 60

    /// 本文の塊
    let chunks: AsyncThrowingStream<Data, Error>

    private let request: URLRequest
    private let idleTimeout: TimeInterval
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var buffered = 0
    private var suspended = false
    /// `cancel()` を呼んだ（その後の `start()` は要求を送らずに `CancellationError` を投げる）
    private var cancelled = false
    /// 受信を止めた回数（計測用）
    private(set) var suspensions = 0

    init(request: URLRequest, idleTimeout: TimeInterval = HTTPChunkStream.defaultIdleTimeout) {
        self.request = request
        self.idleTimeout = idleTimeout
        var captured: AsyncThrowingStream<Data, Error>.Continuation!
        chunks = AsyncThrowingStream(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
        super.init()
        continuation.onTermination = { [weak self] _ in self?.cancel() }
    }

    /// 受信に使う URLSession の設定（WebAPI と同じく `NasneSessionConfiguration` で作る。プロキシ・キャッシュ・Cookie を使わない）
    var sessionConfiguration: URLSessionConfiguration {
        NasneSessionConfiguration.make(timeout: idleTimeout)
    }

    /// 要求を送り、応答の見出しを待つ。本文は `chunks` で受け取る。
    ///
    /// 呼んだタスクが取り消されたら（見出しを待っている間も）受信をやめる。`start()` の前に `cancel()` されていれば、
    /// 要求を送らずに `CancellationError` を投げる（2026-11-21。前は、受信を作ってから `start()` までの間に止めると
    /// `cancel()` が空振りし、その後の `start()` が要求を送って、誰も読まない受信が打ち切りの時間まで nasne の配信の枠を持ち続けることがありえた）
    func start() async throws -> HTTPURLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<HTTPURLResponse, Error>) in
                let task: URLSessionDataTask? = lock.withLock {
                    guard !cancelled else { return nil }
                    let queue = OperationQueue()
                    queue.maxConcurrentOperationCount = 1
                    queue.name = "mirne-mobile.http-chunks"
                    let session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: queue)
                    let task = session.dataTask(with: request)
                    self.session = session
                    self.task = task
                    responseContinuation = waiter
                    return task
                }
                guard let task else {
                    continuation.finish(throwing: CancellationError())
                    waiter.resume(throwing: CancellationError())
                    return
                }
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    /// 読み手が塊を受け取ったら呼ぶ（止めた受信を再開するかを決める）
    func consumed(_ count: Int) {
        let resume: URLSessionDataTask? = lock.withLock {
            buffered -= count
            guard suspended, buffered < Self.lowWater else { return nil }
            suspended = false
            return task
        }
        resume?.resume()
    }

    /// 受信をやめる（`start()` の前でもよい。その後の `start()` は要求を送らない）
    func cancel() {
        let session = lock.withLock { () -> URLSession? in
            cancelled = true
            return self.session
        }
        session?.invalidateAndCancel()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.allow)
        let waiter = lock.withLock { () -> CheckedContinuation<HTTPURLResponse, Error>? in
            defer { responseContinuation = nil }
            return responseContinuation
        }
        if let http = response as? HTTPURLResponse {
            waiter?.resume(returning: http)
        } else {
            waiter?.resume(throwing: DTCPError.unreachable("dtcp:http", "the response is not HTTP"))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let shouldSuspend = lock.withLock { () -> Bool in
            buffered += data.count
            guard !suspended, buffered > Self.highWater else { return false }
            suspended = true
            suspensions += 1
            return true
        }
        if shouldSuspend { dataTask.suspend() }
        continuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let waiter = lock.withLock { () -> CheckedContinuation<HTTPURLResponse, Error>? in
            defer { responseContinuation = nil }
            return responseContinuation
        }
        waiter?.resume(throwing: error ?? DTCPError.unreachable("dtcp:http", "the connection ended before a response"))
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        session.finishTasksAndInvalidate()
    }
}
