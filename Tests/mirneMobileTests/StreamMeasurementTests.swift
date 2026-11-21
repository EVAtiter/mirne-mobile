// 計測の部品の試験：ペアのファイルの読み方・HEAD の作法・PCP のヘッダの要約・TS のパケット長・ES の形式。

import Foundation
import Testing

private typealias V = DTCPTestVectors

@Suite("資格情報ペアのファイルの読み方")
struct CredentialInputTests {
    let certificate = DTCPBytes.fromHex(V.katSinkCert)!

    @Test("ちょうどの長さのバイナリはそのまま")
    func binary() throws {
        #expect(try DTCPCredentialInput.decode(Data(certificate), expectedLength: 88, name: "c") == certificate)
    }

    @Test("16 進（空白・改行・大文字を許す）と base64 を読む")
    func text() throws {
        let hex = DTCPBytes.hex(certificate).uppercased()
        let spaced = stride(from: 0, to: hex.count, by: 32).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<(hex.index(start, offsetBy: 32, limitedBy: hex.endIndex) ?? hex.endIndex)])
        }.joined(separator: "\n ")
        #expect(try DTCPCredentialInput.decode(Data(spaced.utf8), expectedLength: 88, name: "c") == certificate)
        let base64 = Data(certificate).base64EncodedString() + "\n"
        #expect(try DTCPCredentialInput.decode(Data(base64.utf8), expectedLength: 88, name: "c") == certificate)
    }

    @Test("読めなければ誤り。文言に中身を入れない")
    func rejects() {
        let secretLooking = "zz" + String(repeating: "ab", count: 10)
        let error = #expect(throws: DTCPError.self) {
            try DTCPCredentialInput.decode(Data(secretLooking.utf8), expectedLength: 20, name: "private key")
        }
        #expect(error?.detail.contains(secretLooking) == false)
        #expect(error?.detail.contains("22 bytes") == true)
        #expect(throws: DTCPError.self) {
            try DTCPCredentialInput.decode(Data([0xFF, 0xFE, 0x00]), expectedLength: 20, name: "private key")
        }
    }
}

@Suite("pydtcpip の credentials.env からの取り込み")
struct CredentialDotEnvTests {
    let certificate = DTCPBytes.fromHex(V.katSinkCert)!
    let privateKey = DTCPBytes.fromHex(V.katSinkPriv)!

    private func decode(_ text: String, environment: [String: String] = [:]) throws -> (certificate: [UInt8], privateKey: [UInt8]) {
        try DTCPCredentialInput.decodeDotEnv(Data(text.utf8), environment: environment,
                                             certificateLength: 88, privateKeyLength: 20)
    }

    @Test("README の形（16 進の 2 行）を読む")
    func readmeForm() throws {
        let pair = try decode("PYDTCPIP_CERTIFICATE=\(V.katSinkCert)\nPYDTCPIP_PRIVATE_KEY=\(V.katSinkPriv)\n")
        #expect(pair.certificate == certificate)
        #expect(pair.privateKey == privateKey)
    }

    @Test("注釈・空行・export・引用符・小文字の名前・行末の注釈を許す")
    func dotenvVariants() throws {
        let text = """
        # 注釈

        export pydtcpip_certificate="\(V.katSinkCert.uppercased())"
        PYDTCPIP_PRIVATE_KEY = \(V.katSinkPriv)   # 行末の注釈
        PYDTCPIP_OTHER=ignored
        """
        let pair = try decode(text)
        #expect(pair.certificate == certificate)
        #expect(pair.privateKey == privateKey)
    }

    @Test("先頭の BOM と CRLF の改行を許す")
    func bomAndCRLF() throws {
        let pair = try decode("\u{FEFF}PYDTCPIP_CERTIFICATE=\(V.katSinkCert)\r\nPYDTCPIP_PRIVATE_KEY=\(V.katSinkPriv)\r\n")
        #expect(pair.certificate == certificate)
        #expect(pair.privateKey == privateKey)
    }

    @Test("同じ名前の環境変数がファイルより優先する（pydtcpip と同じ）")
    func environmentWins() throws {
        let other = DTCPBytes.fromHex(V.katSrcPriv)!
        let pair = try decode("PYDTCPIP_CERTIFICATE=\(V.katSinkCert)\nPYDTCPIP_PRIVATE_KEY=\(V.katSinkPriv)\n",
                              environment: ["PYDTCPIP_PRIVATE_KEY": V.katSrcPriv])
        #expect(pair.privateKey == other)
    }

    @Test("名前が無ければ誤り。文言に値を入れない")
    func missing() {
        let error = #expect(throws: DTCPError.self) {
            try decode("PYDTCPIP_CERTIFICATE=\(V.katSinkCert)\n")
        }
        #expect(error?.detail.contains("PYDTCPIP_PRIVATE_KEY is missing") == true)
        #expect(error?.detail.contains(V.katSinkCert) == false)
    }
}

@Suite("配信 URL への HEAD")
struct ContentHTTPTests {
    let url = URL(string: "http://\(NasneFixture.host):58890/web/video/pvr?id=1&quality=dr")!

