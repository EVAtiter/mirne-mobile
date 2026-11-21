// AKE の状態機械をフェイクのソースに対して確かめる試験と、鍵の引き当て・TTL 3 のソケットの試験。
//
// torne mobile HB（MIT、© mar1mo-41414）の test/dtcp_test.dart・test/dtcp_streaming_test.dart の該当部分を移したもの。
// フェイクのソースは pydtcpip（MIT、© tsukumijima）の tests/fakes.py の移植（torne mobile HB 経由）。
// 実機（nasne）には一切つながない。ソケットの試験はループバックだけ。

import Darwin
import Foundation
import Synchronization
import Testing

private typealias V = DTCPTestVectors

/// メモリの中の AKE の接続の片側
actor FakeAKEConnection: AKEConnection {
    private var inbox: [[UInt8]] = []
    private var waiter: CheckedContinuation<[UInt8]?, Never>?
    private var closed = false
    private var peer: FakeAKEConnection?
    /// こちらから送ったバイト（フレームの生バイトの検査に使う）
    private(set) var sent: [[UInt8]] = []

    func pair(with peer: FakeAKEConnection) { self.peer = peer }

    func deliver(_ bytes: [UInt8]) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: bytes)
        } else {
            inbox.append(bytes)
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        sent.append(bytes)
        await peer?.deliver(bytes)
    }

    func receive() async throws -> [UInt8]? {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }

    /// こちらの受信を終わらせる（相手が閉じたのと同じに見える）
    func close() async {
        closed = true
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }

    static func makePair() async -> (client: FakeAKEConnection, source: FakeAKEConnection) {
        let client = FakeAKEConnection()
        let source = FakeAKEConnection()
        await client.pair(with: source)
        await source.pair(with: client)
        return (client, source)
    }
}

/// 試験の中の検査に失敗した
struct FakeSourceFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw FakeSourceFailure(description: message) }
}

/// 記録したバイトをフレームごとに分ける
private func wireFrames(_ chunks: [[UInt8]]) throws -> [[UInt8]] {
    var all = chunks.flatMap { $0 }
    var frames = [[UInt8]]()
    while let (_, consumed) = try AKEControlFrame.parse(all) {
        frames.append(Array(all.prefix(consumed)))
        all.removeFirst(consumed)
    }
    return frames
}

/// 診断ログを集める
final class LogCapture: Sendable {
    private let storage = Mutex<[String]>([])
    var lines: [String] { storage.withLock { $0 } }
    var diagnostics: DTCPDiagnostics {
        DTCPDiagnostics { category, message in
            self.storage.withLock { $0.append("[\(category.rawValue)] \(message)") }
        }
    }
}

