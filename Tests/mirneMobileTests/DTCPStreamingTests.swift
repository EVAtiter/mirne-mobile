// 実機の大きさ（1 MiB の PCP パケット）での AES・PCP の試験。
//
// torne mobile HB（MIT、© mar1mo-41414）の test/dtcp_streaming_test.dart の該当部分を移したもの。
// torne mobile HB のビルド 7 は最初の 1 MiB の復号で固まった（AES-CBC の O(n²) の複製）。その再発を止める。

import Foundation
import Testing

private typealias V = DTCPTestVectors

/// 送り手と同じ形の PCP のパケット：14 バイトのヘッダ + 16 バイトの倍数に詰めた AES-128-CBC の暗号文
func buildPCPPacket(exchangeKey: [UInt8], label: UInt8, encryptionMode: UInt8, nonce: [UInt8],
                    plaintext: [UInt8]) throws -> [UInt8] {
    let derived = try DTCPContentKey.derive(exchangeKey: exchangeKey, encryptionMode: encryptionMode, nonce: nonce)
    let paddedLength = (plaintext.count + 15) / 16 * 16
    let padded = plaintext + [UInt8](repeating: 0, count: paddedLength - plaintext.count)
    let cipher = try DTCPAES.cbcEncrypt(key: derived.key, iv: derived.iv, data: padded)
    let length = UInt32(plaintext.count)
    let header: [UInt8] = [encryptionMode & 0x0F, label] + nonce
        + [UInt8(length >> 24), UInt8(truncatingIfNeeded: length >> 16), UInt8(truncatingIfNeeded: length >> 8),
           UInt8(truncatingIfNeeded: length)]
    return header + cipher
}

/// 決まった模様のバイト列
func pattern(_ length: Int, seed: Int) -> [UInt8] {
    (0..<length).map { UInt8(truncatingIfNeeded: $0 * 31 + seed) }
}

@Suite struct DTCPStreamingTests {
    private let exchangeKey = hexBytes(V.katPcpExchangeKey)
    private let label: UInt8 = 0x2A
    private let encryptionMode: UInt8 = 0x04
    private let nonceA: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
    private let nonceB: [UInt8] = [8, 7, 6, 5, 4, 3, 2, 1]
    private static let mebibyte = 1024 * 1024
    private static let chunkSize = 16 * 1024

    @Test func aOneMebibyteBlockRoundTrips() throws {
        let plain = pattern(Self.mebibyte, seed: 7)
        let key = pattern(16, seed: 3)
        let iv = pattern(16, seed: 11)
        let cipher = try DTCPAES.cbcEncrypt(key: key, iv: iv, data: plain)
        #expect(try DTCPAES.cbcDecrypt(key: key, iv: iv, data: cipher) == plain)
    }

    @Test func twoOneMebibytePacketsInSixteenKibibyteChunksDecryptExactlyWhileStreaming() async throws {
        let plainA = pattern(Self.mebibyte, seed: 21)
        let plainB = pattern(Self.mebibyte, seed: 99)
        let wire = try buildPCPPacket(exchangeKey: exchangeKey, label: label, encryptionMode: encryptionMode,
                                      nonce: nonceA, plaintext: plainA)
            + buildPCPPacket(exchangeKey: exchangeKey, label: label, encryptionMode: encryptionMode,
                             nonce: nonceB, plaintext: plainB)
        let key = exchangeKey
        let expectedLabel = label
        let decryptor = PCPDecryptor { requested in
            #expect(requested == expectedLabel)
            return key
        }
        let firstPacketWireLength = PCPHeader.size + plainA.count
        var output = Data()
        var emergedBeforeFirstPacketCompleted = false
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            var offset = 0
            while offset < wire.count {
                let end = min(offset + Self.chunkSize, wire.count)
                for piece in try await decryptor.add(Data(wire[offset..<end])) { output.append(piece) }
                if end < firstPacketWireLength && !output.isEmpty { emergedBeforeFirstPacketCompleted = true }
                offset = end
            }
        }
        // 最初のパケットが届き切る前に平文が出ている（パケット全体を待つ作りではない）
        #expect(emergedBeforeFirstPacketCompleted)
        #expect(await decryptor.packetsDecrypted == 2)
        #expect(await decryptor.plaintextBytes == plainA.count + plainB.count)
        #expect(output.count == plainA.count + plainB.count)
        #expect(Array(output.prefix(plainA.count)) == plainA)
        #expect(Array(output.suffix(plainB.count)) == plainB)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("PCP timing: 2 MiB in 16 KiB chunks took \(elapsed) (\(String(format: "%.1f", 2.0 / max(seconds, 1e-9))) MiB/s)")
        // O(n²) の再発を止める関門（torne mobile HB のビルド 7 は事実上止まった）。DR は約 2 MB/s
        #expect(elapsed < .seconds(2))
    }

    @Test func theFirstBlocksDecryptAsSoonAsTheyArrive() async throws {
        let plain = pattern(4096, seed: 42)
        let wire = try buildPCPPacket(exchangeKey: exchangeKey, label: label, encryptionMode: encryptionMode,
                                      nonce: nonceA, plaintext: plain)
        let key = exchangeKey
        let decryptor = PCPDecryptor { _ in key }
        // ヘッダだけ：まだ復号するものは無い
        #expect(try await decryptor.add(Data(wire[0..<PCPHeader.size])).isEmpty)
        // 暗号文の 1 ブロック：平文の 1 ブロックがちょうど出る
        let first = try await decryptor.add(Data(wire[PCPHeader.size..<(PCPHeader.size + 16)]))
        #expect(first.count == 1)
        #expect(Array(first[0]) == Array(plain[0..<16]))
        let rest = try await decryptor.add(Data(wire[(PCPHeader.size + 16)...]))
        let joined = rest.reduce(first[0]) { $0 + $1 }
        #expect(Array(joined) == plain)
        #expect(await decryptor.packetsDecrypted == 1)
    }

    @Test func anOddLengthPacketDropsThePaddingTail() async throws {
        let plain = pattern(1000, seed: 5)
        let wire = try buildPCPPacket(exchangeKey: exchangeKey, label: label, encryptionMode: encryptionMode,
                                      nonce: nonceA, plaintext: plain)
        let key = exchangeKey
        let decryptor = PCPDecryptor { _ in key }
        var output = Data()
        for byte in wire { for piece in try await decryptor.add(Data([byte])) { output.append(piece) } }
        #expect(Array(output) == plain)
    }

    @Test func anAbsurdContentLengthIsAParseErrorNotAStall() async throws {
        let header: [UInt8] = [encryptionMode, label] + nonceA + [0xFF, 0xFF, 0xFF, 0xFF]
        let key = exchangeKey
        let decryptor = PCPDecryptor { _ in key }
        await #expect(throws: DTCPError.self) { try await decryptor.add(Data(header)) }
    }
}
