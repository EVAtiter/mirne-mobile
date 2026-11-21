// PCP（Protected Content Packet）の逐次復号。
//
// 出典: torne mobile HB（MIT、© mar1mo-41414）の lib/core/dtcp/pcp.dart。
// その元は pydtcpip（MIT、© tsukumijima）の dtcp/pcp.py。
// PCP は 14 バイトのヘッダと、16 バイトの倍数に詰めた AES-128-CBC の暗号文。ヘッダの長さが平文の長さ。
//
// 逐次復号（torne mobile HB の計画書 §30）：実機のパケットは 1 MiB。遅い経路ではパケットが揃うまで
// 何秒もかかり、その間何も渡さないと再生器が諦めた。CBC の復号は直前の暗号文のブロックだけで足りるので、
// 届いた 16 バイトのブロックから順に復号して渡す。持ち越すのはヘッダと 16 バイトに満たない端だけ。

import Foundation

struct PCPHeader: Sendable, Equatable {
    /// E-EMI（コンテンツの暗号化モード）。ヘッダの 1 バイト目の下位 4 ビット
    let encryptionMode: UInt8
    /// 交換鍵のラベル。2 バイト目
    let exchangeKeyLabel: UInt8
    /// 8 バイトの nonce。3〜10 バイト目
    let nonce: [UInt8]
    /// 平文のバイト数。11〜14 バイト目（ビッグエンディアン）
    let contentLength: Int

    static let size = 14
    private static let nonceRange = 2..<10
    private static let lengthRange = 10..<14

    static func parse(_ bytes: some Collection<UInt8>) throws -> PCPHeader {
        let data = Array(bytes.prefix(size))
        guard data.count == size else { throw DTCPError.parse("dtcp:pcp", "PCP header is too short") }
        // 上位 2 ビット（パケットの種類）と次の 2 ビット（暗号の種類）は 0 だけを扱う
        guard data[0] >> 6 == 0, (data[0] >> 4) & 0x3 == 0 else {
            throw DTCPError.parse("dtcp:pcp", "unsupported PCP packet type or cipher")
        }
        return PCPHeader(encryptionMode: data[0] & 0x0F, exchangeKeyLabel: data[1],
                         nonce: Array(data[nonceRange]),
                         contentLength: Int(DTCPBytes.uint64(data[lengthRange])))
    }
}

/// PCP の content_length の上限（DTCP-IP の仕様、参照実装の値）。これより大きい値は、流れがずれたか
/// 壊れているので、待ち続けずに誤りにする（torne mobile HB の計画書 §29）
let pcpMaximumContentLength = 128 * 1024 * 1024

/// PCP のヘッダのうち、診断に出してよい部分（nonce と鍵は含めない）
struct PCPHeaderSummary: Sendable, Equatable {
    let encryptionMode: UInt8
    let exchangeKeyLabel: UInt8
    let contentLength: Int
}

/// バイトの流れから PCP を復号し、暗号文のブロックが届くたびに平文を返す。
///
/// 使うのは 1 つの読み手だけ（`add` を並行に呼ばない）。鍵はヘッダのラベルで `keyForLabel` から引く
actor PCPDecryptor {
    private let keyForLabel: @Sendable (UInt8) async throws -> [UInt8]

    /// まだ使っていない受信データ。いつもヘッダ 1 つか 16 バイトに満たない端の分しか残らない
    private var pending = Data()
    private var packet: PacketState?

    /// 暗号文を使い切ったパケットの数
    private(set) var packetsDecrypted = 0
    /// これまでに渡した平文のバイト数
    private(set) var plaintextBytes = 0
    /// いま持ち越している暗号文のバイト数（診断用）
    var bufferedBytes: Int { pending.count }

    /// ヘッダを読むたびに呼ぶ（計測用。nonce は渡さない）
    private let onHeader: (@Sendable (PCPHeaderSummary) -> Void)?

    init(keyForLabel: @escaping @Sendable (UInt8) async throws -> [UInt8],
         onHeader: (@Sendable (PCPHeaderSummary) -> Void)? = nil) {
        self.keyForLabel = keyForLabel
        self.onHeader = onHeader
    }

    /// 暗号文を受け取り、この入力で使えるようになった平文の断片を返す（パケットの途中の断片のことも、
    /// まだ何も無いこともある）。返した断片を順につなぐと平文の流れになる
    func add(_ data: Data) async throws -> [Data] {
        pending.append(data)
        var out = [Data]()
        var cursor = pending.startIndex
        defer {
            // 使った分を捨てる（残りは小さいので複製してよい）
            pending = cursor < pending.endIndex ? Data(pending[cursor...]) : Data()
        }
        while true {
            let available = pending.endIndex - cursor
            guard var current = packet else {
                guard available >= PCPHeader.size else { break }
                let header = try PCPHeader.parse(pending[cursor..<(cursor + PCPHeader.size)])
                guard header.contentLength <= pcpMaximumContentLength else {
                    throw DTCPError.parse("dtcp:pcp", "the PCP content length exceeds the limit (\(header.contentLength) bytes)")
                }
                cursor += PCPHeader.size
                onHeader?(PCPHeaderSummary(encryptionMode: header.encryptionMode,
                                           exchangeKeyLabel: header.exchangeKeyLabel, contentLength: header.contentLength))
                let paddedLength = (header.contentLength + DTCPAES.blockSize - 1) / DTCPAES.blockSize * DTCPAES.blockSize
                if paddedLength == 0 {
                    packetsDecrypted += 1
                    continue
                }
                let exchangeKey = try await keyForLabel(header.exchangeKeyLabel)
                let derived = try DTCPContentKey.derive(exchangeKey: exchangeKey, encryptionMode: header.encryptionMode,
                                                        nonce: header.nonce)
                packet = PacketState(decryptor: try AESCBCDecryptor(key: derived.key, iv: derived.iv),
                                     cipherRemaining: paddedLength, plainRemaining: header.contentLength)
                continue
            }
            // パケットの中：手元にある 16 バイトの区切りまでを復号する。最後のブロックも同じように復号し、
            // 詰め物の端は平文の残りの数で切る（パケットごとに長さで切る参照実装と同じ結果）
            let blocks = min(available, current.cipherRemaining) / DTCPAES.blockSize * DTCPAES.blockSize
            guard blocks > 0 else { break }
            let plain = try current.decryptor.decrypt(pending, range: cursor..<(cursor + blocks))
            cursor += blocks
            current.cipherRemaining -= blocks
            let emit = min(blocks, current.plainRemaining)
            current.plainRemaining -= emit
            if emit > 0 {
                out.append(emit == plain.count ? plain : plain.prefix(emit))
                plaintextBytes += emit
            }
            if current.cipherRemaining == 0 {
                packet = nil
                packetsDecrypted += 1
            } else {
                packet = current
            }
        }
        return out
    }

    /// 復号中のパケットの CBC の状態
    private struct PacketState {
        let decryptor: AESCBCDecryptor
        /// このパケットのまだ使っていない暗号文のバイト数（詰め物を含む）
        var cipherRemaining: Int
        /// このパケットのまだ渡していない平文のバイト数（詰め物を除く）
        var plainRemaining: Int
    }
}
