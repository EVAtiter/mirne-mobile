import CoreVideo
import Foundation
import Synchronization
import Testing

// H.264 の復号と、録画の再生の部品。
// 素材 Fixtures/video/*.h264 は ffmpeg の testsrc2 を libx264 で符号化したもの（放送の中身は含まない）：
// - progressive_160x96.h264：Main・B フレーム 2 枚・IDR が 6 フレームごと・12 フレーム
// - interlaced_320x240.h264：High・MBAFF（上のフィールドが先）・IDR が 4 フレームごと・8 フレーム

/// SPS（NAL の見出しを含む 16 進）。ffmpeg の testsrc2 を libx264 で符号化した合成の TS から取り出したもの
private enum SampleSPS {
    /// 1440×1080・インターレース・SAR 4:3・29.97（nasne の 3倍に近い形）
    static let interlaced1080 = "67640028acd9405a044fde1c2000007d20001d4c03e2c5b2c0"
    /// 720×480・プログレッシブ・SAR 32:27・29.97（nasne のモバイルに近い形）
    static let progressive480 = "674d401eeca05a1edff8010000d8800001f480007530078b16cb"
}

private func bytes(hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        out.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return out
}

/// Annex B の ES をアクセスユニット（1 ピクチャ）ごとの Annex B に分ける（試験用）。
/// スライスの後に SPS・PPS・SEI・AUD が来るか、first_mb_in_slice が 0 のスライスが来たら、次のピクチャ
private func accessUnits(_ data: Data) -> [Data] {
    let all = [UInt8](data)
    var units: [Data] = []
    var current = Data()
    var hasSlice = false
    for range in H264Parser.nalUnits(all) {
        let nal = Array(all[range])
        let type = nal[0] & H264NALType.typeMask
        let isSlice = type == H264NALType.nonIDRSlice || type == H264NALType.idrSlice
        var reader = BitReader(Array(nal.dropFirst().prefix(4)))
        let startsPicture = isSlice ? reader.ue() == 0 : [H264NALType.sps, H264NALType.pps, H264NALType.sei, H264NALType.accessUnitDelimiter].contains(type)
        if hasSlice, startsPicture {
            units.append(current)
            current = Data()
            hasSlice = false
        }
        current.append(contentsOf: [0, 0, 0, 1])
        current.append(contentsOf: nal)
        if isSlice { hasSlice = true }
    }
    if hasSlice { units.append(current) }
    return units
}

/// 復号したフレームを集める
private final class FrameCollector: Sendable {
    private let frames = Mutex<[DecodedFrame]>([])
    func add(_ frame: DecodedFrame) { frames.withLock { $0.append(frame) } }
    var all: [DecodedFrame] { frames.withLock { $0 } }
}

@Suite("H.264 の読み方")
struct H264ParserTests {
    @Test("3 バイト・4 バイトの開始符号で分け、後ろの 0 を落とす")
    func splitsNALUnits() {
        let stream: [UInt8] = [0, 0, 0, 1, 0x09, 0xF0, 0, 0, 1, 0x67, 0x42, 0x1E, 0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00]
        let ranges = H264Parser.nalUnits(stream)
        #expect(ranges.map { stream[$0].first } == [0x09, 0x67, 0x65])
        #expect(ranges.map(\.count) == [2, 3, 3])
    }

    @Test("SPS・PPS を取り、AUD は送らず、IDR はランダムアクセスの点")
    func scansAccessUnit() {
        // AUD・SPS・PPS・IDR（first_mb 0・slice_type 7 = I）
        let payload = Data([0, 0, 0, 1, 0x09, 0x10, 0, 0, 0, 1, 0x67, 0x4D, 0x40, 0x1E, 0, 0, 0, 1, 0x68, 0xEE, 0x3C, 0x80,
                            0, 0, 1, 0x65, 0b1000_1000, 0x84])
        let unit = H264Parser.scan(payload)
        #expect(unit.sps == [0x67, 0x4D, 0x40, 0x1E])
        #expect(unit.pps == [0x68, 0xEE, 0x3C, 0x80])
        #expect(unit.isIDR && unit.isRandomAccess)
        #expect(unit.codingType == .intra)
        #expect(unit.units.count == 1)
        #expect(unit.units[0].first == 0x65)
    }

    @Test("slice_type を I・P・B に分ける（0〜4 と 5〜9 の両方）")
    func sliceTypes() {
        // first_mb_in_slice = 0（"1"）に続く slice_type の ue：0 = "1"、1 = "010"、2 = "011"、5 = "00110"、6 = "00111"
        #expect(H264Parser.sliceCodingType([0x41, 0b1100_0000]) == .predicted)
        #expect(H264Parser.sliceCodingType([0x01, 0b1010_0000]) == .bidirectional)
        #expect(H264Parser.sliceCodingType([0x41, 0b1011_0000]) == .intra)
        #expect(H264Parser.sliceCodingType([0x41, 0b1001_1000]) == .predicted)
        #expect(H264Parser.sliceCodingType([0x01, 0b1001_1100]) == .bidirectional)
    }

