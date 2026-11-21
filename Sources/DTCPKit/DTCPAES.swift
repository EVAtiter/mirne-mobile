// AES-128（CommonCrypto）と、DTCP-IP のコンテンツ鍵の導出。
//
// 出典: torne mobile HB（MIT、© mar1mo-41414）の lib/core/dtcp/dtcp_crypto.dart。
// コンテンツ鍵の導出と E-EMI ごとの定数は pydtcpip（MIT、© tsukumijima）の derive_content_key の移植。
//
// torne mobile HB からの変更: CBC の連鎖を自前で回さず、CommonCrypto の CCCryptor に持たせる
// （CCCryptorUpdate は呼び出しをまたいで CBC の状態を持ち越す）。torne mobile HB で起きた
// 「1 ブロックごとに入力全体を複製して O(n²) になる」型の誤りは、この形では起きない。

import CommonCrypto
import Foundation

enum DTCPAES {
    /// AES-128 の鍵・ブロックのバイト数
    static let blockSize = kCCBlockSizeAES128
    static let keySize = kCCKeySizeAES128

    /// 1 ブロックを暗号化する（ECB の基本操作）
    static func encryptBlock(key: [UInt8], block: [UInt8]) throws -> [UInt8] {
        try crypt(operation: CCOperation(kCCEncrypt), options: CCOptions(kCCOptionECBMode), key: key, iv: nil, data: block)
    }

    /// AES-128-CBC で暗号化する（詰め物なし。長さは 16 の倍数）。試験で PCP のパケットを作るのに使う
    static func cbcEncrypt(key: [UInt8], iv: [UInt8], data: [UInt8]) throws -> [UInt8] {
        try crypt(operation: CCOperation(kCCEncrypt), options: 0, key: key, iv: iv, data: data)
    }

    /// AES-128-CBC で復号する（詰め物なし。長さは 16 の倍数）
    static func cbcDecrypt(key: [UInt8], iv: [UInt8], data: [UInt8]) throws -> [UInt8] {
        let decryptor = try AESCBCDecryptor(key: key, iv: iv)
        return try decryptor.decrypt(data[...])
    }

    private static func crypt(operation: CCOperation, options: CCOptions, key: [UInt8], iv: [UInt8]?,
                              data: [UInt8]) throws -> [UInt8] {
        guard key.count == keySize, data.count.isMultiple(of: blockSize), iv == nil || iv?.count == blockSize else {
            throw DTCPError.validation("dtcp:aes", "invalid AES key, IV or data length")
        }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), options,
                             key, key.count, iv, data, data.count, &out, out.count, &moved)
        guard status == kCCSuccess, moved == data.count else {
            throw DTCPError.validation("dtcp:aes", "CommonCrypto failed (\(status))")
        }
        return out
    }
}

/// 逐次の AES-128-CBC 復号器（torne mobile HB の計画書 §30）。
///
/// CBC の復号に要るのは直前の暗号文のブロックだけなので、PCP のパケット（実機では 1 MiB）を
/// 全部待たずに、届いたブロックから順に復号できる。連鎖の状態は CCCryptor が持つ
final class AESCBCDecryptor {
    private var cryptor: CCCryptorRef?

    init(key: [UInt8], iv: [UInt8]) throws {
        guard key.count == DTCPAES.keySize, iv.count == DTCPAES.blockSize else {
            throw DTCPError.validation("dtcp:aes", "invalid AES key or IV length")
        }
        var reference: CCCryptorRef?
        let status = CCCryptorCreate(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                     key, key.count, iv, &reference)
        guard status == kCCSuccess, let reference else {
            throw DTCPError.validation("dtcp:aes", "CommonCrypto failed (\(status))")
        }
        cryptor = reference
    }

    deinit {
        if let cryptor { CCCryptorRelease(cryptor) }
    }