/// Full Authentication のソース側を演じるフェイク（pydtcpip の tests/fakes.py の移植）
private func runFakeSource(_ connection: FakeAKEConnection) async throws {
    let reader = AKEFrameReader(connection: connection, diagnostics: .none)
    let sourceCertificate = hexBytes(V.katSrcCert)
    let sourcePrivate = DTCPBigUInt(bytes: hexBytes(V.katSrcPriv))

    // クライアントの CHALLENGE
    var frame = try await reader.next()
    try check(frame.command == AKECommand.challenge && !frame.isResponse, "client CHALLENGE")
    let sinkNonce = Array(frame.payload[0..<16])
    let sinkPublic = try DTCPCertificate.verify(frame.payload[16...], authorityKeys: testAuthority)
    try await reader.send(frame.accepted())

    // ソースの CHALLENGE（ソースのフレームは役割 0x00）
    let sourceNonce = hexBytes(V.katSrcNonce)
    try await reader.send(AKEControlFrame(command: AKECommand.challenge, payload: sourceNonce + sourceCertificate,
                                          roleByte: 0))
    frame = try await reader.next()
    try check(frame.isResponse && frame.command == AKECommand.challenge, "accepted source CHALLENGE")

    // ソースの RESPONSE（一時鍵 B）
    let ephemeralB = DTCPBigUInt(bytes: hexBytes(V.katEphB))
    let ephemeralBPublic = DTCPCurve.generator.multiplied(by: ephemeralB)!
    let responseData = ephemeralBPublic.bytes + [0, 0, 0]
    let signature = DTCPSignature.signDeterministic(privateKey: sourcePrivate, data: sinkNonce + responseData)
    try await reader.send(AKEControlFrame(command: AKECommand.response, payload: responseData + signature, roleByte: 0))
    frame = try await reader.next()
    try check(frame.isResponse && frame.command == AKECommand.response, "accepted source RESPONSE")

    // クライアントの RESPONSE：署名を確かめて認証鍵を導く
    frame = try await reader.next()
    try check(!frame.isResponse && frame.command == AKECommand.response && frame.payload.count == 83, "client RESPONSE")
    let clientEphemeral = DTCPPoint(bytes: frame.payload[0..<40])!
    try check(DTCPSignature.verify(publicKey: sinkPublic, data: sourceNonce + frame.payload[0..<43],
                                   signature: frame.payload[43...]), "client signature")
    try await reader.send(frame.accepted())
    let authenticationKey = Array(try DTCPSignature.sharedSecret(privateKey: ephemeralB,
                                                                 peerPublicKey: clientEphemeral).suffix(12))

    // RTT：READY の往復・SETUP（既知答のカウンタ）・TEST・VERIFY
    try await reader.send(AKEControlFrame(command: AKECommand.rttReady, payload: [], roleByte: 0))
    frame = try await reader.next()
    try check(frame.isResponse && frame.command == AKECommand.rttReady, "accepted RTT_READY")
    frame = try await reader.next()
    try check(!frame.isResponse && frame.command == AKECommand.rttReady, "client RTT_READY")
    try await reader.send(frame.accepted())

    let counter = UInt16(V.katRttCounter)
    try await reader.send(AKEControlFrame(command: AKECommand.rttSetup, payload: [UInt8(counter >> 8), UInt8(counter & 0xFF)],
                                          roleByte: 0))
    frame = try await reader.next()
    try check(frame.isResponse && frame.command == AKECommand.rttSetup, "accepted RTT_SETUP")
    let expected = hexBytes(V.katRttExpected)
    let responseMAC = hexBytes(V.katRttResponse)
    let verifyMAC = hexBytes(V.katRttVerify)

    try await reader.send(AKEControlFrame(command: AKECommand.rttTest, payload: expected, roleByte: 0))
    frame = try await reader.next()
    try check(frame.isResponse && frame.command == AKECommand.rttTest && frame.payload == responseMAC, "RTT_TEST response")

    try await reader.send(AKEControlFrame(command: AKECommand.rttVerify, payload: verifyMAC, roleByte: 0))
    frame = try await reader.next()
    try check(frame.isResponse && frame.command == AKECommand.rttVerify && frame.payload == verifyMAC, "RTT_VERIFY response")

    // EXCHANGE_KEY（既知答の交換鍵を認証鍵で隠したもの）
    let exchangeKey = hexBytes(V.katPcpExchangeKey)
    let masked = zip(exchangeKey, authenticationKey).map { $0 ^ $1 }
    try await reader.send(AKEControlFrame(command: AKECommand.exchangeKey, payload: [0x2A, 0] + masked, roleByte: 0))
    frame = try await reader.next()
    try check(frame.isResponse && frame.command == AKECommand.exchangeKey, "accepted EXCHANGE_KEY")
    // 写しの決まり：受理のフレームはソースのフレームのヘッダを受け継ぐので、ラベルのバイトは 0
    // （鍵のラベルはヘッダではなくペイロードにある）
    try check(frame.label == 0, "accepted EXCHANGE_KEY label byte")

    // どちらも失効させない新しい SRM（版 10）で SRM_UPDATE
    try await reader.send(AKEControlFrame(command: AKECommand.srmUpdate, payload: hexBytes(V.katSrmUpdateData), roleByte: 0))
    frame = try await reader.next()
    try check(frame.isResponse && frame.command == AKECommand.srmUpdate, "accepted SRM_UPDATE")
}

private func makeClient(connection: FakeAKEConnection, srmStore: DTCPMemorySRMStore,
                        diagnostics: DTCPDiagnostics = .none) throws -> AKEClient {
    let credentials = try DTCPCredentials(certificate: hexBytes(V.katSinkCert), privateKey: hexBytes(V.katSinkPriv),
                                          authorityKeys: testAuthority)
    return AKEClient(credentials: credentials, srmStore: srmStore, connectionFactory: { _, _ in connection },
                     authorityKeys: testAuthority, diagnostics: diagnostics,
                     randomBytes: { _ in hexBytes(V.katSinkNonce) },
                     ephemeralScalar: { DTCPBigUInt(bytes: hexBytes(V.katEphA)) })
}

/// 試験の中の待ち時間の上限
private let testWait: Duration = .seconds(10)

