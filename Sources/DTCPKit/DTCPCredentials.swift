// DTCP-IP の機器証明書の検証と、資格情報ペアの検証ゲート。
//
// 出典: torne mobile HB（MIT、© mar1mo-41414）の lib/core/dtcp/dtcp_crypto.dart。
// その元は pydtcpip（MIT、© tsukumijima）の dtcp/crypto.py（DTLA の公開鍵・証明書の形・DeviceCredentials の関門）。

import Foundation

/// DTLA の権威の公開鍵（証明書と SRM の署名の検証に使う公開データ）
enum DTCPAuthority {
    /// 本物の DTLA の公開鍵（どちらかで検証できればよい）。pydtcpip の値
    static let dtlaKeys: [[UInt8]] = [
        DTCPBytes.fromHex("6e6e94c45dbedd467e42b789cce95cd19abcc2cc35d26bc0dff1dfeb2857088e052c5d9b2b339ad5")!,
        DTCPBytes.fromHex("23b8461648aa748babae9d9bd905c7ab40ea8efa743f1b3bb1fc17fbb952ad4f84f1f39a886a59b7")!,
    ]

    /// `data` に対する DTLA の署名（40 バイトの r || s）を、権威の鍵のどれかで確かめる。
    /// `authorityKeys` が空なら本物の DTLA の鍵を使う（空でないのは試験だけ）
    static func verify(data: some Collection<UInt8>, signature: some Collection<UInt8>,
                       authorityKeys: [[UInt8]] = []) -> Bool {
        let keys = authorityKeys.isEmpty ? dtlaKeys : authorityKeys
        let data = Array(data)
        let signature = Array(signature)
        for keyBytes in keys {
            guard let key = DTCPPoint(bytes: keyBytes) else { continue }
            if DTCPSignature.verify(publicKey: key, data: data, signature: signature) { return true }
        }
        return false
    }
}

/// 機器証明書（88 バイトの baseline 形式）
enum DTCPCertificate {
    /// 証明書のバイト数
    static let length = 88
    /// 署名される部分（先頭から公開鍵の終わりまで）のバイト数
    static let signedLength = 48
    /// 公開鍵の位置
    static let publicKeyRange = 8..<48
    /// 機器 ID（5 バイト）の位置
    static let deviceIDRange = 3..<8
    /// 証明書の種別（先頭のバイト）。1 = baseline
    static let baselineType: UInt8 = 1
    /// 2 バイト目の上位 4 ビット（SRM の世代の上限）の許す最大値
    static let maximumSRMGenerationNibble: UInt8 = 1

    /// 証明書を確かめ、中の公開鍵を返す
    static func verify(_ certificate: some Collection<UInt8>, authorityKeys: [[UInt8]] = []) throws -> DTCPPoint {
        let certificate = Array(certificate)
        guard certificate.count == length, certificate[0] == baselineType,
              certificate[1] >> 4 <= maximumSRMGenerationNibble else {
            throw DTCPError.validation("dtcp:certificate", "not an 88-byte DTCP baseline certificate")
        }
        guard DTCPAuthority.verify(data: certificate[0..<signedLength], signature: certificate[signedLength...],
                                   authorityKeys: authorityKeys) else {
            throw DTCPError.validation("dtcp:certificate", "DTLA signature verification failed")
        }
        guard let publicKey = DTCPPoint(bytes: certificate[publicKeyRange]) else {
            throw DTCPError.validation("dtcp:certificate", "certificate contains an invalid public key")
        }
        return publicKey
    }

    /// SRM の失効の判定に使う 5 バイトの機器 ID
    static func deviceID(of certificate: some Collection<UInt8>) -> UInt64 {
        DTCPBytes.uint64(Array(certificate)[deviceIDRange])
    }

    /// 2 バイト目の上位 4 ビット（その機器が持てる SRM の世代の上限）
    static func maximumSRMGeneration(of certificate: some Collection<UInt8>) -> UInt8 {
        Array(certificate)[1] >> 4
    }
}

/// 相互認証に使う、機器証明書と機器秘密鍵のペア。
///
/// 作るときに、証明書の DTLA 署名・秘密鍵の長さと範囲・秘密鍵と証明書の公開鍵の一致を確かめる
/// （pydtcpip の DeviceCredentials と同じ関門）。**値は表示もログもしない**：description は伏せた形を返す
struct DTCPCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 秘密鍵のバイト数
    static let privateKeyLength = 20

    let certificate: [UInt8]
    let privateKey: [UInt8]

    init(certificate: some Collection<UInt8>, privateKey: some Collection<UInt8>, authorityKeys: [[UInt8]] = []) throws {
        let certificate = Array(certificate)
        let privateKey = Array(privateKey)
        let verifier = try DTCPCertificate.verify(certificate, authorityKeys: authorityKeys)
        guard privateKey.count == Self.privateKeyLength else {
            throw DTCPError.validation("dtcp:credentials", "the device private key must be 20 bytes")
        }
        let scalar = DTCPBigUInt(bytes: privateKey)
        guard !scalar.isZero, scalar < DTCPCurve.order else {
            throw DTCPError.validation("dtcp:credentials", "the device private key is outside the DTCP key range")
        }
        guard DTCPCurve.generator.multiplied(by: scalar) == verifier else {
            throw DTCPError.validation("dtcp:credentials", "the device private key does not match the certificate")
        }
        self.certificate = certificate
        self.privateKey = privateKey
    }

    var deviceID: UInt64 { DTCPCertificate.deviceID(of: certificate) }

    /// この機器が持てる SRM の世代の上限
    var maximumSRMGeneration: UInt8 { DTCPCertificate.maximumSRMGeneration(of: certificate) }

    var privateScalar: DTCPBigUInt { DTCPBigUInt(bytes: privateKey) }

    /// 画面に出してよい要約（識別子と指紋。鍵の値ではない）
    var summary: DTCPCredentialSummary { DTCPCredentialSummary(certificate: certificate) }

    var description: String { "DTCPCredentials(<redacted>)" }
    var debugDescription: String { description }
}

/// 設定画面に出してよい、資格情報の要約
public struct DTCPCredentialSummary: Sendable, Equatable {
    /// 証明書の機器 ID（5 バイト、16 進・大文字）
    public let deviceIDHex: String
    /// 証明書（公開データ）の SHA-1 の指紋（16 進・大文字）
    public let certificateSHA1Hex: String

    init(certificate: [UInt8]) {
        deviceIDHex = DTCPBytes.hex(certificate[DTCPCertificate.deviceIDRange]).uppercased()
        certificateSHA1Hex = DTCPBytes.hex(DTCPHash.sha1(certificate)).uppercased()
    }
}
