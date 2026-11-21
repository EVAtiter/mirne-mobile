// SRM（System Renewability Message）の解析と失効の判定。
//
// 出典: torne mobile HB（MIT、© mar1mo-41414）の lib/core/dtcp/srm.dart。
// その元は pydtcpip（MIT、© tsukumijima）の dtcp/srm.py。
// 失効は世代をまたいで 1 つの範囲の列に積み上げる。SRM は DTLA が署名した公開データで秘密を含まないので、
// 資格情報とは別の、ふつうの保存先に置いてよい。

import Foundation

struct DTCPSRM: Sendable, Equatable {
    /// SRM の版（ヘッダの 2〜3 バイト目）
    let version: UInt16
    /// 含まれる最後の世代（最初の部分だけなら 0）
    let generation: UInt8
    /// SRM のバイト列そのもの（相手へ渡すときと、isNewer の長さの比較に使う）
    let data: [UInt8]
    /// 失効した機器 ID の範囲（両端を含む）。個別の ID は (id, id)
    let revokedRanges: [ClosedRange<UInt64>]

    /// 署名のバイト数
    private static let signatureLength = 40
    /// ヘッダのバイト数（世代の上限・予約・版 2 バイト）
    private static let headerLength = 4
    /// 世代の長さのフィールドのバイト数
    private static let generationLengthFieldSize = 2
    /// 世代 0 の長さの上限・世代 1 以降の長さの上限（pydtcpip の値）
    private static let firstGenerationMaximum = 124
    private static let laterGenerationMaximum = 978
    /// 項目の種別（ヘッダの上位 3 ビット）：0 = 個別の ID、1 = 範囲
    private static let entryTypeSingle: UInt8 = 0
    private static let entryTypeRange: UInt8 = 1
    /// 個別の ID の項目・範囲の項目のバイト数
    private static let singleEntryLength = 5
    private static let rangeEntryLength = 7

    func isRevoked(_ deviceID: UInt64) -> Bool {
        revokedRanges.contains { $0.contains(deviceID) }
    }

    /// 版が高い方、同じ版なら長い（世代が多い）方を新しいとする（参照実装どおり）
    func isNewer(than other: DTCPSRM) -> Bool {
        version > other.version || (version == other.version && data.count > other.data.count)
    }

    /// 世代 0 の部分だけ（ヘッダの署名付きの範囲を保つ）。世代 0 までしか持てない相手へ渡すときに使う
    var firstGenerationOnly: [UInt8] {
        let firstLength = Int(data[Self.headerLength]) << 8 | Int(data[Self.headerLength + 1])
        return Array(data[0..<(Self.headerLength + firstLength)])
    }

    /// SRM を解析し、署名を確かめる。各世代は自分の DTLA 署名まで届いていなければならず、
    /// 署名はそれより前のすべて（累積）に対して確かめる
    static func parse(_ bytes: some Collection<UInt8>, authorityKeys: [[UInt8]] = []) throws -> DTCPSRM {
        let data = Array(bytes)
        func failure(_ detail: String) -> DTCPError { .parse("dtcp:srm", detail) }

        guard data.count >= headerLength else { throw failure("SRM is too short") }
        let maximumGeneration = Int(data[0])
        guard data[1] == 0 else { throw failure("invalid SRM header") }
        let version = UInt16(data[2]) << 8 | UInt16(data[3])

        var ranges = [ClosedRange<UInt64>]()
        var generation = -1
        var offset = headerLength
        while offset < data.count {
            generation += 1
            guard generation <= maximumGeneration else { throw failure("SRM generation count exceeds the header") }
            guard offset + generationLengthFieldSize <= data.count else {
                throw failure("SRM ends inside a generation header")
            }
            let generationLength = Int(data[offset]) << 8 | Int(data[offset + 1])
            let maximumSize = generation == 0 ? firstGenerationMaximum : laterGenerationMaximum
            guard generationLength >= generationLengthFieldSize + signatureLength, generationLength <= maximumSize else {
                throw failure("SRM generation has an invalid length")
            }
            let generationEnd = offset + generationLength
            guard generationEnd <= data.count else { throw failure("SRM generation overruns the data") }
            let signatureStart = generationEnd - signatureLength
            guard DTCPAuthority.verify(data: data[0..<signatureStart], signature: data[signatureStart..<generationEnd],
                                       authorityKeys: authorityKeys) else {
                throw failure("SRM signature verification failed")
            }

            var position = offset + generationLengthFieldSize
            while position < signatureStart {
                let entryHeader = data[position]
                position += 1
                let entryType = entryHeader >> 5
                let entryCount = Int(entryHeader & 0x1F)
                guard entryType <= entryTypeRange else { throw failure("unknown SRM entry type") }
                for _ in 0..<entryCount {
                    if entryType == entryTypeSingle {
                        guard position + singleEntryLength <= signatureStart else {
                            throw failure("SRM entry overruns the generation")
                        }
                        let id = DTCPBytes.uint64(data[position..<(position + 5)])
                        ranges.append(id...id)
                        position += singleEntryLength
                    } else {
                        guard position + rangeEntryLength <= signatureStart else {
                            throw failure("SRM entry overruns the generation")
                        }
                        let start = DTCPBytes.uint64(data[position..<(position + 5)])
                        let span = UInt64(data[position + 5]) << 8 | UInt64(data[position + 6])
                        ranges.append(start...(start + span))
                        position += rangeEntryLength
                    }
                }
            }
            offset = generationEnd
        }
        return DTCPSRM(version: version, generation: UInt8(max(generation, 0)), data: data, revokedRanges: ranges)
    }
}

/// SRM の保存先（SRM は公開データなので、資格情報とは別のふつうの保存先でよい）
protocol DTCPSRMStore: Sendable {
    func load() -> DTCPSRM?
    func save(raw: [UInt8], srm: DTCPSRM)
}
