import CoreVideo
import Foundation
import Synchronization
import Testing

// iOS / iPadOS 版の MPEG-2 の復号（FFmpeg）。iOS の試験のターゲットだけで流す。
// 素材 Fixtures/synthetic_320x240i.m2v は ffmpeg の testsrc2 を mpeg2video で符号化したもの（放送の中身は含まない）：
// 320×240・上のフィールドが先のインターレース・GOP 6・B 2 枚・12 フレーム
@Suite("MPEG-2 の復号（FFmpeg）")
struct FFmpegMPEG2VideoTests {
    /// 素材のフレーム数
    static let fixtureFrames = 12
    /// 29.97 fps の 1 フレーム（90 kHz）
    static let frameDuration90k: Int64 = 3003

    private static func fixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/synthetic_320x240i.m2v")
        return try Data(contentsOf: url)
    }

    /// ES をピクチャごとに切る。シーケンスヘッダ・GOP ヘッダは続くピクチャの側に付ける（PES 1 つ = ピクチャ 1 つの形）
    private static func pictures(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [Int] = []
        var hasPicture = false
        var unitStart: Int?
        var index = 0
        while index + 3 < bytes.count {
            guard bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 else {
                index += 1
                continue
            }
            let code = bytes[index + 3]
            if code == MPEG2StartCode.sequenceHeader || code == MPEG2StartCode.groupOfPictures || code == MPEG2StartCode.picture {
                if unitStart != nil, hasPicture {
                    starts.append(index)
                    unitStart = index
                    hasPicture = false
                } else if unitStart == nil {
                    unitStart = index
                    starts.append(index)
                }
                if code == MPEG2StartCode.picture { hasPicture = true }
            }
            index += 4
        }
        let bounds = starts + [bytes.count]
        return zip(bounds, bounds.dropFirst()).map { data.subdata(in: $0..<$1) }
    }

    @Test("全部のフレームを NV12 で出し、終わりに遅れているフレームも出しきる")
    func decodesAllFrames() throws {
        let frames = Mutex<[DecodedFrame]>([])
        let decoder = FFmpegMPEG2VideoDecoder { frame in frames.withLock { $0.append(frame) } }
        let units = Self.pictures(try Self.fixture())
        #expect(units.count == Self.fixtureFrames)
        for (number, unit) in units.enumerated() {
            decoder.decode(unit, pts: Int64(number) * Self.frameDuration90k, dts: nil, damaged: false)
        }
        decoder.flush()
        let decoded = frames.withLock { $0 }
        #expect(decoded.count == Self.fixtureFrames)
        #expect(decoder.decodeErrors == 0)
        #expect(decoder.skippedBeforeIntra == 0)
        let first = try #require(decoded.first)
        #expect(CVPixelBufferGetPixelFormatType(first.pixelBuffer) == MPEG2VideoDecoder.pixelFormat)
        #expect(CVPixelBufferGetWidth(first.pixelBuffer) == 320)
        #expect(CVPixelBufferGetHeight(first.pixelBuffer) == 240)
        #expect(first.sequence.width == 320)
        #expect(!first.picture.progressiveFrame)
        // 出てきたフレームの PTS は、渡した PTS の組と同じ（表示の順に並べ替えても欠けも重なりも無い）
        let expected = Set((0..<Self.fixtureFrames).map { Int64($0) * Self.frameDuration90k })
        #expect(Set(decoded.map(\.pts)) == expected)
    }

    @Test("始め直すと、次の I まで捨てる")
    func resetWaitsForIntra() throws {
        let count = Mutex(0)
        let decoder = FFmpegMPEG2VideoDecoder { _ in count.withLock { $0 += 1 } }
        let units = Self.pictures(try Self.fixture())
        decoder.decode(units[0], pts: 0, dts: nil, damaged: false)
        decoder.reset()
        // 2 枚目からは I が来るまで捨てる（GOP 6 なので、次の I は 6 枚目のあたり）
        for (number, unit) in units.enumerated().dropFirst() {
            decoder.decode(unit, pts: Int64(number) * Self.frameDuration90k, dts: nil, damaged: false)
        }
        decoder.flush()
        let decodedCount = count.withLock { $0 }
        #expect(decoder.skippedBeforeIntra > 0)
        #expect(decodedCount > 0)
        #expect(decoder.decodeErrors == 0)
    }
}
