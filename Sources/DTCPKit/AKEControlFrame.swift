// AKE の制御フレーム（11 バイトのヘッダ + ペイロード）。
//
// 出典: torne mobile HB（MIT、© mar1mo-41414）の lib/core/dtcp/ake.dart。
// その元は pydtcpip（MIT、© tsukumijima）の dtcp/ake.py の ControlFrame・AKECommand。
//
// 生のバイトの決まり（torne mobile HB の計画書 §28.2、実機で完走した参照実装に揃えたもの）:
// - 要求のフレームの 9 バイト目（役割）は 0x01（シンク）、11 バイト目（状態）は 0x0F
// - ACCEPTED の応答は、受け取ったフレームのヘッダをそのまま写し、種別を ACCEPTED に、状態を 0 にするだけ

import Foundation

/// AKE のコマンドの値（pydtcpip の AKECommand）
enum AKECommand {
    static let challenge: UInt8 = 0x01
    static let response: UInt8 = 0x02
    static let exchangeKey: UInt8 = 0x03
    static let srmUpdate: UInt8 = 0x04
    static let rttSetup: UInt8 = 0x11
    static let rttTest: UInt8 = 0x12
    static let rttReady: UInt8 = 0x91
    static let rttVerify: UInt8 = 0x92
}

struct AKEControlFrame: Sendable, Equatable {
    /// ヘッダのバイト数
    static let headerSize = 11
    /// 長さのフィールドに含まれる、ヘッダのうち 4 バイト目以降の分（長さ = ペイロード + 8）
    private static let lengthOverhead = 8
    /// 1 バイト目の決まった値
    private static let leadingByte: UInt8 = 0x01
    /// 4 バイト目の種別：要求・ACCEPTED
    static let typeControl: UInt8 = 0x0
    static let typeAccepted: UInt8 = 0x9
    /// 7 バイト目の手順：Full Authentication
    static let procedureFullAuthentication: UInt8 = 0x04
    /// 8 バイト目の鍵の種類：AES-128
    static let keyTypeAES128: UInt8 = 0x08
    /// 9 バイト目の役割：シンク（送り手の機器 ID の最上位の 4 ビット。参照実装はシンクから常に 0x01 を送る）
    static let roleSink: UInt8 = 0x01
    /// 要求のフレームの 11 バイト目（参照実装の値）
    static let requestStatusByte: UInt8 = 0x0F

    var command: UInt8
    var payload: [UInt8]
    var isResponse = false
    var procedure = procedureFullAuthentication
    var keyType = keyTypeAES128
    var roleByte = roleSink
    var label: UInt8 = 0
    var status: UInt8 = 0

    var isAccepted: Bool { isResponse && status == 0 }

    /// このフレームへの ACCEPTED の応答。ヘッダ（手順・鍵の種類・役割・ラベル）は受け取ったまま写し、
    /// 種別を ACCEPTED に、状態を 0 にする。ペイロードは差し替える（既定は空）
    func accepted(payload: [UInt8] = []) -> AKEControlFrame {
        AKEControlFrame(command: command, payload: payload, isResponse: true, procedure: procedure,
                        keyType: keyType, roleByte: roleByte, label: label, status: 0)
    }

    func encode() -> [UInt8] {
        let totalLength = payload.count + Self.lengthOverhead
        var out = [UInt8](repeating: 0, count: Self.headerSize)
        out[0] = Self.leadingByte
        out[1] = UInt8(truncatingIfNeeded: totalLength >> 8)
        out[2] = UInt8(truncatingIfNeeded: totalLength)
        out[3] = isResponse ? Self.typeAccepted : Self.typeControl
        out[4] = 0
        out[5] = command
        out[6] = procedure
        out[7] = keyType
        out[8] = roleByte
        out[9] = label
        // 要求は 0x0F、応答は状態の 4 ビット（参照実装どおり）
        out[10] = isResponse ? status & 0x0F : Self.requestStatusByte
        return out + payload
    }

    /// `data` の先頭から 1 つのフレームを読む。足りなければ nil。ヘッダが壊れていれば誤り
    static func parse(_ data: some Collection<UInt8>) throws -> (frame: AKEControlFrame, consumed: Int)? {
        guard data.count >= headerSize else { return nil }
        let header = Array(data.prefix(headerSize))
        guard header[0] == leadingByte, header[4] == 0 else {
            throw DTCPError.parse("dtcp:ake", "invalid AKE frame header")
        }
        let totalLength = Int(header[1]) << 8 | Int(header[2])
        let frameLength = totalLength + 3
        guard totalLength >= lengthOverhead, data.count >= frameLength else { return nil }
        let frameType = header[3] & 0x0F
        guard frameType == typeControl || frameType == typeAccepted else {
            throw DTCPError.parse("dtcp:ake", "unknown AKE frame type 0x\(String(frameType, radix: 16))")
        }
        let payload = Array(data.prefix(frameLength).dropFirst(headerSize))
        let frame = AKEControlFrame(command: header[5], payload: payload, isResponse: frameType == typeAccepted,
                                    procedure: header[6], keyType: header[7], roleByte: header[8],
                                    label: header[9], status: header[10] & 0x0F)
        return (frame, frameLength)
    }
}
