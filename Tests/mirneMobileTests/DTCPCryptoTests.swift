// DTCP-IP の暗号の既知答テスト・資格情報の検証・SRM・PCP。
//
// torne mobile HB（MIT、© mar1mo-41414）の test/dtcp_test.dart の該当部分を Swift Testing へ移したもの。
// ベクタは DTCPTestVectors（pydtcpip で試験用の鍵から作った架空の値）。

import Foundation
import Testing

private typealias V = DTCPTestVectors

/// 16 進の文字列からバイト列（試験用。読めなければ止める）
func hexBytes(_ text: String) -> [UInt8] {
    guard let bytes = DTCPBytes.fromHex(text) else { fatalError("hex が読めない") }
    return bytes
}

/// 試験用の権威の鍵（DTLA の鍵ではない）
let testAuthority = [hexBytes(V.katAuthPub)]

@Suite struct DTCPBigUIntTests {
    @Test func bytesRoundTrip() {
        let value = DTCPBigUInt(hex: "0102030405060708090a0b0c0d0e0f1011121314")!
        #expect(value.bytes(length: 20).map(DTCPBytes.hex) == "0102030405060708090a0b0c0d0e0f1011121314")
        #expect(value.bytes(length: 19) == nil)
        #expect(value.bitLength == 153)
    }

    @Test func divisionMatchesMultiplication() {
        // 被除数 = 商 × 除数 + 余り（Knuth の割り算の足し戻しの経路も通る組を含む）
        let cases: [(String, String)] = [
            ("94A8E16AAD4F50EFE29B9D5C0C0B6D481B27DE53", "02278C8AD247A46B5C53DE4CC9A0072488F028A3"),
            ("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "94A8E16AAD4F50EFE29B9D5C0C0B6D481B27DE53"),
            ("80000000000000000000000000000000000000000000000000000001", "800000000000000000000001"),
            ("123456789abcdef0123456789abcdef", "fedcba987"),
            ("7fffffff800000010000000000000000", "800000008000000200000005"),
        ]
        for (dividendHex, divisorHex) in cases {
            let dividend = DTCPBigUInt(hex: dividendHex)!
            let divisor = DTCPBigUInt(hex: divisorHex)!
            let (q, r) = DTCPBigUInt.divMod(dividend, divisor)
            #expect(r < divisor)
            #expect(q * divisor + r == dividend)
        }
    }

    @Test func inverseModuloThePrimes() {
        for modulus in [DTCPCurve.p, DTCPCurve.order] {
            let modular = DTCPModular(modulus: modulus)
            for valueHex in ["1", "2", "3", "deadbeef", "0123456789abcdef0123456789abcdef01234567"] {
                let value = modular.reduce(DTCPBigUInt(hex: valueHex)!)
                let inverse = modular.inverse(value)!
                #expect(modular.multiply(value, inverse) == .one)
            }
            #expect(modular.inverse(.zero) == nil)
        }
    }
}

@Suite struct DTCPCurveTests {
    @Test func generatorMultiplesMatchTheReference() {
        let authorityPublic = DTCPCurve.generator.multiplied(by: DTCPBigUInt(bytes: hexBytes(V.katAuthPriv)))!
        #expect(DTCPBytes.hex(authorityPublic.bytes) == V.katAuthPub)
        let ephemeralA = DTCPCurve.generator.multiplied(by: DTCPBigUInt(bytes: hexBytes(V.katEphA)))!
        #expect(DTCPBytes.hex(ephemeralA.bytes) == V.katEphAPub)
        #expect(DTCPCurve.generator.isOnCurve)
    }

    @Test func certificateVerificationWithTheTestAuthority() throws {
        let certificate = hexBytes(V.katSinkCert)
        let publicKey = try DTCPCertificate.verify(certificate, authorityKeys: testAuthority)
        #expect(DTCPBytes.hex(publicKey.bytes) == String(V.katSinkCert.dropFirst(16).prefix(80)))
        #expect(DTCPCertificate.deviceID(of: certificate) == V.katSinkId)
        // 本物の DTLA の鍵では、試験用の証明書は通らない
        #expect(throws: DTCPError.self) { try DTCPCertificate.verify(certificate) }
    }