    /// 16 の倍数のバイト数を復号する。連鎖は次の呼び出しへ持ち越す
    func decrypt(_ cipher: ArraySlice<UInt8>) throws -> [UInt8] {
        guard cipher.count.isMultiple(of: DTCPAES.blockSize) else {
            throw DTCPError.validation("dtcp:aes", "CBC input is not a multiple of the block size")
        }
        guard !cipher.isEmpty else { return [] }
        var out = [UInt8](repeating: 0, count: cipher.count)
        var moved = 0
        let status = cipher.withUnsafeBytes { input in
            out.withUnsafeMutableBytes { output in
                CCCryptorUpdate(cryptor, input.baseAddress, input.count, output.baseAddress, output.count, &moved)
            }
        }
        guard status == kCCSuccess, moved == cipher.count else {
            throw DTCPError.validation("dtcp:aes", "CommonCrypto failed (\(status))")
        }
        return out
    }

    /// Data の範囲を復号する（PCP の受信バッファからコピーせずに読む）
    func decrypt(_ data: Data, range: Range<Data.Index>) throws -> Data {
        guard range.count.isMultiple(of: DTCPAES.blockSize) else {
            throw DTCPError.validation("dtcp:aes", "CBC input is not a multiple of the block size")
        }
        guard !range.isEmpty else { return Data() }
        var out = Data(count: range.count)
        var moved = 0
        let status = data[range].withUnsafeBytes { input in
            out.withUnsafeMutableBytes { output in
                CCCryptorUpdate(cryptor, input.baseAddress, input.count, output.baseAddress, output.count, &moved)
            }
        }
        guard status == kCCSuccess, moved == range.count else {
            throw DTCPError.validation("dtcp:aes", "CommonCrypto failed (\(status))")
        }
        return out
    }
}

/// コンテンツ鍵と CBC の IV
struct DTCPContentKey: Sendable {
    let key: [UInt8]
    let iv: [UInt8]

    /// 交換鍵の長さ
    static let exchangeKeyLength = 12
    /// PCP の nonce の長さ
    static let nonceLength = 8

    /// E-EMI ごとに交換鍵の後ろへ付ける定数（pydtcpip の値）
    private static let constants: [UInt8: String] = [
        0x2: "de665adec0156112cf2628eb",
        0x4: "45b146a0611a501ac32bfad4",
        0x6: "e6ed3e3078ff0e5b3a273ccb",
        0x8: "7c0d87c76c195662f98c14e6",
        0xA: "28b522c7cdb22d490ef8e3d4",
        0xC: "a3806f971635c1796deaed24",
    ]

    /// IV の導出に使う定数（pydtcpip の値）
    private static let ivConstant = DTCPBytes.fromHex("95dc3a449028eb3c")!

    /// 交換鍵（12 バイト）・PCP の E-EMI・PCP の nonce（8 バイト）から AES のコンテンツ鍵と IV を導く
    static func derive(exchangeKey: [UInt8], encryptionMode: UInt8, nonce: [UInt8]) throws -> DTCPContentKey {
        guard exchangeKey.count == exchangeKeyLength, nonce.count == nonceLength else {
            throw DTCPError.validation("dtcp:contentKey", "the exchange key must be 12 bytes and the nonce 8 bytes")
        }
        guard let constantHex = constants[encryptionMode], let constant = DTCPBytes.fromHex(constantHex) else {
            throw DTCPError.validation("dtcp:contentKey",
                                       "unsupported content encryption mode (E-EMI 0x\(String(encryptionMode, radix: 16)))")
        }
        let material = exchangeKey + constant + nonce
        let tail = Array(material[DTCPAES.keySize...])
        let block = try DTCPAES.encryptBlock(key: Array(material[0..<DTCPAES.keySize]), block: tail)
        let contentKey = zip(block, tail).map { $0 ^ $1 }
        let iv = try DTCPAES.encryptBlock(key: contentKey, block: ivConstant + nonce)
        return DTCPContentKey(key: contentKey, iv: iv)
    }
}