    @Test("Content-Type のパラメータの名前は大文字小文字を区別せず、引用符を外す")
    func parsesContentType() {
        let (type, parameters) = DTCPContentHTTP.parseContentType(
            #"Application/X-DTCP1; dtcp1HOST="192.0.2.1"; DTCP1PORT=57343; CONTENTFORMAT="video/vnd.dlna.mpeg-tts""#)
        #expect(type == "application/x-dtcp1")
        #expect(parameters["dtcp1host"] == "192.0.2.1")
        #expect(parameters["dtcp1port"] == "57343")
        #expect(parameters["contentformat"] == "video/vnd.dlna.mpeg-tts")
    }

    /// HEAD に Content-Type と contentFeatures を返す HTTP のモック
    final class HeadReply: HTTPExchanging, @unchecked Sendable {
        let status: Int
        let headers: [String: String]
        var sent: [URLRequest] = []
        init(status: Int = 200, headers: [String: String]) { self.status = status; self.headers = headers }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            sent.append(request)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
    }

    @Test("HEAD で AKE の相手とシークの申告を返す。見出しは torne mobile HB と同じ")
    func endpoint() async throws {
        let http = HeadReply(headers: ["Content-Type": "application/x-dtcp1;DTCP1HOST=192.0.2.1;DTCP1PORT=57343",
                                       "contentFeatures.dlna.org": "DLNA.ORG_OP=10;DLNA.ORG_FLAGS=0"])
        let endpoint = try await DTCPContentHTTP.endpoint(of: url, client: http)
        #expect(endpoint == DTCPContentEndpoint(akeHost: "192.0.2.1", akePort: 57343,
                                                contentFeatures: "DLNA.ORG_OP=10;DLNA.ORG_FLAGS=0"))
        let request = try #require(http.sent.first)
        #expect(request.httpMethod == "HEAD")
        #expect(request.value(forHTTPHeaderField: "transferMode.dlna.org") == "Streaming")
        #expect(request.value(forHTTPHeaderField: "getcontentFeatures.dlna.org") == "1")
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
    }

    @Test("200 でない・DTCP でない・相手が無いときは誤り")
    func rejects() async {
        await #expect(throws: DTCPError.self) {
            try await DTCPContentHTTP.endpoint(of: url, client: HeadReply(status: 404, headers: [:]))
        }
        await #expect(throws: DTCPError.self) {
            try await DTCPContentHTTP.endpoint(of: url, client: HeadReply(headers: ["Content-Type": "video/mpeg"]))
        }
        await #expect(throws: DTCPError.self) {
            try await DTCPContentHTTP.endpoint(of: url, client: HeadReply(headers: ["Content-Type": "application/x-dtcp1;DTCP1HOST=192.0.2.1"]))
        }
    }
}

@Suite("PCP のヘッダの要約")
struct PCPHeaderSummaryTests {
    @Test("ヘッダを読むたびに E-EMI・ラベル・長さを渡す（nonce は渡さない）")
    func reportsHeaders() async throws {
        let key = pattern(12, seed: 3)
        let nonce = pattern(8, seed: 5)
        let first = try buildPCPPacket(exchangeKey: key, label: 7, encryptionMode: 0xC, nonce: nonce, plaintext: pattern(100, seed: 1))
        let second = try buildPCPPacket(exchangeKey: key, label: 8, encryptionMode: 0xC, nonce: nonce, plaintext: pattern(32, seed: 2))
        final class Box: @unchecked Sendable { var values: [PCPHeaderSummary] = [] }
        let box = Box()
        let decryptor = PCPDecryptor(keyForLabel: { _ in key }, onHeader: { box.values.append($0) })
        _ = try await decryptor.add(Data(first + second))
        #expect(box.values == [PCPHeaderSummary(encryptionMode: 0xC, exchangeKeyLabel: 7, contentLength: 100),
                               PCPHeaderSummary(encryptionMode: 0xC, exchangeKeyLabel: 8, contentLength: 32)])
    }
}

@Suite("TS のパケット長")
struct TSFramingTests {
    /// PID と連番の入った 188 バイトのパケット
    static func packet(_ index: Int) -> [UInt8] {
        [0x47, 0x01, 0x00, 0x10 | UInt8(index & 0x0F)] + [UInt8](repeating: UInt8(truncatingIfNeeded: index), count: 184)
    }

    @Test("188 と 192（4 バイトのタイムスタンプ付き）を見分ける")
    func detects() {
        let plain = (0..<6).flatMap(Self.packet)
        #expect(TSFraming.detect(plain)?.framing == .plain)
        #expect(TSFraming.detect(plain)?.syncOffset == 0)
        let stamped: [UInt8] = (0..<6).flatMap { i -> [UInt8] in [0x00, 0x47, 0x47, UInt8(i)] + Self.packet(i) }
        let found = TSFraming.detect([0x12, 0x34] + stamped)
        #expect(found?.framing == .timestamped)
        #expect(found?.syncOffset == 6)
        #expect(TSFraming.detect([UInt8](repeating: 0, count: 2000)) == nil)
    }