    @Test func deterministicSignaturesMatchTheReferenceByteForByte() throws {
        let data = hexBytes(V.katSrcNonce) + hexBytes(V.katResponseData)
        let signature = DTCPSignature.signDeterministic(privateKey: DTCPBigUInt(bytes: hexBytes(V.katSinkPriv)), data: data)
        #expect(DTCPBytes.hex(signature) == V.katResponseSig)
        let publicKey = try DTCPCertificate.verify(hexBytes(V.katSinkCert), authorityKeys: testAuthority)
        #expect(DTCPSignature.verify(publicKey: publicKey, data: data, signature: signature))
        // 1 ビット変えたら通らない
        var tampered = signature
        tampered[39] ^= 0x01
        #expect(!DTCPSignature.verify(publicKey: publicKey, data: data, signature: tampered))

        // 相手側（ソース）の署名も参照実装と一致する
        let sourceData = hexBytes(V.katSinkNonce) + hexBytes(V.katSrcResponseData)
        let sourceSignature = DTCPSignature.signDeterministic(privateKey: DTCPBigUInt(bytes: hexBytes(V.katSrcPriv)),
                                                              data: sourceData)
        #expect(DTCPBytes.hex(sourceSignature) == V.katSrcResponseSig)
    }

    @Test func ecdhSharedSecretAndAuthenticationKey() throws {
        let peer = DTCPPoint(bytes: hexBytes(V.katEphBPub))!
        let shared = try DTCPSignature.sharedSecret(privateKey: DTCPBigUInt(bytes: hexBytes(V.katEphA)), peerPublicKey: peer)
        #expect(DTCPBytes.hex(shared) == V.katSharedSecret)
        #expect(DTCPBytes.hex(shared.suffix(12)) == V.katAuthKey)
    }

    @Test func pointsOffTheCurveAreRejected() {
        var bytes = hexBytes(V.katEphBPub)
        bytes[39] ^= 0x01
        #expect(DTCPPoint(bytes: bytes) == nil)
        #expect(DTCPPoint(bytes: [UInt8](repeating: 0, count: 39)) == nil)
    }

    /// 署名・検証の所要時間を記録する（Debug ビルド。合否の基準ではなく目安）
    @Test func signAndVerifyTiming() throws {
        let data = hexBytes(V.katSrcNonce) + hexBytes(V.katResponseData)
        let publicKey = try DTCPCertificate.verify(hexBytes(V.katSinkCert), authorityKeys: testAuthority)
        let clock = ContinuousClock()
        var signature = [UInt8]()
        let signTime = clock.measure {
            signature = DTCPSignature.signDeterministic(privateKey: DTCPBigUInt(bytes: hexBytes(V.katSinkPriv)), data: data)
        }
        var verified = false
        let verifyTime = clock.measure {
            verified = DTCPSignature.verify(publicKey: publicKey, data: data, signature: signature)
        }
        #expect(verified)
        print("DTCP timing: sign \(signTime), verify \(verifyTime)")
        // AKE は数回の署名・検証で済む。1 回 2 秒を超えたら演算の作りを疑う
        #expect(signTime < .seconds(2))
        #expect(verifyTime < .seconds(2))
    }
}

@Suite struct DTCPContentKeyTests {
    @Test(arguments: [UInt8(0x2), 0x4, 0x6, 0x8, 0xA, 0xC])
    func matchesTheReferencePublishedValues(mode: UInt8) throws {
        let derived = try DTCPContentKey.derive(exchangeKey: (0..<12).map { UInt8($0) }, encryptionMode: mode,
                                                nonce: (0..<8).map { UInt8(0x80 + $0) })
        #expect(DTCPBytes.hex(derived.key + derived.iv) == V.contentKeys[mode])
    }

    @Test func rejectsUnknownModesAndLengths() {
        #expect(throws: DTCPError.self) {
            try DTCPContentKey.derive(exchangeKey: [UInt8](repeating: 0, count: 12), encryptionMode: 0x3,
                                      nonce: [UInt8](repeating: 0, count: 8))
        }
        #expect(throws: DTCPError.self) {
            try DTCPContentKey.derive(exchangeKey: [UInt8](repeating: 0, count: 11), encryptionMode: 0x4,
                                      nonce: [UInt8](repeating: 0, count: 8))
        }
    }
}

@Suite struct DTCPCredentialTests {
    private let certificate = hexBytes(V.katSinkCert)
    private let privateKey = hexBytes(V.katSinkPriv)

    @Test func aGenuinePairPasses() throws {
        let credentials = try DTCPCredentials(certificate: certificate, privateKey: privateKey, authorityKeys: testAuthority)
        #expect(credentials.deviceID == V.katSinkId)
        #expect(credentials.maximumSRMGeneration == 1)
        // 値は description に出ない
        #expect(!"\(credentials)".contains(V.katSinkPriv))
        #expect(credentials.summary.deviceIDHex == String(format: "%010llX", V.katSinkId))
    }

