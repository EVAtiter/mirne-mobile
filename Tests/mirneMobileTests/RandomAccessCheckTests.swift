import Foundation
import Testing

// 始められる絵の判定（`MPEG2Parser.isRandomAccess`・`H264Parser.isRandomAccess`）は、PES の頭だけ読む・写さない形にした
// （2026-11-21。CPU の使い道を測って見つけた）。全体を走査する `scan` での判定と、いつも同じ結果になることを確かめる

/// 決まった並びを返す乱数（試験を流すたびに同じ PES を作る）
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

struct RandomAccessCheckTests {
    /// MPEG-2 の部品（開始符号から）
    private static func mpeg2Pieces(_ random: inout SeededGenerator) -> [UInt8] {
        let filler = (0..<Int.random(in: 0...6, using: &random)).map { _ in UInt8.random(in: 1...255, using: &random) }
        switch Int.random(in: 0..<6, using: &random) {
        case 0: return [0, 0, 1, 0xB3, 0x5A, 0x04, 0x38, 0x34] + filler        // シーケンスヘッダ
        case 1: return [0, 0, 1, 0xB5, 0x14, 0x82, 0x00, 0x01] + filler        // シーケンス拡張
        case 2: return [0, 0, 1, 0xB8, 0x00, 0x08, 0x00] + filler              // GOP
        case 3:
            let type = UInt8.random(in: 0...4, using: &random)                   // 0・4 は知らない種類
            return [0, 0, 1, 0x00, 0x01, type << 3] + filler                     // ピクチャヘッダ
        case 4: return [0, 0, 1, UInt8.random(in: 0x01...0xAF, using: &random)] + filler  // スライス
        default: return filler + [0]                                             // 開始符号でない並び
        }
    }

    @Test("MPEG-2：頭だけ読む判定は、全体を走査した判定と同じ（乱数で 5,000 通り）")
    func mpeg2MatchesScan() {
        var random = SeededGenerator(state: 0x2026_1121)
        var outcomes = Set<Bool>()
        for _ in 0..<5_000 {
            var bytes: [UInt8] = []
            for _ in 0..<Int.random(in: 0...8, using: &random) { bytes += Self.mpeg2Pieces(&random) }
            let data = Data(bytes)
            let scanned = MPEG2Parser.scan(data)
            let expected = scanned.sequence != nil && scanned.picture?.codingType == .intra
            #expect(MPEG2Parser.isRandomAccess(data) == expected, "\(bytes)")
            outcomes.insert(expected)
        }
        #expect(outcomes == [true, false])   // 真も偽も試せていること
    }

    /// H.264 の NAL（見出しの 1 バイトから）
    private static func h264Unit(_ random: inout SeededGenerator) -> [UInt8] {
        switch Int.random(in: 0..<8, using: &random) {
        case 0: return [0x67, 0x4D, 0x40, 0x28]                                  // SPS
        case 1: return [0x68, 0xEE, 0x3C, 0x80]                                  // PPS
        case 2: return [0x09, 0xF0]                                              // AUD
        case 3: return [0x06, 0x06, 0x01, 0x84, 0x80]                            // recovery point の SEI
        case 4: return [0x06, 0x05, 0x02, 0xAA, 0xBB, 0x80]                      // ほかの SEI
        case 5: return [0x65, 0b1000_1000, 0x12]                                 // IDR スライス
        case 6:
            // IDR でないスライス：P・B・I・読めない見出し
            let headers: [UInt8] = [0b1100_0000, 0b1010_0000, 0b1011_0000, 0x00]
            return [0x41, headers[Int.random(in: 0..<headers.count, using: &random)], 0x34]
        default: return [0x0C, 0xFF, 0xFF]                                       // フィラー
        }
    }

    @Test("H.264：写さない判定は、全体を走査した判定と同じ（乱数で 5,000 通り）")
    func h264MatchesScan() {
        var random = SeededGenerator(state: 0x0264_1121)
        var outcomes = Set<Bool>()
        for _ in 0..<5_000 {
            var bytes: [UInt8] = []
            for _ in 0..<Int.random(in: 0...7, using: &random) {
                bytes += Bool.random(using: &random) ? [0, 0, 1] : [0, 0, 0, 1]
                bytes += Self.h264Unit(&random)
                if Int.random(in: 0..<4, using: &random) == 0 { bytes += [0, 0] }   // trailing_zero_8bits
            }
            let data = Data(bytes)
            let expected = H264Parser.scan(data).isRandomAccess
            #expect(H264Parser.isRandomAccess(data) == expected, "\(bytes)")
            outcomes.insert(expected)
        }
        #expect(outcomes == [true, false])   // 真も偽も試せていること
    }

    @Test("H.264：試験の素材の ES でも同じ（NAL の境目で切った断片ごと）")
    func h264FixtureMatchesScan() throws {
        for name in ["interlaced_320x240.h264", "progressive_160x96.h264", "bff_opengop_320x240.h264"] {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/video").appendingPathComponent(name)
            let bytes = [UInt8](try Data(contentsOf: url))
            let starts = H264Parser.nalUnits(bytes).map { $0.lowerBound - 3 }
            // 3 つの NAL ごとに切った断片
            for index in stride(from: 0, to: starts.count, by: 3) {
                let end = index + 3 < starts.count ? starts[index + 3] : bytes.count
                let piece = Data(bytes[starts[index]..<end])
                #expect(H264Parser.isRandomAccess(piece) == H264Parser.scan(piece).isRandomAccess)
            }
        }
    }
}