    @Test("192 の流れから 4 バイトを落とし、受信の切れ目をまたいでも 188 の並びにする")
    func strips() {
        let count = 20
        let stamped: [UInt8] = [0x99, 0x98, 0x97] + (0..<count).flatMap { i -> [UInt8] in [0x01, 0x02, 0x03, UInt8(i)] + Self.packet(i) }
        let framer = TSFramer()
        var out = Data()
        var offset = 0
        for size in [100, 500, 777, 1, 3000] + [Int](repeating: 333, count: 20) where offset < stamped.count {
            let end = min(offset + size, stamped.count)
            out.append(framer.feed(Data(stamped[offset..<end])))
            offset = end
        }
        #expect(framer.framing == .timestamped)
        #expect(framer.leadingSkippedBytes == 3)
        #expect(framer.resynchronizations == 0)
        #expect(framer.packets == count)
        #expect([UInt8](out) == (0..<count).flatMap(Self.packet))
    }

    @Test("188 の流れはそのまま通す")
    func passesPlain() {
        let plain = (0..<10).flatMap(Self.packet)
        let framer = TSFramer()
        #expect([UInt8](framer.feed(Data(plain))) == plain)
        #expect(framer.framing == .plain)
    }
}

@Suite("ES の形式")
struct ElementaryStreamFormatTests {
    /// ビット単位の書き手（試験で SPS を組み立てる）
    struct BitWriter {
        var bits: [Int] = []
        mutating func put(_ value: Int, _ count: Int) { for i in (0..<count).reversed() { bits.append(value >> i & 1) } }
        mutating func ue(_ value: Int) {
            let code = value + 1
            let length = Int.bitWidth - code.leadingZeroBitCount
            put(0, length - 1)
            put(code, length)
        }
        var bytes: [UInt8] {
            var padded = bits + [1]
            while padded.count % 8 != 0 { padded.append(0) }
            return stride(from: 0, to: padded.count, by: 8).map { i in UInt8(padded[i..<(i + 8)].reduce(0) { $0 << 1 | $1 }) }
        }
    }

    /// High プロファイル・4:2:0・フレーム・1440×1088 を下 8 ラインだけ切った SPS（PES の形で返す）
    static func highProfileSPS() -> Data {
        var w = BitWriter()
        w.put(100, 8); w.put(0, 8); w.put(40, 8)  // profile_idc・制約・level_idc
        w.ue(0)                                    // seq_parameter_set_id
        w.ue(1)                                    // chroma_format_idc = 4:2:0
        w.ue(0); w.ue(0); w.put(0, 1)              // bit depth・qpprime
        w.put(0, 1)                                // seq_scaling_matrix_present_flag
        w.ue(0)                                    // log2_max_frame_num_minus4
        w.ue(0); w.ue(0)                           // pic_order_cnt_type = 0・log2_max_poc_lsb_minus4
        w.ue(4); w.put(0, 1)                       // max_num_ref_frames・gaps
        w.ue(1440 / 16 - 1); w.ue(1088 / 16 - 1)
        w.put(1, 1); w.put(1, 1)                   // frame_mbs_only・direct_8x8
        w.put(1, 1); w.ue(0); w.ue(0); w.ue(0); w.ue(4)  // 切り取り（下 4×2 = 8 ライン）
        return Data([0, 0, 0, 1, 0x09, 0xF0, 0, 0, 1, 0x67] + w.bytes + [0, 0, 1, 0x68, 0xCE])
    }

    @Test("H.264 の SPS から切り取り後の大きさを読む")
    func h264() {
        #expect(ElementaryStreamFormat.h264Size(Self.highProfileSPS()) == .init(width: 1440, height: 1080))
        #expect(ElementaryStreamFormat.h264Size(Data([0, 0, 1, 0x65, 1, 2, 3])) == nil)
    }

    @Test("MPEG-2 のシーケンスヘッダから大きさを読む")
    func mpeg2() {
        // 1440 = 0x5A0・1080 = 0x438
        let header: [UInt8] = [0xAA, 0, 0, 1, 0xB3, 0x5A, 0x04, 0x38, 0x33, 0xFF]
        #expect(ElementaryStreamFormat.mpeg2SequenceSize(Data(header)) == .init(width: 1440, height: 1080))
        #expect(ElementaryStreamFormat.mpeg2SequenceSize(Data([0, 0, 1, 0x00, 1, 2, 3, 4])) == nil)
    }

    @Test("ADTS のヘッダから AAC の形式を読む")
    func adts() {
        // AAC LC（object 2）・48 kHz（index 3）・ステレオ（2）
        let header: [UInt8] = [0xFF, 0xF1, 0x4C, 0x80, 0x00, 0x1F, 0xFC]
        #expect(ElementaryStreamFormat.adts(Data(header)) == .init(objectType: 2, sampleRate: 48000, channelConfiguration: 2))
        #expect(ElementaryStreamFormat.adts(Data([0x00, 0x01, 0x02, 0x03])) == nil)
    }
}