    @Test func wrongLengthsAreRejected() {
        #expect(throws: DTCPError.self) {
            try DTCPCredentials(certificate: certificate.prefix(87), privateKey: privateKey, authorityKeys: testAuthority)
        }
        #expect(throws: DTCPError.self) {
            try DTCPCredentials(certificate: certificate, privateKey: privateKey.prefix(19), authorityKeys: testAuthority)
        }
    }

    @Test func outOfRangePrivateKeysAreRejected() {
        #expect(throws: DTCPError.self) {
            try DTCPCredentials(certificate: certificate, privateKey: [UInt8](repeating: 0, count: 20),
                                authorityKeys: testAuthority)
        }
        #expect(throws: DTCPError.self) {
            try DTCPCredentials(certificate: certificate, privateKey: DTCPCurve.order.bytes(length: 20)!,
                                authorityKeys: testAuthority)
        }
    }

    @Test func aMismatchedPairIsRejected() {
        #expect(throws: DTCPError.self) {
            try DTCPCredentials(certificate: certificate, privateKey: hexBytes(V.katSrcPriv), authorityKeys: testAuthority)
        }
    }

    @Test func aTamperedCertificateIsRejected() {
        var tampered = certificate
        tampered[20] ^= 0x01
        #expect(throws: DTCPError.self) {
            try DTCPCredentials(certificate: tampered, privateKey: privateKey, authorityKeys: testAuthority)
        }
    }

    @Test func memoryStoreRoundTrip() throws {
        let store: any DTCPCredentialStore = DTCPMemoryCredentialStore(authorityKeys: testAuthority)
        #expect(try store.hasCredentials == false)
        #expect(try store.load() == nil)
        try store.save(certificate: certificate, privateKey: privateKey)
        #expect(try store.hasCredentials)
        #expect(try store.load()?.deviceID == V.katSinkId)
        try store.delete()
        #expect(try store.hasCredentials == false)
    }

    @Test func anInvalidPairIsNotStored() throws {
        let store: any DTCPCredentialStore = DTCPMemoryCredentialStore(authorityKeys: testAuthority)
        #expect(throws: DTCPError.self) {
            try store.save(certificate: certificate, privateKey: hexBytes(V.katSrcPriv))
        }
        #expect(try store.hasCredentials == false)
    }
}

@Suite struct DTCPSRMTests {
    @Test func parseAndRevocationChecks() throws {
        let srm = try DTCPSRM.parse(hexBytes(V.katSrmData), authorityKeys: testAuthority)
        #expect(srm.version == 9)
        #expect(srm.generation == 1)
        #expect(srm.isRevoked(V.katSrcId))
        #expect(srm.isRevoked(0x11_2233_4455))
        #expect(srm.isRevoked(0x20_0000_0080))
        #expect(!srm.isRevoked(V.katSinkId))
        #expect(!srm.isRevoked(0x20_0000_0100))
    }

    @Test func aTamperedSRMIsRejected() {
        var tampered = hexBytes(V.katSrmData)
        tampered[10] ^= 0x01
        #expect(throws: DTCPError.self) { try DTCPSRM.parse(tampered, authorityKeys: testAuthority) }
    }

    @Test func newerComparison() throws {
        let current = try DTCPSRM.parse(hexBytes(V.katSrmData), authorityKeys: testAuthority)
        let update = try DTCPSRM.parse(hexBytes(V.katSrmUpdateData), authorityKeys: testAuthority)
        #expect(update.version == 10)
        #expect(update.isNewer(than: current))
        #expect(!current.isNewer(than: update))
    }
}

@Suite struct PCPReferenceTests {
    @Test func theReferencePacketDecryptsToTheReferenceContent() async throws {
        let decryptor = PCPDecryptor { label in
            #expect(label == 0x2A)
            return hexBytes(V.katPcpExchangeKey)
        }
        let wire = hexBytes(V.katPcpWire)
        // 不揃いな塊で与えて、持ち越しを通す
        var output = Data()
        for range in [0..<5, 5..<100, 100..<wire.count] {
            for piece in try await decryptor.add(Data(wire[range])) { output.append(piece) }
        }
        #expect(DTCPBytes.hex(output) == V.katPcpContent)
        #expect(await decryptor.packetsDecrypted == 1)
    }

    @Test func headerParsing() throws {
        let header = try PCPHeader.parse(hexBytes(V.katPcpWire).prefix(PCPHeader.size))
        #expect(header.exchangeKeyLabel == 0x2A)
        #expect(header.encryptionMode == 0x2)
        // 種類のビットが 0 でないものは扱わない
        var bad = hexBytes(V.katPcpWire).prefix(PCPHeader.size).map { $0 }
        bad[0] |= 0x40
        #expect(throws: DTCPError.self) { try PCPHeader.parse(bad) }
    }
}