@Suite struct AKEFakeSourceTests {
    // 試験の宛先は文書用のアドレス（RFC 5737）。フェイクの接続なので実際にはどこにもつながない
    private let host = "192.0.2.1"
    private let port: UInt16 = 58293

    @Test func fullAuthenticationRTTExchangeKeyAndSRMUpdate() async throws {
        let (clientConnection, sourceConnection) = await FakeAKEConnection.makePair()
        let srmStore = DTCPMemorySRMStore(authorityKeys: testAuthority)
        let client = try makeClient(connection: clientConnection, srmStore: srmStore)
        let source = Task { try await runFakeSource(sourceConnection) }

        let session = try await client.connect(host: host, port: port)
        #expect(try await session.waitFirstExchangeKey(timeout: testWait) == 0x2A)
        let key = try await session.waitExchangeKey(0x2A, timeout: testWait)
        #expect(DTCPBytes.hex(key) == V.katPcpExchangeKey)
        try await source.value
        // SRM_UPDATE の受理は交換鍵の後なので、保存されるまで少し待つことがある
        for _ in 0..<100 where srmStore.savedRaw == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(srmStore.savedRaw.map(DTCPBytes.hex) == V.katSrmUpdateData)
        await session.close()

        // 生バイト（torne mobile HB の計画書 §28.2）：クライアントのフレームのヘッダが参照実装と一致する
        let clientFrames = try wireFrames(await clientConnection.sent)
        let sourceFrames = try wireFrames(await sourceConnection.sent)
        #expect(clientFrames.count == 11)
        // 要求：役割 0x01（シンク）・状態 0x0F・種別 0x00（CHALLENGE・RESPONSE・RTT_READY）
        for index in [0, 3, 5] {
            #expect(clientFrames[index][8] == 0x01, "client frame \(index) role byte")
            #expect(clientFrames[index][10] == 0x0F, "client frame \(index) status")
            #expect(clientFrames[index][3] == 0x00, "client frame \(index) ctype")
        }
        // ACCEPTED は受け取ったフレームのヘッダの写し（4〜10 バイト目。長さを除く）：種別 0x09・状態 0、
        // 手順・鍵の種類・役割・ラベルは受け継ぐ。クライアントの 1 番はソースの 1 番（ソースの CHALLENGE、
        // 役割 0x00）に、9 番はソースの 9 番（EXCHANGE_KEY）に答える
        for (clientIndex, sourceIndex) in [(1, 1), (9, 9)] {
            let accepted = clientFrames[clientIndex]
            let original = sourceFrames[sourceIndex]
            #expect(accepted[3] == 0x09)
            #expect(accepted[10] == 0x00)
            for byte in 4...9 {
                #expect(accepted[byte] == original[byte], "accepted header byte \(byte) must be copied")
            }
        }
    }

    @Test func aSourceCloseAfterAuthenticationIsANormalEnd() async throws {
        let log = LogCapture()
        let (clientConnection, sourceConnection) = await FakeAKEConnection.makePair()
        let client = try makeClient(connection: clientConnection, srmStore: DTCPMemorySRMStore(authorityKeys: testAuthority),
                                    diagnostics: log.diagnostics)
        let source = Task { try await runFakeSource(sourceConnection) }
        let session = try await client.connect(host: host, port: port)
        #expect(try await session.waitFirstExchangeKey(timeout: testWait) == 0x2A)
        try await source.value

        // 実機の nasne は認証の直後に AKE の接続を閉じる（torne mobile HB の計画書 §29 の実測）
        await clientConnection.close()
        for _ in 0..<100 where !log.lines.contains(where: { $0.contains("closed by the source") }) {
            try await Task.sleep(for: .milliseconds(10))
        }

        // 受け取った鍵は終わったセッションでも引ける
        #expect(DTCPBytes.hex(try await session.waitExchangeKey(0x2A, timeout: .seconds(5))) == V.katPcpExchangeKey)
        // 届かなかったラベルは、時間切れを待たずに閉じた合図で返る（呼び出し側が認証し直せる）
        await #expect(throws: AKEConnectionClosed.self) {
            try await session.waitExchangeKey(0x77, timeout: .seconds(5))
        }
        // 閉じたことは正常な終わりとして記録され、接続の失敗やメッセージの誤りとしては記録されない
        #expect(log.lines.contains { $0.contains("closed by the source") })
        #expect(!log.lines.contains { $0.contains("connection failed") })
        #expect(!log.lines.contains { $0.contains("message loop ended") })
    }

    @Test func aRevokedSourceIsRejectedAtChallenge() async throws {
        let (clientConnection, sourceConnection) = await FakeAKEConnection.makePair()
        // 保存してある SRM がソースを失効させている
        let srmStore = DTCPMemorySRMStore(authorityKeys: testAuthority, seed: hexBytes(V.katSrmData))
        let client = try makeClient(connection: clientConnection, srmStore: srmStore)
        let source = Task {
            let reader = AKEFrameReader(connection: sourceConnection, diagnostics: .none)
            let challenge = try await reader.next()
            try await reader.send(challenge.accepted())
            try await reader.send(AKEControlFrame(command: AKECommand.challenge,
                                                  payload: hexBytes(V.katSrcNonce) + hexBytes(V.katSrcCert)))
        }
        await #expect {
            _ = try await client.connect(host: host, port: port)
        } throws: { error in
            (error as? DTCPError)?.category == .parse
        }
        try await source.value
    }

    @Test func aSourceThatHangsUpMidHandshakeIsAnUnreachableErrorNamingTheStage() async throws {
        let (clientConnection, sourceConnection) = await FakeAKEConnection.makePair()
        let client = try makeClient(connection: clientConnection, srmStore: DTCPMemorySRMStore(authorityKeys: testAuthority))
        let source = Task {
            let reader = AKEFrameReader(connection: sourceConnection, diagnostics: .none)
            _ = try await reader.next()
            // 受け付けずに切る
            await clientConnection.close()
        }
        await #expect {
            _ = try await client.connect(host: host, port: port)
        } throws: { error in
            guard let error = error as? DTCPError else { return false }
            return error.category == .unreachable && error.detail.contains("stage: challenge")
        }
        try await source.value
    }
}

