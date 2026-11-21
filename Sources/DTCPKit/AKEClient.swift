// DTCP-IP の AKE（Authentication and Key Exchange）のシンク側。
//
// 出典: torne mobile HB（MIT、© mar1mo-41414）の lib/core/dtcp/ake.dart。
// その元は pydtcpip（MIT、© tsukumijima）の dtcp/ake.py（Full Authentication・RTT・SRM の更新）。
//
// 守ること（torne mobile HB の計画書 §28・§29 の実測）:
// - 要求のフレームは役割 0x01・状態 0x0F。ACCEPTED は受け取ったヘッダの写し（AKEControlFrame）
// - 認証は交換鍵を受け取るまでを含めて 30 秒で打ち切り、止まった段の名前を誤りに残す
// - **nasne は認証の直後に AKE の接続を閉じる。これは正常な終わり方**で、接続の失敗として扱わない。
//   終わったセッションが渡していないラベルの鍵を待つと、すぐに AKEConnectionClosed で返す
//   （呼び出し側が新しい接続で認証し直す。DTCPKeySource）
// - 鍵（認証鍵・交換鍵）はメモリの中だけに置く。ログには段とフレームのヘッダだけを書く
//
// torne mobile HB からの変更: Dart のストリームの購読の代わりに、actor と async の receive で書いた。

import Foundation

/// 確立した AKE のセッションのうち、交換鍵を取り出す面（DTCPKeySource が使う。試験では差し替える）
protocol AKEKeySession: Sendable {
    /// 受け取り済みなら `label` の鍵、まだなら nil（待たない）
    func key(for label: UInt8) async -> [UInt8]?
    /// `label` の鍵を待つ。セッションが鍵を渡さずに終わったら AKEConnectionClosed
    func waitExchangeKey(_ label: UInt8, timeout: Duration?) async throws -> [UInt8]
    /// このセッションの最初の交換鍵を待ち、そのラベルを返す
    func waitFirstExchangeKey(timeout: Duration) async throws -> UInt8
    /// 接続を閉じる
    func close() async
}

/// 確立した AKE のセッション
struct AKESession: AKEKeySession {
    let client: AKEClient
    let connection: any AKEConnection

    func key(for label: UInt8) async -> [UInt8]? { await client.key(for: label) }

    func waitExchangeKey(_ label: UInt8, timeout: Duration?) async throws -> [UInt8] {
        try await client.waitExchangeKey(label, timeout: timeout)
    }

    func waitFirstExchangeKey(timeout: Duration = AKETiming.firstExchangeKey) async throws -> UInt8 {
        try await client.waitFirstExchangeKey(timeout: timeout)
    }

    func close() async { await connection.close() }
}

/// AKE の時間の決まり
enum AKETiming {
    /// 認証全体の上限（参照実装の timeout）
    static let authentication: Duration = .seconds(30)
    /// 認証の後、最初の交換鍵を待つ上限（torne mobile HB の計画書 §28.2）
    static let firstExchangeKey: Duration = .seconds(20)
}

