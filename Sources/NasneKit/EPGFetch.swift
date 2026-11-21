// torne mobile HB（MIT、© mar1mo-41414）の lib/core/parsing/epg.dart と services/epg.dart を Swift へ移植したもの。
// EIT セクションの中身の読み方は mirne の SITables.parseEIT（Sources/SI）を使う。

import Compression
import Foundation

/// 番組表のバイナリの形（すべて実機と公式のクライアントで確かめたもの。plan.md §21・§24）
public enum EPGFormat {
    /// `chEpg` の応答の全バイトにかかっている XOR の鍵
    public static let xorKey: UInt8 = 0x9D

    /// 版数表（`status/EPGVersionInfoGet`）の見出しの長さ
    static let versionTableHeaderSize = 12
    /// 見出しの中のレコードの数（u16 BE）の位置
    static let versionTableCountOffset = 8
    /// レコードの頭の長さ（サービスの 3 つ組 + flags）
    static let versionTableRecordHeaderSize = 8
    /// 版数のブロック 1 つの長さ（`[u32 LE = 日数 8]` + 版数の並び）
    static let versionTableBlockSize = 68
    /// flags の「基本（table_id 0x50・0x51）の版数がある」ビット。あればレコードに版数のブロックが 1 つ付く
    static let versionTableBasicFlag: UInt16 = 0x8000
    /// flags の「拡張（0x58・0x59）の版数がある」ビット。あればさらにブロックが 1 つ付く
    static let versionTableExtendedFlag: UInt16 = 0x4000

    /// EPGGet の本文の見出しの長さ（+4 に件数の u16 BE。ほかのバイトは nasne が読まない）
    static let requestHeaderSize = 8
    /// EPGGet の本文の 1 レコードの長さ（3 つ組・LDT の旗・空き・基本 8 バイト・拡張 8 バイトのビットマップ）
    static let requestRecordSize = 24
    /// 見出しの中の件数の位置
    static let requestCountOffset = 4
    /// レコードの中の LDT の旗の位置
    static let requestLinkedDescriptionOffset = 6
    /// レコードの中の基本側のビットマップの位置（table_id 0x50・0x51 の側）
    static let requestBasicBitmapOffset = 8
    /// レコードの中の拡張側のビットマップの位置（0x58・0x59 の側）
    static let requestExtendedBitmapOffset = 16
    /// ビットマップの長さ（64 セグメント = 1 日 8 × 8 日。1 セグメント = 3 時間）
    static let requestBitmapSize = 8

    /// EIT のセクションの見出しの長さ（CRC の前まで、イベントの前まで）
    static let eitHeaderSize = 14
    /// セクションの末尾の CRC-32 の長さ
    static let crcSize = 4
    /// section_length より前の 3 バイト（table_id と長さの 2 バイト）
    static let sectionPrefixSize = 3

    /// ロゴの 1 レコードの見出しの長さ
    static let logoHeaderSize = 20

    // MARK: 版数表と要求

    /// 版数表のサービス（nasne の番組表のデータベースの鍵）を表の順に並べる。
    /// 見出しの件数は実際のレコード数と合わない（20 件で 21 と書いてある）ので使わない
    ///
    /// レコードの長さは flags で決まる（2026-11-21・Buffalo 製で実測。 の後の調べ）：0xC000 は基本と拡張の版数のブロックが 2 つで 144 バイト、
    /// 0x8000 は基本だけの 1 つで 76 バイト、0x0000 はブロックが無く 8 バイト（番組表の無いサービス）。見出しの件数はこの数え方の全部のレコードの数と合う。
    /// 前は 144 バイト固定で読み、0xC000 でないレコードで打ち切っていたので、途中の 0x0000 のレコードの後ろの局（番組表が取れないと見えていた
    /// 地上の 7 局。リモコンキーのある 3 局を含む）を読んでいなかった。知らない flags に当たったら、それより後ろは読まない
    public static func services(inVersionTable table: Data) -> [EPGServiceRef] {
        let bytes = [UInt8](table)
        guard bytes.count >= versionTableHeaderSize else { return [] }
        // 件数が 0 なら（形の分からない表）末尾まで読む
        let count = Int(u16(bytes, versionTableCountOffset))
        var services: [EPGServiceRef] = []
        var offset = versionTableHeaderSize
        var read = 0
        while offset + versionTableRecordHeaderSize <= bytes.count, count == 0 || read < count {
            let flags = u16(bytes, offset + 6)
            guard flags & ~(versionTableBasicFlag | versionTableExtendedFlag) == 0 else { break }
            let hasBasic = flags & versionTableBasicFlag != 0
            let hasExtended = flags & versionTableExtendedFlag != 0
            let length = versionTableRecordHeaderSize + versionTableBlockSize * ((hasBasic ? 1 : 0) + (hasExtended ? 1 : 0))
            guard offset + length <= bytes.count else { break }
            if hasBasic || hasExtended {
                services.append(EPGServiceRef(networkID: Int(u16(bytes, offset)), transportStreamID: Int(u16(bytes, offset + 2)),
                                              serviceID: Int(u16(bytes, offset + 4)), hasBasic: hasBasic, hasExtended: hasExtended))
            }
            offset += length
            read += 1
        }
        return services
    }