    @Test("SEI の recovery point を見つける。ほかの SEI だけなら見つけない")
    func recoveryPoint() {
        // payloadType 5（user data unregistered、長さ 2）の後に payloadType 6（長さ 1）
        #expect(H264Parser.seiHasRecoveryPoint([0x06, 0x05, 0x02, 0xAA, 0xBB, 0x06, 0x01, 0x84, 0x80]))
        #expect(!H264Parser.seiHasRecoveryPoint([0x06, 0x05, 0x02, 0xAA, 0xBB, 0x80]))
        // recovery point の SEI と P スライスの PES は、SPS が無くてもランダムアクセスの点
        let payload = Data([0, 0, 1, 0x06, 0x06, 0x01, 0x84, 0x80, 0, 0, 1, 0x41, 0b1100_0000])
        #expect(H264Parser.scan(payload).isRandomAccess)
        #expect(!H264Parser.scan(Data([0, 0, 1, 0x41, 0b1100_0000])).isRandomAccess)
    }

    @Test("4 バイトの長さを付けてつなぐ（AVCC）")
    func lengthPrefixed() {
        let data = H264Parser.lengthPrefixed([[0x65, 0x01], [0x06, 0x02, 0x03]])
        #expect([UInt8](data) == [0, 0, 0, 2, 0x65, 0x01, 0, 0, 0, 3, 0x06, 0x02, 0x03])
    }

    @Test("SPS の VUI から SAR とフレームレートを読み、描画の MPEG-2 の言葉に写す（1440×1080i・16:9）")
    func interlacedSequence() throws {
        let parameters = try #require(ElementaryStreamFormat.parseSPSParameters(Array(bytes(hex: SampleSPS.interlaced1080).dropFirst())))
        #expect(parameters.size == .init(width: 1440, height: 1080))
        #expect(!parameters.frameMBsOnly)
        #expect(parameters.sampleAspectRatio?.width == 4 && parameters.sampleAspectRatio?.height == 3)
        #expect(abs((parameters.frameRate ?? 0) - 30000.0 / 1001) < 0.001)
        let sequence = H264FrameDescription.sequence(parameters)
        #expect(sequence.aspectRatioCode == H264FrameDescription.aspect16x9)
        #expect(sequence.frameRateCode == 4)
        #expect(!sequence.progressiveSequence)
    }

    @Test("720×480p・SAR 32:27 も 16:9 になる")
    func progressiveSequence() throws {
        let parameters = try #require(ElementaryStreamFormat.parseSPSParameters(Array(bytes(hex: SampleSPS.progressive480).dropFirst())))
        #expect(parameters.size == .init(width: 720, height: 480))
        #expect(parameters.frameMBsOnly)
        #expect(parameters.sampleAspectRatio?.width == 32 && parameters.sampleAspectRatio?.height == 27)
        let sequence = H264FrameDescription.sequence(parameters)
        #expect(sequence.aspectRatioCode == H264FrameDescription.aspect16x9)
        #expect(sequence.progressiveSequence)
    }

    @Test("PMT の映像は MPEG-2 と H.264 の両方。圧縮のままのランダムアクセスの見分けを方式で替える")
    func programMapVideo() {
        let h264 = ProgramMap(programNumber: 1, version: 0, pcrPID: 0x100, streams: [
            ElementaryStream(pid: 0x100, streamType: ElementaryStream.h264, componentTag: nil),
        ])
        #expect(h264.video?.pid == 0x100)
        let idr = Data([0, 0, 1, 0x67, 0x4D, 0, 0, 1, 0x65, 0b1000_1000])
        #expect(VideoCodec.isRandomAccess(idr, streamType: ElementaryStream.h264))
        #expect(!VideoCodec.isRandomAccess(idr, streamType: ElementaryStream.mpeg2Video))
    }
}