@Suite struct DTCPDiagnosticsAuditTests {
    /// 実行時の監査：既知答のフローを診断ログ付きで流し、鍵の値が 16 進でも base64 でも出ないことを確かめる
    @Test func diagnosticsRecordStagesButNeverKeyMaterial() async throws {
        let log = LogCapture()
        let (clientConnection, sourceConnection) = await FakeAKEConnection.makePair()
        let client = try makeClient(connection: clientConnection, srmStore: DTCPMemorySRMStore(authorityKeys: testAuthority),
                                    diagnostics: log.diagnostics)
        let source = Task { try await runFakeSource(sourceConnection) }
        let session = try await client.connect(host: "192.0.2.1", port: 58293)
        _ = try await session.waitExchangeKey(0x2A, timeout: testWait)
        try await source.value
        await session.close()

        // 段の遷移とフレームのヘッダは記録される
        #expect(log.lines.contains { $0.contains("stage: challenge accepted") })
        #expect(log.lines.contains { $0.contains("stage: response accepted") })
        #expect(log.lines.contains { $0.contains("exchange key received, label 42") })
        #expect(log.lines.contains { $0.contains("rx cmd=0x01") })
        // 鍵の値は記録されない：認証鍵・交換鍵・秘密鍵・両方のノンス・共有の秘密・署名
        let secrets = [V.katAuthKey, V.katPcpExchangeKey, V.katSinkPriv, V.katSinkNonce, V.katSrcNonce,
                       V.katSharedSecret, V.katResponseSig]
        let encoded = secrets + secrets.map { Data(hexBytes($0)).base64EncodedString() } + secrets.map { $0.uppercased() }
        for line in log.lines {
            for secret in encoded {
                #expect(!line.contains(secret), "log line must not contain key material: \(line)")
            }
        }
    }

    /// 静的な監査：DTCPKit の文字列の補間（ログ・誤りの文面）に、鍵・ノンス・署名・資格情報の変数を入れていない
    @Test func noSecretIdentifierIsInterpolatedIntoAnyString() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent("Sources/DTCPKit")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        let forbidden: Set<String> = [
            "key", "keys", "exchangeKey", "exchangeKeys", "authenticationKey", "privateKey", "privateScalar", "masked",
            "shared", "nonce", "myNonce", "sourceNonce", "signature", "sourceSignature", "signedData", "ephemeral",
            "contentKey", "derived", "plain", "cipher", "rttBase", "testResponse", "verifyResponse", "expectedTest",
            "receivedTest", "certificate", "sourceCertificate", "peerCertificate", "credentials", "responseData",
            "bx", "digest", "material", "block", "tail", "iv", "payload", "bytes", "data", "buffer", "pending",
        ]
        let interpolation = try Regex(#"\\\(([^)]*)"#)
        let identifier = try Regex(#"[A-Za-z_][A-Za-z0-9_]*"#)
        var findings = [String]()
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (number, line) in lines.enumerated() {
                for match in line.matches(of: interpolation) {
                    let expression = String(match.output[1].substring ?? "")
                    // 「payload.count」のような長さはよい
                    let names = expression.matches(of: identifier).map { String(expression[$0.range]) }
                    for (index, name) in names.enumerated() where forbidden.contains(name) {
                        let next = index + 1 < names.count ? names[index + 1] : ""
                        if next != "count" { findings.append("\(file.lastPathComponent):\(number + 1): \(expression)") }
                    }
                }
            }
        }
        #expect(findings.isEmpty, "secret-looking interpolation: \(findings)")
    }
}