    /// EPGGet の本文を組む。両方のビットマップを全部立てると、nasne が持っている全セクションが 1 回で返る。
    /// 局ごとに、版数表に版数の無い側（基本だけの局の拡張など）のビットマップは立てない
    public static func requestBody(services: [EPGServiceRef], basic: Bool = true, extended: Bool = true,
                                   linkedDescriptions: Bool = false) -> Data {
        var bytes = [UInt8](repeating: 0, count: requestHeaderSize + requestRecordSize * services.count)
        put16(&bytes, requestCountOffset, UInt16(services.count))
        var offset = requestHeaderSize
        for service in services {
            put16(&bytes, offset, UInt16(service.networkID))
            put16(&bytes, offset + 2, UInt16(service.transportStreamID))
            put16(&bytes, offset + 4, UInt16(service.serviceID))
            bytes[offset + requestLinkedDescriptionOffset] = linkedDescriptions ? 1 : 0
            if basic && service.hasBasic {
                for index in 0..<requestBitmapSize { bytes[offset + requestBasicBitmapOffset + index] = 0xFF }
            }
            if extended && service.hasExtended {
                for index in 0..<requestBitmapSize { bytes[offset + requestExtendedBitmapOffset + index] = 0xFF }
            }
            offset += requestRecordSize
        }
        return Data(bytes)
    }

    // MARK: 応答

    /// XOR を外す
    public static func deobfuscate(_ data: Data) -> [UInt8] {
        data.map { $0 ^ xorKey }
    }

    /// EPGGet の応答（XOR + zlib）を平文にする
    public static func plaintext(ofResponse data: Data) throws -> [UInt8] {
        let bytes = deobfuscate(data)
        let (output, _) = try ZlibStream.inflate(bytes, from: 0)
        return output
    }

    /// 平文の中の EIT セクションを順に読む。
    /// 平文は「4 バイトの接頭辞 + セクションの連結」（plan.md §24.1）。セクションに見えない位置は 1 バイトずつ飛ばし、
    /// CRC が合うものだけを採る（CRC があるので、イベントの中に偶然現れた形を取り違えない）
    public static func sections(inPlaintext plain: [UInt8]) -> (sections: [EITSection], skippedBytes: Int) {
        var sections: [EITSection] = []
        var skipped = 0
        var offset = 0
        while offset + sectionPrefixSize <= plain.count {
            let tableID = plain[offset]
            let length = (Int(plain[offset + 1] & 0x0F) << 8 | Int(plain[offset + 2])) + sectionPrefixSize
            if SITables.eitTableIDs.contains(tableID), length >= eitHeaderSize + crcSize, offset + length <= plain.count {
                let section = Array(plain[offset..<(offset + length)])
                if PSI.crcIsValid(section), let parsed = SITables.parseEIT(section) {
                    sections.append(parsed)
                    offset += length
                    continue
                }
            }
            skipped += 1
            offset += 1
        }
        skipped += plain.count - offset
        return (sections, skipped)
    }

