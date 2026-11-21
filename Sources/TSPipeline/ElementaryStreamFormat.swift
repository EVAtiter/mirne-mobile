import Foundation

/// 映像・音声の ES の頭から、形式（解像度・チャンネル数など）を読む。
/// 計測と、再生で H.264 を扱うときの下調べに使う
public enum ElementaryStreamFormat {
    /// 映像の大きさ
    public struct VideoSize: Sendable, Equatable {
        public let width: Int
        public let height: Int
    }

    /// AAC（ADTS）の形式
    public struct AACFormat: Sendable, Equatable {
        /// MPEG-4 の audio object type（2 = AAC LC）
        public let objectType: Int
        public let sampleRate: Int?
        /// channel_configuration（1 = モノラル・2 = ステレオ・6 = 5.1ch。0 は PCE で決まる）
        public let channelConfiguration: Int
    }

    /// MPEG-2 のシーケンスヘッダの開始符号の 4 バイト目
    static let mpeg2SequenceHeaderCode: UInt8 = 0xB3
    /// H.264 の SPS の NAL の種類
    static let h264SPSType: UInt8 = 7
    /// ADTS の sampling_frequency_index の表
    static let adtsSampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    /// PES の本体から MPEG-2 のシーケンスヘッダを探し、大きさを返す
    public static func mpeg2SequenceSize(_ payload: Data) -> VideoSize? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 8 else { return nil }
        for i in 0...(bytes.count - 8)
        where bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 && bytes[i + 3] == mpeg2SequenceHeaderCode {
            let width = Int(bytes[i + 4]) << 4 | Int(bytes[i + 5]) >> 4
            let height = Int(bytes[i + 5] & 0x0F) << 8 | Int(bytes[i + 6])
            return VideoSize(width: width, height: height)
        }
        return nil
    }

    /// PES の本体から H.264 の SPS を探し、切り取り後の大きさを返す
    public static func h264Size(_ payload: Data) -> VideoSize? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 4 else { return nil }
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                let start = i + 3
                if bytes[start] & 0x1F == h264SPSType {
                    // 次の開始符号までが SPS
                    var end = start + 1
                    while end + 2 < bytes.count, !(bytes[end] == 0 && bytes[end + 1] == 0 && bytes[end + 2] == 1) { end += 1 }
                    if end + 2 >= bytes.count { end = bytes.count }
                    return parseSPS(Array(bytes[(start + 1)..<end]))
                }
                i = start
            } else {
                i += 1
            }
        }
        return nil
    }

    /// H.264 の SPS から読んだもの（再生の書式と、描画のフレームレート・アスペクト比に使う）
    public struct H264SequenceParameters: Sendable, Equatable {
        /// 切り取り後の大きさ
        public let size: VideoSize
        /// frame_mbs_only_flag（1 ならフレームだけ＝プログレッシブ。0 ならフィールドを含みうる）
        public let frameMBsOnly: Bool
        /// VUI の画素のアスペクト比（幅, 高さ）。無ければ nil
        public let sampleAspectRatio: (width: Int, height: Int)?
        /// VUI の timing_info から求めたフレームレート（time_scale ÷ (2 × num_units_in_tick)）。無ければ nil
        public let frameRate: Double?
        /// スライスヘッダの frame_num のビット数（log2_max_frame_num_minus4 + 4）
        public var log2MaxFrameNum = 4
        /// mb_adaptive_frame_field_flag（MBAFF。フレームのピクチャの中でマクロブロックの対ごとにフィールドで符号化しうる）
        public var mbAdaptiveFrameField = false
        /// separate_colour_plane_flag（スライスヘッダに colour_plane_id が入る）
        public var separateColourPlane = false
        /// VUI の pic_struct_present_flag（SEI の pic_timing に pic_struct が入る）
        public var picStructPresent = false
        /// HRD があるときの、pic_timing の cpb_removal_delay・dpb_output_delay のビット数。HRD が無ければ nil
        public var hrdDelayLengths: (cpbRemoval: Int, dpbOutput: Int)?

        /// 表示のアスペクト比（幅 ÷ 高さ）
        public var displayAspectRatio: Double {
            let sar = sampleAspectRatio.map { Double($0.width) / Double($0.height) } ?? 1
            return Double(size.width) * sar / Double(size.height)
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.size == rhs.size && lhs.frameMBsOnly == rhs.frameMBsOnly && lhs.frameRate == rhs.frameRate
                && lhs.sampleAspectRatio?.width == rhs.sampleAspectRatio?.width
                && lhs.sampleAspectRatio?.height == rhs.sampleAspectRatio?.height
        }
    }

    /// H.264 の aspect_ratio_idc（1〜16）の画素のアスペクト比。255 は SAR を直に書く
    static let h264SampleAspectRatios: [(Int, Int)] = [
        (1, 1), (12, 11), (10, 11), (16, 11), (40, 33), (24, 11), (20, 11), (32, 11),
        (80, 33), (18, 11), (15, 11), (64, 33), (160, 99), (4, 3), (3, 2), (2, 1),
    ]
    static let h264ExtendedSAR = 255

    /// SPS の本体（NAL の見出しの後）を読み、切り取り後の大きさを返す
    static func parseSPS(_ escaped: [UInt8]) -> VideoSize? {
        parseSPSParameters(escaped)?.size
    }

    /// emulation prevention（00 00 03）を外す
    static func unescapeRBSP(_ escaped: [UInt8]) -> [UInt8] {
        var rbsp = [UInt8]()
        rbsp.reserveCapacity(escaped.count)
        var zeros = 0
        for byte in escaped {
            if zeros >= 2, byte == 3 { zeros = 0; continue }
            rbsp.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return rbsp
    }

    /// SPS の本体（NAL の見出しの後）を読む（VUI のアスペクト比とフレームレートまで）
    public static func parseSPSParameters(_ escaped: [UInt8]) -> H264SequenceParameters? {
        var reader = BitReader(unescapeRBSP(escaped))
        guard let profile = reader.bits(8) else { return nil }
        _ = reader.bits(16)                        // constraint_set のフラグ・level_idc
        _ = reader.ue()                            // seq_parameter_set_id
        var chromaFormat = 1
        var separateColourPlane = false
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            guard let chroma = reader.ue() else { return nil }
            chromaFormat = chroma
            if chroma == 3 { separateColourPlane = reader.bits(1) == 1 }
            _ = reader.ue(); _ = reader.ue()        // bit_depth_luma / chroma
            _ = reader.bits(1)                      // qpprime_y_zero_transform_bypass_flag
            if reader.bits(1) == 1 {                // seq_scaling_matrix_present_flag
                for list in 0..<(chromaFormat != 3 ? 8 : 12) where reader.bits(1) == 1 {
                    skipScalingList(&reader, size: list < 6 ? 16 : 64)
                }
            }
        }
        guard let log2MaxFrameNumMinus4 = reader.ue() else { return nil }
        guard let pocType = reader.ue() else { return nil }
        if pocType == 0 {
            _ = reader.ue()
        } else if pocType == 1 {
            _ = reader.bits(1); _ = reader.se(); _ = reader.se()
            guard let cycle = reader.ue() else { return nil }
            for _ in 0..<cycle { _ = reader.se() }
        }
        _ = reader.ue()                            // max_num_ref_frames
        _ = reader.bits(1)                         // gaps_in_frame_num_value_allowed_flag
        guard let widthInMBs = reader.ue(), let heightInMapUnits = reader.ue(),
              let frameMBsOnly = reader.bits(1) else { return nil }
        let mbAdaptive = frameMBsOnly == 0 ? reader.bits(1) == 1 : false  // mb_adaptive_frame_field_flag
        _ = reader.bits(1)                         // direct_8x8_inference_flag
        var crop = (left: 0, right: 0, top: 0, bottom: 0)
        if reader.bits(1) == 1 {
            guard let l = reader.ue(), let r = reader.ue(), let t = reader.ue(), let b = reader.ue() else { return nil }
            crop = (l, r, t, b)
        }
        let fieldFactor = 2 - frameMBsOnly
        let arrayType = separateColourPlane ? 0 : chromaFormat
        let subWidth = arrayType == 1 || arrayType == 2 ? 2 : 1
        let subHeight = arrayType == 1 ? 2 : 1
        let cropX = arrayType == 0 ? 1 : subWidth
        let cropY = (arrayType == 0 ? 1 : subHeight) * fieldFactor
        let size = VideoSize(width: (widthInMBs + 1) * 16 - cropX * (crop.left + crop.right),
                             height: fieldFactor * (heightInMapUnits + 1) * 16 - cropY * (crop.top + crop.bottom))
        // VUI（無ければ、または読めなければ、大きさだけを返す）
        var sar: (Int, Int)?
        var frameRate: Double?
        var picStructPresent = false
        var hrdDelayLengths: (cpbRemoval: Int, dpbOutput: Int)?
        if reader.bits(1) == 1 {
            if reader.bits(1) == 1, let idc = reader.bits(8) {          // aspect_ratio_info_present_flag
                if idc == h264ExtendedSAR, let w = reader.bits(16), let h = reader.bits(16), w > 0, h > 0 {
                    sar = (w, h)
                } else if (1...h264SampleAspectRatios.count).contains(idc) {
                    sar = h264SampleAspectRatios[idc - 1]
                }
            }
            if reader.bits(1) == 1 { _ = reader.bits(1) }               // overscan_info
            if reader.bits(1) == 1 {                                    // video_signal_type
                _ = reader.bits(4)                                      // video_format・video_full_range_flag
                if reader.bits(1) == 1 { _ = reader.bits(24) }          // colour_description
            }
            if reader.bits(1) == 1 { _ = reader.ue(); _ = reader.ue() } // chroma_loc_info
            if reader.bits(1) == 1, let units = reader.bits(32), let scale = reader.bits(32) {  // timing_info
                if units > 0 { frameRate = Double(scale) / Double(2 * units) }
                _ = reader.bits(1)                                      // fixed_frame_rate_flag
            }
            // HRD（NAL・VCL）。pic_timing の SEI を読むのに、遅れの欄のビット数が要る
            let nalHRD = reader.bits(1) == 1 ? readHRDDelayLengths(&reader) : nil
            let vclHRD = reader.bits(1) == 1 ? readHRDDelayLengths(&reader) : nil
            hrdDelayLengths = nalHRD ?? vclHRD
            if hrdDelayLengths != nil { _ = reader.bits(1) }           // low_delay_hrd_flag
            picStructPresent = reader.bits(1) == 1
        }
        var parameters = H264SequenceParameters(size: size, frameMBsOnly: frameMBsOnly == 1,
                                                sampleAspectRatio: sar.map { (width: $0.0, height: $0.1) }, frameRate: frameRate)
        parameters.log2MaxFrameNum = log2MaxFrameNumMinus4 + 4
        parameters.mbAdaptiveFrameField = mbAdaptive
        parameters.separateColourPlane = separateColourPlane
        parameters.picStructPresent = picStructPresent
        parameters.hrdDelayLengths = hrdDelayLengths
        return parameters
    }

    /// hrd_parameters() を読み飛ばし、cpb_removal_delay・dpb_output_delay のビット数を返す
    private static func readHRDDelayLengths(_ reader: inout BitReader) -> (cpbRemoval: Int, dpbOutput: Int)? {
        guard let cpbCountMinus1 = reader.ue(), cpbCountMinus1 < 32 else { return nil }
        _ = reader.bits(8)                                              // bit_rate_scale・cpb_size_scale
        for _ in 0...cpbCountMinus1 {
            _ = reader.ue(); _ = reader.ue(); _ = reader.bits(1)        // bit_rate・cpb_size・cbr_flag
        }
        _ = reader.bits(5)                                              // initial_cpb_removal_delay_length_minus1
        guard let removal = reader.bits(5), let output = reader.bits(5), reader.bits(5) != nil else { return nil }
        return (removal + 1, output + 1)
    }

    private static func skipScalingList(_ reader: inout BitReader, size: Int) {
        var last = 8, next = 8
        for _ in 0..<size {
            if next != 0 {
                guard let delta = reader.se() else { return }
                next = (last + delta + 256) % 256
            }
            last = next == 0 ? last : next
        }
    }

    /// PES の本体の頭の ADTS ヘッダを読む
    public static func adts(_ payload: Data) -> AACFormat? {
        let bytes = [UInt8](payload.prefix(8))
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] & 0xF0 == 0xF0 else { return nil }
        let index = Int(bytes[2] >> 2) & 0x0F
        return AACFormat(objectType: Int(bytes[2] >> 6) + 1,
                         sampleRate: index < adtsSampleRates.count ? adtsSampleRates[index] : nil,
                         channelConfiguration: Int(bytes[2] & 0x01) << 2 | Int(bytes[3] >> 6))
    }
}

/// ビット単位の読み手（指数ゴロム符号つき）
struct BitReader {
    private let bytes: [UInt8]
    private var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func bits(_ count: Int) -> Int? {
        var value = 0
        for _ in 0..<count {
            guard position < bytes.count * 8 else { return nil }
            let bit = (bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1
            value = value << 1 | Int(bit)
            position += 1
        }
        return value
    }

    /// 符号なしの指数ゴロム符号
    mutating func ue() -> Int? {
        var zeros = 0
        while true {
            guard let bit = bits(1) else { return nil }
            if bit == 1 { break }
            zeros += 1
            if zeros > 31 { return nil }
        }
        guard let rest = bits(zeros) else { return nil }
        return (1 << zeros) - 1 + rest
    }

    /// 符号つきの指数ゴロム符号
    mutating func se() -> Int? {
        guard let code = ue() else { return nil }
        return code % 2 == 1 ? (code + 1) / 2 : -(code / 2)
    }
}