@Suite("H.264 の復号（VideoToolbox）")
struct H264DecoderTests {
    @Test("プログレッシブ・B フレームつきの 12 フレームを全部復号し、大きさとプログレッシブを渡す")
    func decodesProgressive() throws {
        let units = accessUnits(NasneFixture.data("video/progressive_160x96.h264"))
        #expect(units.count == 12)
        let collector = FrameCollector()
        let decoder = H264VideoDecoder { collector.add($0) }
        for (index, unit) in units.enumerated() {
            let time = Int64(index) * 3003
            decoder.decode(unit, pts: time, dts: time, damaged: false)
        }
        decoder.flush()
        let frames = collector.all
        #expect(frames.count == 12)
        #expect(decoder.decodeErrors == 0)
        let first = try #require(frames.first)
        #expect(first.sequence.width == 160 && first.sequence.height == 96)
        #expect(first.sequence.progressiveSequence && first.picture.progressiveFrame)
        #expect(CVPixelBufferGetWidth(first.pixelBuffer) == 160)
        #expect(CVPixelBufferGetPixelFormatType(first.pixelBuffer) == MPEG2VideoDecoder.pixelFormat)
    }

    @Test("MBAFF のインターレースも復号し、プログレッシブでないと渡す（描画がデインターレースする）")
    func decodesInterlaced() throws {
        let units = accessUnits(NasneFixture.data("video/interlaced_320x240.h264"))
        let collector = FrameCollector()
        let decoder = H264VideoDecoder { collector.add($0) }
        for (index, unit) in units.enumerated() {
            decoder.decode(unit, pts: Int64(index) * 3003, dts: Int64(index) * 3003, damaged: false)
        }
        decoder.flush()
        let frames = collector.all
        #expect(frames.count == units.count)
        let first = try #require(frames.first)
        #expect(first.sequence.width == 320 && first.sequence.height == 240)
        #expect(!first.sequence.progressiveSequence && !first.picture.progressiveFrame)
        #expect(first.picture.topFieldFirst)
    }

    @Test("最初の IDR より前のピクチャは捨て、reset の後も次の IDR まで捨てる")
    func waitsForRandomAccess() {
        let units = accessUnits(NasneFixture.data("video/progressive_160x96.h264"))
        let collector = FrameCollector()
        let decoder = H264VideoDecoder { collector.add($0) }
        // SPS・PPS・IDR の入った最初のピクチャを飛ばして、2 枚目から渡す（IDR は 6 枚目ごと）
        for (index, unit) in units.enumerated().dropFirst() {
            decoder.decode(unit, pts: Int64(index) * 3003, dts: Int64(index) * 3003, damaged: false)
        }
        decoder.flush()
        // SPS・PPS は 6 枚目の IDR と一緒に届く。それより前の 5 枚は書式が無いので数えずに捨てる
        #expect(collector.all.count == 6)
        decoder.reset()
        decoder.decode(units[7], pts: 0, dts: 0, damaged: false)
        decoder.flush()
        #expect(collector.all.count == 6)
        #expect(decoder.skippedBeforeIntra == 1)
    }
}

/// 合成の素材 Fixtures/video/bff_opengop_320x240.h264 をアクセスユニットに分け、表示の時刻を付ける。
/// ffmpeg の testsrc2 を libx264 で符号化したもの：High・MBAFF・下のフィールドが先・pic_struct の SEI・NAL の HRD・
/// open GOP（IDR の後、7 枚目は recovery point の SEI 付きの I）・B フレーム 2 枚（b-adapt 0）・12 フレーム。
/// ES には時刻が無いので、復号の順 I0 P3 B1 B2 | I6 B4 B5 P9 B7 B8 P11 B10 の表示の番号から付ける
/// （TS で持つと .gitignore の `*.ts` に当たる。放送の素材を置き間違えないための決まりなので変えない）
private func openGOPVideoPES() -> [(payload: Data, pts: Int64)] {
    let displayOrder: [Int64] = [0, 3, 1, 2, 6, 4, 5, 9, 7, 8, 11, 10]
    let units = accessUnits(NasneFixture.data("video/bff_opengop_320x240.h264"))
    return zip(units, displayOrder).map { ($0, $1 * 3003) }
}

@Suite("H.264 のピクチャの組み方")
struct H264PictureLayoutTests {
    @Test("SPS から frame_num の長さ・MBAFF・HRD の遅れの長さ・pic_struct の有無を読む")
    func sequenceTiming() throws {
        let first = try #require(openGOPVideoPES().first)
        let sps = try #require(H264Parser.scan(first.payload).sps)
        let parameters = try #require(ElementaryStreamFormat.parseSPSParameters(Array(sps.dropFirst())))
        #expect(parameters.size == .init(width: 320, height: 240))
        #expect(!parameters.frameMBsOnly && parameters.mbAdaptiveFrameField)
        #expect(parameters.picStructPresent)
        #expect(parameters.hrdDelayLengths != nil)
        // HRD の無い素材（libx264 はインターレースなら pic_struct を載せる）は、遅れの欄を読まずに pic_struct を読む
        let units = accessUnits(NasneFixture.data("video/interlaced_320x240.h264"))
        let firstUnit = try #require(units.first)
        let plainSPS = try #require(H264Parser.scan(firstUnit).sps)
        let plain = try #require(ElementaryStreamFormat.parseSPSParameters(Array(plainSPS.dropFirst())))
        #expect(plain.picStructPresent && plain.hrdDelayLengths == nil)
        #expect(units.map { H264Parser.layout($0, parameters: plain).picStructs } == Array(repeating: [3], count: units.count))
    }