    /// `channelLogoDataGet` の応答を serviceID → PNG にする。PNG の無いレコードと、先頭のファイルの見出しは除く。
    /// パレットの無い PNG には共通固定色のパレットを足す（`ARIBLogo`）
    public static func logos(ofResponse data: Data) -> [Int: Data] {
        let bytes = deobfuscate(data)
        var logos: [Int: Data] = [:]
        var offset = 0
        while offset + 2 <= bytes.count, bytes[offset] == ZlibStream.headerFirstByte {
            guard let (record, consumed) = try? ZlibStream.inflate(bytes, from: offset), consumed > 0 else { break }
            offset += consumed
            guard record.count >= logoHeaderSize, Int(u16(record, 2)) == record.count else { continue }
            let serviceID = Int(u16(record, 14))
            let pngLength = Int(u16(record, 18))
            guard pngLength > 0, logoHeaderSize + pngLength <= record.count else { continue }
            let png = Data(record[logoHeaderSize..<(logoHeaderSize + pngLength)])
            // パレットの無いロゴに ARIB の共通固定色を足す（足さないと絵として読めない）
            if png.starts(with: [0x89, 0x50, 0x4E, 0x47]) { logos[serviceID] = ARIBLogo.addingCommonPalette(to: png) }
        }
        return logos
    }

    static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    static func put16(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt16) {
        bytes[offset] = UInt8(value >> 8)
        bytes[offset + 1] = UInt8(value & 0xFF)
    }
}

/// 版数表のサービス（ネットワーク・TS・サービスの 3 つ組）
public struct EPGServiceRef: Sendable, Equatable, Hashable {
    public var networkID: Int
    public var transportStreamID: Int
    public var serviceID: Int
    /// 版数表に基本（0x50・0x51）の版数があるか（flags 0x8000）
    public var hasBasic: Bool
    /// 版数表に拡張（0x58・0x59）の版数があるか（flags 0x4000）
    public var hasExtended: Bool

    public init(networkID: Int, transportStreamID: Int, serviceID: Int, hasBasic: Bool = true, hasExtended: Bool = true) {
        self.networkID = networkID
        self.transportStreamID = transportStreamID
        self.serviceID = serviceID
        self.hasBasic = hasBasic
        self.hasExtended = hasExtended
    }
}

/// zlib（RFC 1950）のストリーム。Compression framework の ZLIB は生の deflate（RFC 1951）なので、
/// 2 バイトの見出しと末尾の Adler-32 はここで扱う
public enum ZlibStream {
    /// 見出しの 1 バイト目（CM = 8・CINFO = 7）
    static let headerFirstByte: UInt8 = 0x78
    static let headerSize = 2
    static let trailerSize = 4
    /// FLG の FDICT（辞書付き。nasne の応答では使われない）
    static let presetDictionaryFlag: UInt8 = 0x20
    /// 展開の出力の 1 回の大きさ
    static let chunkSize = 64 * 1024
    /// Adler-32 の法
    static let adlerModulus: UInt32 = 65521

    /// `start` から 1 つのストリームを展開し、出力と、ストリームが占めていたバイト数を返す。
    ///
    /// ストリームの長さは、Compression の残りの入力（src_size）からは出せない：展開を終えた時点で
    /// 入力を先読みして全部使ったことにする（2026-11-17 に試験で確かめた）。そこで torne mobile HB と同じく、
    /// 展開した中身の Adler-32 が並んでいる位置を探し、その手前までを展開し直して同じ中身になるかで決める
    static func inflate(_ bytes: [UInt8], from start: Int) throws -> ([UInt8], Int) {
        let source = "epg:zlib"
        guard start + headerSize + trailerSize <= bytes.count, bytes[start] == headerFirstByte,
              (UInt16(bytes[start]) << 8 | UInt16(bytes[start + 1])) % 31 == 0,
              bytes[start + 1] & presetDictionaryFlag == 0 else {
            throw NasneError.parse(source, "zlib の見出しでない")
        }
        let deflateStart = start + headerSize
        guard let output = rawInflate(bytes[deflateStart...]) else { throw NasneError.parse(source, "deflate として読めない") }
        let checksum = adler32(output)
        let trailer: [UInt8] = [UInt8(checksum >> 24), UInt8((checksum >> 16) & 0xFF),
                                UInt8((checksum >> 8) & 0xFF), UInt8(checksum & 0xFF)]
        var end = deflateStart + 1
        while end + trailerSize <= bytes.count {
            if bytes[end] == trailer[0], bytes[end + 1] == trailer[1], bytes[end + 2] == trailer[2], bytes[end + 3] == trailer[3],
               rawInflate(bytes[deflateStart..<end]) == output {
                return (output, end + trailerSize - start)
            }
            end += 1
        }
        throw NasneError.parse(source, "Adler-32 が見つからない")
    }

