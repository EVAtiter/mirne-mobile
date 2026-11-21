import Foundation

/// TS のパケットの長さ。素の 188 バイトと、4 バイトのタイムスタンプが前に付いた 192 バイト
/// （DLNA の `DTCP_MPEG_TS_JP_T`・`video/vnd.dlna.mpeg-tts` の申告）
public enum TSFraming: Int, Sendable {
    case plain = 188
    case timestamped = 192

    /// 192 バイトのパケットで、同期バイトの前に付くタイムスタンプのバイト数
    public static let timestampLength = 4
    /// 長さを決めるのに、同期バイトが続けて並んでいることを確かめるパケットの数
    public static let confirmations = 5

    /// 先頭から同期バイトの並びを探し、パケットの長さと最初の同期バイトの位置を返す。
    /// 188 の並びを先に試す（192 の流れで 188 の並びが続けて当たることはまず無い）。
    ///
    /// 192 では、同期バイトの直前のタイムスタンプの 4 バイトにも 0x47 がありうる（上位のバイトは数パケットの間
    /// 変わらないので、並びとして当たる）。タイムスタンプは同期バイトの**前**にあるので、4 バイト以内に続けて
    /// 当たったら後ろのものを採る
    public static func detect(_ bytes: [UInt8]) -> (framing: TSFraming, syncOffset: Int)? {
        for framing in [TSFraming.plain, .timestamped] {
            let needed = framing.rawValue * (confirmations - 1) + 1
            guard bytes.count >= needed else { continue }
            let last = min(framing.rawValue, bytes.count - needed + 1)
            func aligned(_ start: Int) -> Bool {
                start < bytes.count - needed + 1
                    && (0..<confirmations).allSatisfy { bytes[start + $0 * framing.rawValue] == TSPacket.syncByte }
            }
            for start in 0..<last where aligned(start) {
                guard framing == .timestamped else { return (framing, start) }
                let later = (1...timestampLength).map { start + $0 }.filter(aligned)
                return (framing, later.last ?? start)
            }
        }
        return nil
    }
}

/// 受信した TS を 188 バイトのパケットの流れに直す（192 バイトなら前の 4 バイトを落とす）。
///
/// 最初に長さを決め（決まるまでは溜める）、以後はその長さで切る。同期バイトが期待の位置に無かった
/// パケットは数えて、1 バイトずつずらして探し直す（`resynchronizations`）
public final class TSFramer {
    /// 決めた長さ。決まるまでは nil
    public private(set) var framing: TSFraming?
    /// 長さを決めるまでに読み飛ばしたバイト数
    public private(set) var leadingSkippedBytes = 0
    /// 同期バイトが期待の位置に無く、探し直した回数
    public private(set) var resynchronizations = 0
    /// 出した 188 バイトのパケットの数
    public private(set) var packets = 0

    private var residue = [UInt8]()

    public init() {}

    /// 受信したバイト列を渡し、188 バイトのパケットを連ねたものを返す（受信の切れ目はどこでもよい）
    public func feed(_ data: Data) -> Data {
        residue.append(contentsOf: data)
        if framing == nil {
            guard let (found, syncOffset) = TSFraming.detect(residue) else {
                // 決まらないまま溜まりすぎたら、古い分を捨てる（2 つ分の長さを残す）
                let keep = TSFraming.timestamped.rawValue * TSFraming.confirmations * 2
                if residue.count > keep * 4 {
                    leadingSkippedBytes += residue.count - keep
                    residue.removeFirst(residue.count - keep)
                }
                return Data()
            }
            framing = found
            // 192 なら、同期バイトの 4 バイト前がパケットの頭
            let start = found == .timestamped ? max(0, syncOffset - TSFraming.timestampLength) : syncOffset
            leadingSkippedBytes += start
            residue.removeFirst(start)
        }
        guard let framing else { return Data() }
        let syncAt = framing == .timestamped ? TSFraming.timestampLength : 0
        var out = Data()
        out.reserveCapacity(residue.count)
        var offset = 0
        while residue.count - offset >= framing.rawValue {
            if residue[offset + syncAt] != TSPacket.syncByte {
                resynchronizations += 1
                offset += 1
                continue
            }
            out.append(contentsOf: residue[(offset + syncAt)..<(offset + syncAt + TSPacket.size)])
            packets += 1
            offset += framing.rawValue
        }
        residue.removeFirst(offset)
        return out
    }
}
