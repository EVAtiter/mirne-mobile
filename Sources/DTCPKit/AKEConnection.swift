// AKE の接続（TCP）。IP の TTL = 3 と TCP_NODELAY を付けた BSD ソケット。
//
// 出典: torne mobile HB（MIT、© mar1mo-41414）の ios/Runner/AkeSocket.swift と lib/core/dtcp/ake.dart の
// AkeConnection。TTL = 3 と TCP_NODELAY は pydtcpip（MIT、© tsukumijima）の AKE クライアントに倣う
// （DTCP-IP の近接の制限。TTL が大きいと CHALLENGE の受理の直後に切るレコーダーがある、とのこと）。
// nasne は TTL が 4 以上の SYN を TCP の段で拒否する（RST → Connection refused。閾値はちょうど 3。
// torne mobile HB の plan.md §47.5 の実測）。TTL は connect の前に付ける。
//
// torne mobile HB からの変更: Flutter のチャネルを介さず、async の receive を直接持つ。

import Darwin
import Foundation
import Synchronization

/// AKE のフレームを運ぶ接続
protocol AKEConnection: Sendable {
    func send(_ bytes: [UInt8]) async throws
    /// 届いたバイトを返す。相手が閉じたら nil
    func receive() async throws -> [UInt8]?
    func close() async
}

/// `(host, port)` から AKE の接続を開く
typealias AKEConnectionFactory = @Sendable (_ host: String, _ port: UInt16) async throws -> any AKEConnection

enum AKESocket {
    /// AKE の接続の IP の TTL（DTCP-IP の近接の制限）
    static let timeToLive: Int32 = 3
    /// 接続を待つ時間
    static let connectTimeoutMilliseconds: Int32 = 10_000
    /// 1 回の recv で読む上限
    static let receiveBufferSize = 16 * 1024

    /// 既定の接続の作り方（TTL 3・TCP_NODELAY）
    static let factory: AKEConnectionFactory = { host, port in
        try await AKESocketConnection.connect(host: host, port: port)
    }
}

/// BSD ソケットの AKE の接続。connect の前に IP_TTL と TCP_NODELAY を設定し、poll で待つ非ブロッキングの
/// connect の後、ブロッキングの recv を専用のキューで回す
final class AKESocketConnection: AKEConnection {
    /// ソケットの記述子（閉じたら -1）
    private let descriptor: Mutex<Int32>
    private let queue = DispatchQueue(label: "com.slack-kingdom.mirne-mobile.ake-socket")

    private init(fd: Int32) {
        descriptor = Mutex(fd)
    }

    /// 開いたソケットの IP_TTL（試験で確かめる）
    var timeToLive: Int32? {
        descriptor.withLock { fd in
            guard fd >= 0 else { return nil }
            var value: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, IPPROTO_IP, IP_TTL, &value, &length) == 0 else { return nil }
            return value
        }
    }

    static func connect(host: String, port: UInt16) async throws -> AKESocketConnection {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try connectBlocking(host: host, port: port))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func failure(_ detail: String) -> DTCPError {
        .unreachable("dtcp:ake", detail)
    }

    private static func connectBlocking(host: String, port: UInt16) throws -> AKESocketConnection {
        // 相手は HEAD の応答で渡される IPv4 のアドレス
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &resolved) == 0, let first = resolved else {
            throw failure("could not resolve the AKE host")
        }
        defer { freeaddrinfo(resolved) }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure("socket() failed: \(String(cString: strerror(errno)))") }
        var ttl = AKESocket.timeToLive
        var noDelay: Int32 = 1
        guard setsockopt(fd, IPPROTO_IP, IP_TTL, &ttl, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw failure("setsockopt failed: \(message)")
        }
        // 書き込み先が閉じても SIGPIPE で落ちないようにする
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        if Darwin.connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) != 0 {
            guard errno == EINPROGRESS else {
                let message = String(cString: strerror(errno))
                Darwin.close(fd)
                throw failure("connect failed: \(message)")
            }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pollDescriptor, 1, AKESocket.connectTimeoutMilliseconds) > 0 else {
                Darwin.close(fd)
                throw failure("connect timed out")
            }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
            guard socketError == 0 else {
                Darwin.close(fd)
                throw failure("connect failed: \(String(cString: strerror(socketError)))")
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return AKESocketConnection(fd: fd)
    }

    private var currentDescriptor: Int32 { descriptor.withLock { $0 } }

    func send(_ bytes: [UInt8]) async throws {
        let fd = currentDescriptor
        guard fd >= 0 else { throw AKEConnectionClosed() }
        var offset = 0
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < bytes.count {
                let sent = Darwin.send(fd, base + offset, bytes.count - offset, 0)
                if sent < 0 && errno == EINTR { continue }
                guard sent > 0 else { throw Self.failure("send failed: \(String(cString: strerror(errno)))") }
                offset += sent
            }
        }
    }

    func receive() async throws -> [UInt8]? {
        let fd = currentDescriptor
        guard fd >= 0 else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var buffer = [UInt8](repeating: 0, count: AKESocket.receiveBufferSize)
                while true {
                    let count = recv(fd, &buffer, buffer.count, 0)
                    if count > 0 {
                        continuation.resume(returning: Array(buffer.prefix(count)))
                    } else if count == 0 {
                        continuation.resume(returning: nil)
                    } else if errno == EINTR {
                        continue
                    } else if errno == EBADF || errno == ENOTCONN {
                        // こちらから閉じた
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: Self.failure("recv failed: \(String(cString: strerror(errno)))"))
                    }
                    return
                }
            }
        }
    }

    func close() async {
        let fd = descriptor.withLock { fd in
            defer { fd = -1 }
            return fd
        }
        guard fd >= 0 else { return }
        // ブロック中の recv を起こしてから閉じる
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    deinit {
        let fd = descriptor.withLock { $0 }
        if fd >= 0 { Darwin.close(fd) }
    }
}