/// AKE のシンク側。1 つのクライアントは 1 つのセッションの鍵の状態を持つ（認証し直すときは新しく作る）
actor AKEClient {
    let credentials: DTCPCredentials
    let srmStore: any DTCPSRMStore
    private let connectionFactory: AKEConnectionFactory
    private let authorityKeys: [[UInt8]]
    private let diagnostics: DTCPDiagnostics
    private let randomBytes: @Sendable (Int) -> [UInt8]
    private let ephemeralScalar: @Sendable () -> DTCPBigUInt

    /// ノンスのバイト数
    private static let nonceLength = 16
    /// ECDH の共有の x 座標のうち、認証鍵に使う下位のバイト数（12 バイト = 96 ビット）
    private static let authenticationKeyLength = 12
    /// 相手の CHALLENGE のペイロード（ノンス 16 + 証明書 88）・RESPONSE（一時公開鍵 40 + SRM 3 + 署名 40）の長さ
    private static let challengePayloadLength = 104
    private static let responsePayloadLength = 83
    /// RESPONSE のうち署名される部分（一時公開鍵 + SRM の版と世代）の長さ
    private static let responseSignedLength = 43
    /// RTT_SETUP のペイロード（カウンタ 2 バイト）・RTT の MAC の長さ
    private static let rttSetupPayloadLength = 2
    private static let rttMACLength = 10
    /// EXCHANGE_KEY のペイロード（ラベル 1 + 予約 1 + 鍵 12）
    private static let exchangeKeyPayloadLength = 14

    private var exchangeKeys: [UInt8: [UInt8]] = [:]
    private(set) var exchangeKeyLabel: UInt8?
    private var keyWaiters: [UInt8: [Int: CheckedContinuation<[UInt8], any Error>]] = [:]
    private var firstKeyWaiters: [Int: CheckedContinuation<UInt8, any Error>] = [:]
    private var firstKeyLabel: UInt8?
    private var nextWaiterID = 0
    /// 認証の後のメッセージの繰り返しが終わったか。終わったら鍵はもう届かない
    private(set) var loopEnded = false
    private var loopError: (any Error)?
    /// いま進めている段（時間切れの誤りに名前を出す）
    private var authenticationStage = "connect"

    /// 相手の証明書と SRM の版・世代（SRM_UPDATE の判定と、SRM を渡すかの判定に使う）
    private var peerCertificate: [UInt8]?
    private var peerSRMVersion: UInt16 = 0
    private var peerSRMGeneration: UInt8 = 0
    private var peerMaximumSRMGeneration: UInt8 = 0

    init(credentials: DTCPCredentials, srmStore: any DTCPSRMStore,
         connectionFactory: @escaping AKEConnectionFactory = AKESocket.factory,
         authorityKeys: [[UInt8]] = [], diagnostics: DTCPDiagnostics = .osLog,
         randomBytes: @escaping @Sendable (Int) -> [UInt8] = DTCPRandom.bytes,
         ephemeralScalar: @escaping @Sendable () -> DTCPBigUInt = DTCPSignature.randomScalar) {
        self.credentials = credentials
        self.srmStore = srmStore
        self.connectionFactory = connectionFactory
        self.authorityKeys = authorityKeys
        self.diagnostics = diagnostics
        self.randomBytes = randomBytes
        self.ephemeralScalar = ephemeralScalar
    }

    // MARK: 鍵の受け渡し

    func key(for label: UInt8) -> [UInt8]? { exchangeKeys[label] }

    func waitExchangeKey(_ label: UInt8, timeout: Duration?) async throws -> [UInt8] {
        if let key = exchangeKeys[label] { return key }
        if loopEnded { throw loopError ?? AKEConnectionClosed() }
        let id = takeWaiterID()
        return try await withCheckedThrowingContinuation { continuation in
            keyWaiters[label, default: [:]][id] = continuation
            if let timeout {
                Task {
                    try? await Task.sleep(for: timeout)
                    self.expireKeyWaiter(label: label, id: id)
                }
            }
        }
    }

    func waitFirstExchangeKey(timeout: Duration) async throws -> UInt8 {
        if let firstKeyLabel { return firstKeyLabel }
        if loopEnded { throw loopError ?? Self.closedBeforeFirstKey }
        let id = takeWaiterID()
        return try await withCheckedThrowingContinuation { continuation in
            firstKeyWaiters[id] = continuation
            Task {
                try? await Task.sleep(for: timeout)
                self.expireFirstKeyWaiter(id: id, timeout: timeout)
            }
        }
    }

    private func takeWaiterID() -> Int {
        nextWaiterID += 1
        return nextWaiterID
    }

    private func expireKeyWaiter(label: UInt8, id: Int) {
        guard let continuation = keyWaiters[label]?.removeValue(forKey: id) else { return }
        continuation.resume(throwing: DTCPError.unreachable("dtcp:ake", "timed out waiting for the exchange key (label \(label))"))
    }

    private func expireFirstKeyWaiter(id: Int, timeout: Duration) {
        guard let continuation = firstKeyWaiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: DTCPError.unreachable(
            "dtcp:ake", "the source sent no exchange key within \(timeout.components.seconds) seconds of authentication"))
    }

    private static let closedBeforeFirstKey = DTCPError.unreachable(
        "dtcp:ake", "the source closed the AKE connection before sending an exchange key")

    private func deliver(key: [UInt8], label: UInt8) {
        exchangeKeys[label] = key
        exchangeKeyLabel = label
        if let waiters = keyWaiters.removeValue(forKey: label) {
            for continuation in waiters.values { continuation.resume(returning: key) }
        }
        if firstKeyLabel == nil {
            firstKeyLabel = label
            let waiters = firstKeyWaiters
            firstKeyWaiters.removeAll()
            for continuation in waiters.values { continuation.resume(returning: label) }
        }
    }

    /// メッセージの繰り返しが終わったら、待っているものをすべて片付ける。きれいな終わり（相手が閉じた。
    /// 再生では正常）なら、届かなかった鍵の待ちは AKEConnectionClosed で返す。最初の鍵より前に終わったら
    /// 開始の失敗なので、分類した誤りにする
    private func endLoop(error: (any Error)?) {
        guard !loopEnded else { return }
        loopEnded = true
        loopError = error
        let waiters = keyWaiters
        keyWaiters.removeAll()
        for continuation in waiters.values.flatMap(\.values) {
            continuation.resume(throwing: error ?? AKEConnectionClosed())
        }
        let firstWaiters = firstKeyWaiters
        firstKeyWaiters.removeAll()
        for continuation in firstWaiters.values {
            continuation.resume(throwing: error ?? Self.closedBeforeFirstKey)
        }
    }

    // MARK: 接続と認証

    /// 認証を行い、セッションを返す。認証の後のメッセージの繰り返し（RTT・EXCHANGE_KEY・SRM_UPDATE）は
    /// 裏で回り続け、相手が閉じるか close するまで続く
    func connect(host: String, port: UInt16) async throws -> AKESession {
        let started = ContinuousClock.now
        diagnostics(.ake, "connecting to the AKE port")
        authenticationStage = "connect"
        let connection = try await connectionFactory(host, port)
        let reader = AKEFrameReader(connection: connection, diagnostics: diagnostics)
        let authenticationKey: [UInt8]
        do {
            // 参照実装は認証全体を時間で区切る。止まったら段の名前を残す
            let result: [UInt8]? = try await withThrowingTaskGroup(of: [UInt8]?.self) { group in
                group.addTask { try await self.authenticate(reader: reader) }
                group.addTask {
                    try await Task.sleep(for: AKETiming.authentication)
                    // 時間切れ：接続を閉じて、止まっている受信を起こす（起こさないと認証の子の
                    // タスクが終わらず、この task group から戻れない）
                    await connection.close()
                    return nil
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
            guard let result else {
                throw DTCPError.unreachable("dtcp:ake", "AKE timed out during stage: \(authenticationStage)")
            }
            authenticationKey = result
        } catch is AKEConnectionClosed {
            await connection.close()
            // 認証の途中で相手が切った：ただの「閉じた」ではなく、段の名前の付いた到達の誤り
            throw DTCPError.unreachable("dtcp:ake", "the source closed the AKE connection during stage: \(authenticationStage)")
        } catch {
            await connection.close()
            throw error
        }
        let elapsed = ContinuousClock.now - started
        diagnostics(.ake, "authenticated in \(elapsed.wholeMilliseconds) ms; post-auth message loop running")
        Task {
            do {
                try await self.messageLoop(reader: reader, authenticationKey: authenticationKey)
                self.endLoop(error: nil)
            } catch is AKEConnectionClosed {
                self.diagnostics(.ake, "ake session ended: the source closed the connection (normal after authentication)")
                self.endLoop(error: nil)
            } catch {
                self.diagnostics(.ake, "message loop ended: \(error)")
                self.endLoop(error: error)
            }
        }
        return AKESession(client: self, connection: connection)
    }

    private func authenticate(reader: AKEFrameReader) async throws -> [UInt8] {
        let srm = srmStore.load()
        let myNonce = randomBytes(Self.nonceLength)

        // CHALLENGE：ノンス || 自分の証明書
        authenticationStage = "challenge"
        try await reader.send(AKEControlFrame(command: AKECommand.challenge, payload: myNonce + credentials.certificate))
        var frame = try await reader.next()
        try expectAccepted(frame, command: AKECommand.challenge)
        diagnostics(.ake, "stage: challenge accepted by source")

        // 相手の CHALLENGE
        authenticationStage = "source challenge"
        frame = try await reader.next()
        guard !frame.isResponse, frame.command == AKECommand.challenge,
              frame.payload.count == Self.challengePayloadLength else {
            throw DTCPError.parse("dtcp:ake", "expected the source CHALLENGE frame")
        }
        let sourceNonce = Array(frame.payload[0..<Self.nonceLength])
        let sourceCertificate = Array(frame.payload[Self.nonceLength...])
        let sourcePublicKey = try DTCPCertificate.verify(sourceCertificate, authorityKeys: authorityKeys)
        peerCertificate = sourceCertificate
        diagnostics(.ake, "stage: source certificate verified")
        if let srm {
            if srm.isRevoked(DTCPCertificate.deviceID(of: sourceCertificate)) {
                throw DTCPError.parse("dtcp:ake", "the source device is revoked by the SRM")
            }
            if srm.isRevoked(credentials.deviceID) {
                throw DTCPError.parse("dtcp:ake", "this device is revoked by the SRM")
            }
        }
        // 相手の CHALLENGE への ACCEPTED（ヘッダは受け取ったものの写し）
        try await reader.send(frame.accepted())

        // 相手の RESPONSE
        authenticationStage = "source response"
        frame = try await reader.next()
        guard !frame.isResponse, frame.command == AKECommand.response,
              frame.payload.count == Self.responsePayloadLength else {
            throw DTCPError.parse("dtcp:ake", "expected the source RESPONSE frame")
        }
        guard let sourceEphemeral = DTCPPoint(bytes: frame.payload[0..<(DTCPCurve.size * 2)]) else {
            throw DTCPError.parse("dtcp:ake", "the source ephemeral key is invalid")
        }
        peerSRMVersion = UInt16(frame.payload[40]) << 8 | UInt16(frame.payload[41])
        peerSRMGeneration = frame.payload[42] & 0x0F
        peerMaximumSRMGeneration = DTCPCertificate.maximumSRMGeneration(of: sourceCertificate)
        guard peerSRMGeneration <= peerMaximumSRMGeneration else {
            throw DTCPError.parse("dtcp:ake", "the source SRM generation exceeds its maximum")
        }
        let sourceSignature = Array(frame.payload[Self.responseSignedLength...])
        let signedData = myNonce + frame.payload[0..<Self.responseSignedLength]
        guard DTCPSignature.verify(publicKey: sourcePublicKey, data: signedData, signature: sourceSignature) else {
            throw DTCPError.parse("dtcp:ake", "the source signature verification failed")
        }
        diagnostics(.ake, "stage: source response signature verified")

        // ECDH：認証鍵は共有点の x 座標の下位 12 バイト
        let ephemeral = ephemeralScalar()
        guard let ephemeralPublic = DTCPCurve.generator.multiplied(by: ephemeral) else {
            throw DTCPError.validation("dtcp:ake", "could not create an ephemeral key")
        }
        let shared = try DTCPSignature.sharedSecret(privateKey: ephemeral, peerPublicKey: sourceEphemeral)
        let authenticationKey = Array(shared.suffix(Self.authenticationKeyLength))

        // 相手の RESPONSE への ACCEPTED（ヘッダは写し）
        try await reader.send(frame.accepted())

        // 自分の RESPONSE：一時公開鍵 || SRM の版と世代 || （相手のノンス || ここまで）への決定的な署名
        authenticationStage = "response"
        let mySRM = srmStore.load()
        let version = mySRM?.version ?? 0
        let responseData = ephemeralPublic.bytes + [UInt8(version >> 8), UInt8(version & 0xFF), mySRM?.generation ?? 0]
        let signature = DTCPSignature.signDeterministic(privateKey: credentials.privateScalar,
                                                        data: sourceNonce + responseData)
        try await reader.send(AKEControlFrame(command: AKECommand.response, payload: responseData + signature))
        authenticationStage = "response acceptance"
        frame = try await reader.next()
        try expectAccepted(frame, command: AKECommand.response)
        diagnostics(.ake, "stage: response accepted by source")
        return authenticationKey
    }

    private func expectAccepted(_ frame: AKEControlFrame, command: UInt8) throws {
        guard frame.isResponse, frame.command == command, frame.status == 0 else {
            throw DTCPError.parse("dtcp:ake", "the source rejected the AKE step (command 0x\(String(command, radix: 16)))")
        }
    }

    // MARK: 認証の後

    private func messageLoop(reader: AKEFrameReader, authenticationKey: [UInt8]) async throws {
        // RTT の MAC は RTT_SETUP の時点で先に計算しておく（相手は往復の時間を測る。参照実装の注記では 7 ms）
        let rttBase = DTCPHash.sha1(authenticationKey + authenticationKey)
        var expectedTest: [UInt8]?
        var testResponse: [UInt8]?
        var verifyResponse: [UInt8]?
        var receivedTest: [UInt8]?

        while true {
            let frame = try await reader.next()
            switch frame.command {
            case AKECommand.rttReady:
                // 相手が自分の RTT_READY を受け付けた：次の要求を待つ（参照実装どおり）
                if frame.isResponse { continue }
                diagnostics(.ake, "rtt: ready round trip")
                try await reader.send(frame.accepted())
                try await reader.send(AKEControlFrame(command: AKECommand.rttReady, payload: []))
            case AKECommand.rttSetup:
                guard !frame.isResponse, frame.payload.count == Self.rttSetupPayloadLength else {
                    throw DTCPError.parse("dtcp:ake", "invalid RTT_SETUP frame")
                }
                let counter = UInt64(frame.payload[0]) << 8 | UInt64(frame.payload[1])
                let digest = DTCPHash.sha1(Self.add(counter, to: rttBase))
                expectedTest = Array(digest[0..<Self.rttMACLength])
                testResponse = Array(digest[Self.rttMACLength...])
                verifyResponse = Array(DTCPHash.sha1(Self.add(counter + 1, to: rttBase)).prefix(Self.rttMACLength))
                diagnostics(.ake, "rtt: setup received, MACs precomputed")
                // 受け付けの応答はカウンタをそのまま返す（受け取ったフレームの ACCEPTED の写し）
                try await reader.send(frame.accepted(payload: frame.payload))
            case AKECommand.rttTest:
                guard !frame.isResponse, expectedTest != nil, let testResponse,
                      frame.payload.count == Self.rttMACLength else {
                    throw DTCPError.parse("dtcp:ake", "invalid RTT_TEST frame")
                }
                receivedTest = frame.payload
                diagnostics(.ake, "rtt: test received")
                try await reader.send(frame.accepted(payload: testResponse))
            case AKECommand.rttVerify:
                guard !frame.isResponse, let expectedTest, let receivedTest, receivedTest == expectedTest,
                      let verifyResponse else {
                    throw DTCPError.parse("dtcp:ake", "RTT verification failed")
                }
                diagnostics(.ake, "rtt: verified")
                try await reader.send(frame.accepted(payload: verifyResponse))
            case AKECommand.exchangeKey:
                guard !frame.isResponse, frame.payload.count == Self.exchangeKeyPayloadLength else {
                    throw DTCPError.parse("dtcp:ake", "invalid EXCHANGE_KEY frame")
                }
                let label = frame.payload[0]
                let masked = frame.payload[2...]
                let key = zip(masked, authenticationKey).map { $0 ^ $1 }
                deliver(key: key, label: label)
                diagnostics(.ake, "exchange key received, label \(label)")
                try await reader.send(frame.accepted())
                try await forwardSRMIfNewer(reader: reader)
            case AKECommand.srmUpdate:
                guard !frame.isResponse else {
                    throw DTCPError.parse("dtcp:ake", "unexpected SRM_UPDATE response frame")
                }
                try await handleSRMUpdate(reader: reader, frame: frame)
            default:
                throw DTCPError.parse("dtcp:ake", "unsupported AKE command 0x\(String(frame.command, radix: 16))")
            }
        }
    }

    /// 20 バイトのビッグエンディアンの数に `value` を足す（2^160 で折り返す。RTT の MAC の素）
    private static func add(_ value: UInt64, to base: [UInt8]) -> [UInt8] {
        var out = base
        var carry = value
        var index = out.count - 1
        while carry > 0 && index >= 0 {
            let sum = UInt64(out[index]) + (carry & 0xFF)
            out[index] = UInt8(truncatingIfNeeded: sum)
            carry = (carry >> 8) + (sum >> 8)
            index -= 1
        }
        return out
    }

    private func handleSRMUpdate(reader: AKEFrameReader, frame: AKEControlFrame) async throws {
        let newSRM = try DTCPSRM.parse(frame.payload, authorityKeys: authorityKeys)
        diagnostics(.ake, "srm update received (version \(newSRM.version), generation \(newSRM.generation))")
        let current = srmStore.load()
        let effective: DTCPSRM
        if let current, !newSRM.isNewer(than: current) {
            effective = current
        } else {
            // 新しい SRM は、どちらかを失効させるものでも保存する（参照実装どおり）。その後の判定で効く
            srmStore.save(raw: frame.payload, srm: newSRM)
            effective = newSRM
        }
        if let peerCertificate, effective.isRevoked(DTCPCertificate.deviceID(of: peerCertificate)) {
            throw DTCPError.parse("dtcp:ake", "the source device is revoked by the SRM")
        }
        if effective.isRevoked(credentials.deviceID) {
            throw DTCPError.parse("dtcp:ake", "this device is revoked by the SRM")
        }
        try await reader.send(frame.accepted())
    }

    /// EXCHANGE_KEY の後、手元の SRM の方が新しければ相手へ渡す（参照実装どおり）。
    /// このフレームの鍵の種類は 0（相手は種類を指定すると拒む）
    private func forwardSRMIfNewer(reader: AKEFrameReader) async throws {
        guard let localSRM = srmStore.load(), peerCertificate != nil else { return }
        let isLocalNewer = localSRM.version > peerSRMVersion
            || (localSRM.version == peerSRMVersion && peerSRMGeneration < peerMaximumSRMGeneration
                && localSRM.generation > peerSRMGeneration)
        guard isLocalNewer else { return }
        diagnostics(.ake, "forwarding newer local SRM (version \(localSRM.version), generation \(localSRM.generation))")
        // 世代 0 までしか持てない相手には、署名付きのヘッダを保って最初の世代だけを送る
        let sendData = localSRM.generation > peerMaximumSRMGeneration ? localSRM.firstGenerationOnly : localSRM.data
        try await reader.send(AKEControlFrame(command: AKECommand.srmUpdate, payload: sendData, keyType: 0))
        let accepted = try await reader.next()
        guard accepted.isResponse, accepted.command == AKECommand.srmUpdate, accepted.status == 0 else {
            throw DTCPError.parse("dtcp:ake", "the source did not accept the SRM update")
        }
    }
}

/// 接続のバイトの流れを制御フレームに区切る。読み手は 1 つだけ（認証の後はメッセージの繰り返し）
actor AKEFrameReader {
    private let connection: any AKEConnection
    private let diagnostics: DTCPDiagnostics
    private var buffer: [UInt8] = []
    private var failureLogged = false

    init(connection: any AKEConnection, diagnostics: DTCPDiagnostics) {
        self.connection = connection
        self.diagnostics = diagnostics
    }

    private static func hexByte(_ value: UInt8) -> String {
        "0x" + (value < 0x10 ? "0" : "") + String(value, radix: 16)
    }

    /// 次のフレーム。相手が閉じたら AKEConnectionClosed（誤りかどうかは呼び出し側が段で決める）
    func next() async throws -> AKEControlFrame {
        while true {
            if let (frame, consumed) = try AKEControlFrame.parse(buffer) {
                // ログに出すのはコマンド・種別・状態・ペイロードの長さだけ（中身は出さない）
                let frameType = buffer[3]
                diagnostics(.ake, "rx cmd=\(Self.hexByte(frame.command)) ctype=\(Self.hexByte(frameType)) "
                    + "status=\(frame.status) payload=\(frame.payload.count)B")
                buffer.removeFirst(consumed)
                return frame
            }
            let chunk: [UInt8]?
            do {
                chunk = try await connection.receive()
            } catch {
                if !failureLogged {
                    failureLogged = true
                    diagnostics(.ake, "ake connection failed: \(error)")
                }
                throw error
            }
            guard let chunk else {
                diagnostics(.ake, "ake connection closed by the source")
                throw AKEConnectionClosed()
            }
            buffer += chunk
        }
    }

    func send(_ frame: AKEControlFrame) async throws {
        diagnostics(.ake, "tx cmd=\(Self.hexByte(frame.command)) ctype=\(frame.isResponse ? "accepted" : "control") "
            + "payload=\(frame.payload.count)B")
        try await connection.send(frame.encode())
    }
}