/// 鍵の引き当ての試験用のセッション
private final class FakeKeySession: AKEKeySession {
    let keys: [UInt8: [UInt8]]
    let ended: Bool
    private let closedFlag = Mutex(false)
    var closed: Bool { closedFlag.withLock { $0 } }

    init(keys: [UInt8: [UInt8]], ended: Bool = false) {
        self.keys = keys
        self.ended = ended
    }

    func key(for label: UInt8) async -> [UInt8]? { keys[label] }

    func waitExchangeKey(_ label: UInt8, timeout: Duration?) async throws -> [UInt8] {
        if let key = keys[label] { return key }
        if ended { throw AKEConnectionClosed() }
        // 試験ではこの道を通らない
        try await Task.sleep(for: .seconds(3600))
        throw AKEConnectionClosed()
    }

    func waitFirstExchangeKey(timeout: Duration) async throws -> UInt8 { keys.keys.sorted().first ?? 0 }

    func close() async { closedFlag.withLock { $0 = true } }
}

@Suite struct DTCPKeySourceTests {
    private let key115 = [UInt8](repeating: 0x11, count: 12)
    private let key116 = [UInt8](repeating: 0x22, count: 12)

    @Test func aRotatedLabelIsFetchedByReauthenticating() async throws {
        let first = FakeKeySession(keys: [115: key115], ended: true)
        let second = FakeKeySession(keys: [116: key116])
        let reauthentications = Mutex(0)
        let source = DTCPKeySource(session: first, diagnostics: .none) {
            reauthentications.withLock { $0 += 1 }
            return second
        }
        // いまの鍵は認証し直さずに渡す
        #expect(try await source.key(for: 115) == key115)
        #expect(reauthentications.withLock { $0 } == 0)
        // 交代したラベルは終わったセッションに無いので、認証し直す
        #expect(try await source.key(for: 116) == key116)
        #expect(reauthentications.withLock { $0 } == 1)
        #expect(await source.currentSession as? FakeKeySession === second)
        #expect(first.closed)
    }

    @Test func aLabelMismatchAfterReauthenticationIsAnError() async throws {
        let first = FakeKeySession(keys: [115: key115], ended: true)
        let second = FakeKeySession(keys: [117: key116])
        let source = DTCPKeySource(session: first, diagnostics: .none) { second }
        await #expect(throws: DTCPError.self) { try await source.key(for: 116) }
    }
}

@Suite struct AKESocketTests {
    /// ループバックで待ち受けて、TTL 3 が付いていること・送受信・相手が閉じたときの nil を確かめる
    @Test func loopbackConnectionCarriesTTLThreeAndBytes() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        #expect(listener >= 0)
        defer { Darwin.close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
        }
        #expect(bound == 0)
        #expect(listen(listener, 1) == 0)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        let port = UInt16(bigEndian: address.sin_port)

        // 受け側：1 回読んで同じものを返し、閉じる
        let server = Task.detached {
            let peer = accept(listener, nil, nil)
            guard peer >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 64)
            let count = recv(peer, &buffer, buffer.count, 0)
            if count > 0 { _ = Darwin.send(peer, buffer, count, 0) }
            Darwin.close(peer)
        }

        let connection = try await AKESocketConnection.connect(host: "127.0.0.1", port: port)
        #expect(connection.timeToLive == AKESocket.timeToLive)
        try await connection.send([1, 2, 3, 4])
        var received = [UInt8]()
        while received.count < 4, let chunk = try await connection.receive() { received += chunk }
        #expect(received == [1, 2, 3, 4])
        // 相手が閉じたら nil
        #expect(try await connection.receive() == nil)
        await connection.close()
        #expect(connection.timeToLive == nil)
        await server.value
    }
}