    @Test("scan で分けた NAL から読んだ組み方は、PES を分け直して読んだものと同じ（2026-11-21）")
    func layoutFromScannedUnits() throws {
        var pieces = openGOPVideoPES().map(\.payload)
        pieces += accessUnits(NasneFixture.data("video/interlaced_320x240.h264"))
        var parameters: ElementaryStreamFormat.H264SequenceParameters?
        var checked = 0
        for payload in pieces {
            if let sps = H264Parser.scan(payload).sps {
                parameters = ElementaryStreamFormat.parseSPSParameters(Array(sps.dropFirst()))
            }
            let parameters = try #require(parameters)
            // 分け直して読む形（2026-11-21 より前の layout）
            let bytes = [UInt8](payload)
            var reference = H264PictureLayout()
            for range in H264Parser.nalUnits(bytes) where range.count > 1 {
                let nal = Array(bytes[range])
                switch nal[0] & H264NALType.typeMask {
                case H264NALType.nonIDRSlice, H264NALType.idrSlice:
                    if let kind = H264Parser.slicePictureKind(nal, parameters: parameters) { reference.pictures.append(kind) }
                case H264NALType.sei:
                    if let value = H264Parser.picStruct(nal, parameters: parameters) { reference.picStructs.append(value) }
                default:
                    break
                }
            }
            #expect(H264Parser.layout(H264Parser.scan(payload).units, parameters: parameters) == reference)
            checked += 1
        }
        #expect(checked > 12)
    }

    @Test("MBAFF のピクチャはフレーム。pic_struct は下上（4）")
    func layoutOfMBAFF() throws {
        let packets = openGOPVideoPES()
        #expect(packets.count == 12)
        var parameters: ElementaryStreamFormat.H264SequenceParameters?
        for packet in packets {
            if let sps = H264Parser.scan(packet.payload).sps {
                parameters = ElementaryStreamFormat.parseSPSParameters(Array(sps.dropFirst()))
            }
            let layout = H264Parser.layout(packet.payload, parameters: try #require(parameters))
            #expect(layout.pictures == [.frame])
            #expect(layout.picStructs == [4])
        }
    }

    @Test("流れを数える：IDR 1・recovery point 1・open GOP の頭の B")
    func survey() {
        var survey = H264StructureSurvey()
        for unit in openGOPVideoPES() { survey.add(unit.payload, pts: unit.pts) }
        #expect(survey.idr == 1)
        #expect(survey.recoveryPoints == 1)
        #expect(survey.layouts == ["F": survey.accessUnits])
        #expect(survey.picStructs == [4: survey.accessUnits])
        // 復号の順は I0 P3 B1 B2 | I6 B4 B5 P9 …なので、ランダムアクセスの点の間は 4 つ
        #expect(survey.gopLengths == [4])
        // IDR の後の B は IDR より後に表示する（閉じた頭）。recovery point の I の後の 2 枚は I より前に表示する
        #expect(survey.leadingPictures.first == 0)
        #expect(survey.leadingPictures.dropFirst().first == 2)
    }

    @Test("フィールドの順：PAFF は先に来たフィールド、フレームは pic_struct。下が先の素材は下が先で渡す")
    func fieldOrder() throws {
        #expect(H264Parser.topFieldFirst(.init(pictures: [.topField, .bottomField], picStructs: [1, 2])))
        #expect(!H264Parser.topFieldFirst(.init(pictures: [.bottomField, .topField], picStructs: [2, 1])))
        #expect(H264Parser.topFieldFirst(.init(pictures: [.frame], picStructs: [3])))
        #expect(!H264Parser.topFieldFirst(.init(pictures: [.frame], picStructs: [4])))
        #expect(H264Parser.topFieldFirst(.init(pictures: [.frame], picStructs: [])))

        let packets = openGOPVideoPES()
        let collector = FrameCollector()
        let decoder = H264VideoDecoder { collector.add($0) }
        for (index, packet) in packets.enumerated() {
            decoder.decode(packet.payload, pts: packet.pts, dts: Int64(index) * 3003, damaged: false)
        }
        decoder.flush()
        let frames = collector.all
        #expect(frames.count == packets.count)
        #expect(decoder.decodeErrors == 0)
        #expect(frames.allSatisfy { !$0.picture.topFieldFirst && !$0.picture.progressiveFrame })
    }
}