    /// 生の deflate を展開する。ストリームの終わり（最後のブロック）まで読めなければ nil
    static func rawInflate(_ input: ArraySlice<UInt8>) -> [UInt8]? {
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(streamPointer) }
        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        let input = Array(input)
        return input.withUnsafeBufferPointer { source -> [UInt8]? in
            guard let base = source.baseAddress else { return nil }
            streamPointer.pointee.src_ptr = base
            streamPointer.pointee.src_size = source.count
            while true {
                let status: compression_status = chunk.withUnsafeMutableBufferPointer { buffer in
                    streamPointer.pointee.dst_ptr = buffer.baseAddress!
                    streamPointer.pointee.dst_size = chunkSize
                    return compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                output.append(contentsOf: chunk[0..<(chunkSize - streamPointer.pointee.dst_size)])
                switch status {
                case COMPRESSION_STATUS_OK:
                    // 入力を使い切ったのに終わらない（ストリームが途中で切れている）
                    if streamPointer.pointee.src_size == 0, streamPointer.pointee.dst_size > 0 { return nil }
                case COMPRESSION_STATUS_END: return output
                default: return nil
                }
            }
        }
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % adlerModulus
            b = (b + a) % adlerModulus
        }
        return b << 16 | a
    }
}

/// 番組表を取った結果
public struct EPGFetchResult: Sendable {
    public var sections: [EITSection]
    /// 版数表にあったサービスの数
    public var serviceCount: Int
    /// 応答の大きさ（XOR・zlib のまま）
    public var responseBytes: Int
    /// 平文の大きさ
    public var plaintextBytes: Int
    /// セクションとして読めなかったバイト数（接頭辞の 4 バイトなど）
    public var skippedBytes: Int
}

/// 番組表を取る（版数表 → EPGGet → 平文 → EIT セクション）
public struct WebAPIProgramGuideService: Sendable {
    private let plain: WebAPITransport
    private let authenticated: WebAPITransport

    public init(transport: WebAPITransport, tokens: TokenProvider) {
        plain = transport
        authenticated = transport.authenticated(with: tokens)
    }

    /// エンドポイントの表（転送層の機器の表）
    private var endpoints: WebAPIEndpointTable { plain.endpoints }

    /// 版数表（`status/EPGVersionInfoGet` の応答のバイト列）。変わっていなければ EPGGet を送らなくてよい
    public func versionTable(broadcastingType: Int = BroadcastingType.terrestrial) async throws -> Data {
        try await plain.getBytes(endpoints.epgVersionInfoGet, parameters: [endpoints.parameters.broadcastingType: String(broadcastingType)])
    }

    /// 読んだ版数表のサービスで EPGGet を 1 回送り、EIT のセクションにする
    public func fetch(versionTable: Data) async throws -> EPGFetchResult {
        let services = EPGFormat.services(inVersionTable: versionTable)
        guard !services.isEmpty else {
            throw NasneError.parse("webapi:\(endpoints.epgVersionInfoGet.path)", "版数表にサービスが無い")
        }
        let response = try await authenticated.postBinary(endpoints.epgGet,
                                                          body: EPGFormat.requestBody(services: services))
        let plaintext = try EPGFormat.plaintext(ofResponse: response)
        let (sections, skipped) = EPGFormat.sections(inPlaintext: plaintext)
        return EPGFetchResult(sections: sections, serviceCount: services.count, responseBytes: response.count,
                              plaintextBytes: plaintext.count, skippedBytes: skipped)
    }

    /// 版数表を読んでから EPGGet を送る
    public func fetch(broadcastingType: Int = BroadcastingType.terrestrial) async throws -> EPGFetchResult {
        try await fetch(versionTable: versionTable(broadcastingType: broadcastingType))
    }

    /// 局のロゴ（serviceID → PNG）
    public func logos(broadcastingType: Int = BroadcastingType.terrestrial) async throws -> [Int: Data] {
        EPGFormat.logos(ofResponse: try await plain.getBytes(endpoints.channelLogoDataGet,
                                                             parameters: [endpoints.parameters.broadcastingType: String(broadcastingType)]))
    }
}
