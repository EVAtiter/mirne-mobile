import CoreMedia
import CoreVideo
import Foundation
import os
import VideoToolbox

// H.264（nasne の 3倍・モバイルの録画とライブ）の復号。mirne mobile で足したもの（mirne には無い）。
//
// 描画（VideoRenderer・FrameQueue）は MPEG-2 の言葉（MPEG2Sequence・MPEG2PictureInfo）でフレームを受け取るので、
// SPS から読んだ大きさ・フレームレート・アスペクト比・プログレッシブかどうかを、その形に写して渡す。

/// 映像の復号器（PlayerEngine が PMT の stream_type で選ぶ）
public protocol VideoDecoding: AnyObject, Sendable {
    /// 1 つの PES（1 アクセスユニット）を渡す。`pts` は巻き戻りを解いた値
    func decode(_ payload: Data, pts: Int64, dts: Int64?, damaged: Bool)
    /// 復号途中のものを捨てて、最初のランダムアクセスの点から始め直す
    func reset()
    /// 送ったものの復号が終わるまで待つ
    func flush()
    /// 復号の失敗の数
    var decodeErrors: Int { get }
    /// 欠けたまま復号に回したピクチャの数
    var damagedPictures: Int { get }
    /// 最初のランダムアクセスの点より前で捨てたピクチャの数
    var skippedBeforeIntra: Int { get }
}

extension MPEG2VideoDecoder: VideoDecoding {}

/// 映像の符号化方式ごとの、圧縮のままでの見分け
enum VideoCodec {
    /// その PES から復号を始められるか（PlayerEngine が溜めた映像の切り詰めと、始める点の選びに使う）
    static func isRandomAccess(_ payload: Data, streamType: UInt8) -> Bool {
        switch streamType {
        case ElementaryStream.h264:
            return H264Parser.isRandomAccess(payload)
        default:
            return MPEG2Parser.isRandomAccess(payload)
        }
    }
}

/// H.264 の NAL ユニットの種類（nal_unit_type）
enum H264NALType {
    static let nonIDRSlice: UInt8 = 1
    static let idrSlice: UInt8 = 5
    static let sei: UInt8 = 6
    static let sps: UInt8 = 7
    static let pps: UInt8 = 8
    static let accessUnitDelimiter: UInt8 = 9
    static let endOfSequence: UInt8 = 10
    static let endOfStream: UInt8 = 11
    static let fillerData: UInt8 = 12
    /// nal_unit_type を取り出すマスク
    static let typeMask: UInt8 = 0x1F
    /// SEI の payloadType のうち、recovery point（ここから復号すれば正しい絵になる点）
    static let recoveryPointPayload = 6
}

/// 1 つの PES（Annex B のバイト列）を NAL ユニットに分けて読んだもの
struct H264AccessUnit {
    /// SPS・PPS の本体（NAL の見出しの 1 バイトを含む）
    var sps: [UInt8]?
    var pps: [UInt8]?
    /// 最初のスライスの種類
    var codingType: MPEG2PictureInfo.CodingType?
    var isIDR = false
    var hasRecoveryPoint = false
    /// 復号器へ送る NAL ユニット（スライスと SEI。SPS・PPS・AUD・フィラーなどは除く）
    var units: [[UInt8]] = []

    /// ここから復号を始められるか（IDR・recovery point の SEI・SPS 付きの I スライス）
    var isRandomAccess: Bool {
        isIDR || hasRecoveryPoint || (sps != nil && codingType == .intra)
    }
}

enum H264Parser {
    /// Annex B のバイト列を NAL ユニット（開始符号を除き、後ろの 0 を落とした範囲）に分ける
    static func nalUnits<Bytes: RandomAccessCollection<UInt8>>(_ bytes: Bytes) -> [Range<Int>] where Bytes.Index == Int {
        var starts: [Int] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }
        var ranges: [Range<Int>] = []
        for (index, start) in starts.enumerated() {
            var end = index + 1 < starts.count ? starts[index + 1] - 3 : bytes.count
            // 次の開始符号の前の 0（4 バイトの開始符号の頭・trailing_zero_8bits）を落とす
            while end > start, bytes[end - 1] == 0 { end -= 1 }
            if end > start { ranges.append(start..<end) }
        }
        return ranges
    }

    /// PES を NAL ユニットに分けて読む。PES の全体は写さず、NAL ごとに 1 回だけ配列へ写す
    static func scan(_ data: Data) -> H264AccessUnit {
        data.withUnsafeBytes { raw in scan(raw.bindMemory(to: UInt8.self)) }
    }

    private static func scan(_ bytes: UnsafeBufferPointer<UInt8>) -> H264AccessUnit {
        var unit = H264AccessUnit()
        for range in nalUnits(bytes) {
            let nal = Array(bytes[range])
            let type = nal[0] & H264NALType.typeMask
            switch type {
            case H264NALType.sps:
                unit.sps = nal
            case H264NALType.pps:
                unit.pps = nal
            case H264NALType.accessUnitDelimiter, H264NALType.endOfSequence, H264NALType.endOfStream,
                 H264NALType.fillerData:
                break
            case H264NALType.nonIDRSlice, H264NALType.idrSlice:
                if type == H264NALType.idrSlice { unit.isIDR = true }
                if unit.codingType == nil { unit.codingType = sliceCodingType(nal) }
                unit.units.append(nal)
            case H264NALType.sei:
                if seiHasRecoveryPoint(nal) { unit.hasRecoveryPoint = true }
                unit.units.append(nal)
            default:
                unit.units.append(nal)
            }
        }
        return unit
    }

    /// ここから復号を始められるか（`scan(_:).isRandomAccess` と同じ結果）。
    ///
    /// 圧縮のまま溜める映像の PES ごとに呼ぶ（`PlayerEngine`）。`scan` は PES の全体と NAL ごとに配列へ写すが、
    /// 判定に要るのは NAL の種類と、最初のスライスの見出し・SEI の中身だけなので、写すのはそこだけにする
    static func isRandomAccess(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var sawSPS = false
            /// 最初に読めたスライスの種類（`scan` と同じく、読めなかったスライスは飛ばして次で読む）
            var firstSliceType: MPEG2PictureInfo.CodingType?
            for range in nalUnits(bytes) {
                let type = bytes[range.lowerBound] & H264NALType.typeMask
                switch type {
                case H264NALType.idrSlice:
                    return true
                case H264NALType.nonIDRSlice:
                    if firstSliceType == nil {
                        // slice_type は見出しの頭（16 バイトまで）にある（`sliceCodingType` と同じ量を写す）
                        firstSliceType = sliceCodingType(Array(bytes[range.lowerBound..<min(range.upperBound, range.lowerBound + 17)]))
                    }
                case H264NALType.sei:
                    if seiHasRecoveryPoint(Array(bytes[range])) { return true }
                case H264NALType.sps:
                    sawSPS = true
                default:
                    break
                }
            }
            return sawSPS && firstSliceType == .intra
        }
    }

    /// スライスヘッダの slice_type（0・5 = P、1・6 = B、2・7 = I、3・8 = SP、4・9 = SI）
    static func sliceCodingType(_ nal: [UInt8]) -> MPEG2PictureInfo.CodingType? {
        var reader = BitReader(ElementaryStreamFormat.unescapeRBSP(Array(nal.dropFirst().prefix(16))))
        _ = reader.ue()   // first_mb_in_slice
        guard let sliceType = reader.ue() else { return nil }
        switch sliceType % 5 {
        case 0, 3: return .predicted
        case 1: return .bidirectional
        default: return .intra
        }
    }

    /// SEI に recovery point（payloadType 6）があるか
    static func seiHasRecoveryPoint(_ nal: [UInt8]) -> Bool {
        let rbsp = ElementaryStreamFormat.unescapeRBSP(Array(nal.dropFirst()))
        var i = 0
        while i < rbsp.count, rbsp[i] != 0x80 {
            var payloadType = 0
            while i < rbsp.count, rbsp[i] == 0xFF { payloadType += 255; i += 1 }
            guard i < rbsp.count else { return false }
            payloadType += Int(rbsp[i]); i += 1
            var payloadSize = 0
            while i < rbsp.count, rbsp[i] == 0xFF { payloadSize += 255; i += 1 }
            guard i < rbsp.count else { return false }
            payloadSize += Int(rbsp[i]); i += 1
            if payloadType == H264NALType.recoveryPointPayload { return true }
            i += payloadSize
        }
        return false
    }

    /// NAL ユニットを、4 バイトの長さを前に付けた形（AVCC）につなぐ
    static func lengthPrefixed(_ units: [[UInt8]]) -> Data {
        var out = Data()
        out.reserveCapacity(units.reduce(0) { $0 + $1.count + H264VideoDecoder.nalLengthSize })
        for unit in units {
            let length = UInt32(unit.count)
            out.append(contentsOf: [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
            out.append(contentsOf: unit)
        }
        return out
    }
}

/// H.264 の SPS を、描画が読む MPEG-2 の言葉に写す
enum H264FrameDescription {
    /// MPEG-2 の frame_rate_code と、そのフレームレート（`MPEG2FrameRate` の表と同じ）
    static let frameRateCodes: [(code: UInt8, rate: Double)] = [
        (1, 24000.0 / 1001), (2, 24), (3, 25), (4, 30000.0 / 1001), (5, 30), (6, 50), (7, 60000.0 / 1001), (8, 60),
    ]
    /// フレームレートが分からないときの frame_rate_code（29.97。日本の放送）
    static let defaultFrameRateCode: UInt8 = 4
    /// 表示のアスペクト比を 16:9・4:3 と見なす許容の幅
    static let aspectTolerance = 0.02
    /// MPEG-2 の aspect_ratio_information（2 = 4:3、3 = 16:9、1 = 画素が正方形）
    static let aspect4x3: UInt8 = 2
    static let aspect16x9: UInt8 = 3
    static let aspectSquare: UInt8 = 1

    static func sequence(_ parameters: ElementaryStreamFormat.H264SequenceParameters) -> MPEG2Sequence {
        let rateCode = parameters.frameRate.flatMap { rate in
            frameRateCodes.min { abs($0.rate - rate) < abs($1.rate - rate) }?.code
        } ?? defaultFrameRateCode
        let aspect = parameters.displayAspectRatio
        let aspectCode: UInt8
        if abs(aspect - 16.0 / 9.0) < aspectTolerance {
            aspectCode = aspect16x9
        } else if abs(aspect - 4.0 / 3.0) < aspectTolerance {
            aspectCode = aspect4x3
        } else {
            aspectCode = aspectSquare
        }
        return MPEG2Sequence(width: parameters.size.width, height: parameters.size.height, aspectRatioCode: aspectCode,
                             frameRateCode: rateCode, progressiveSequence: parameters.frameMBsOnly)
    }
}

/// H.264 を VideoToolbox で復号する。
///
/// - SPS・PPS が届くまで、そして最初のランダムアクセスの点（IDR・recovery point・SPS 付きの I）まで捨てる
/// - SPS・PPS が変わったら、セッションを作り直す
/// - 欠けた PES も、MPEG-2 と同じく復号に回す（止めるより崩れを見せる。MPEG2VideoDecoder の方針と揃える）
/// - フィールドの順は、PES の中のフィールドのピクチャの並び（PAFF）か、SEI の pic_struct（フレームのピクチャ）で決める。
///   どちらも無ければ上のフィールドが先と見なす。nasne の 3倍は PAFF で、PES ごとに上・下のフィールドが 1 枚ずつ入る（2026-11-20 実測）
public final class H264VideoDecoder: VideoDecoding, @unchecked Sendable {
    public typealias FrameHandler = @Sendable (DecodedFrame) -> Void

    /// AVCC の長さのバイト数
    static let nalLengthSize = 4

    private let onFrame: FrameHandler
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var sequence: MPEG2Sequence?
    /// いまの SPS から読んだもの（スライスヘッダと pic_timing を読むのに使う）
    private var parameters: ElementaryStreamFormat.H264SequenceParameters?
    private var waitingForRandomAccess = true
    private let logger = Logger(subsystem: AppLog.subsystem, category: "video")

    private let pendingLock = NSLock()
    private var pending: [Int: PendingH264Frame] = [:]
    private var nextToken = 1
    private let countersLock = NSLock()
    private var errors = 0

    public private(set) var skippedBeforeIntra = 0
    public private(set) var damagedPictures = 0
    public var decodeErrors: Int { countersLock.withLock { errors } }

    public init(onFrame: @escaping FrameHandler) {
        self.onFrame = onFrame
    }

    deinit {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    public func decode(_ payload: Data, pts: Int64, dts: Int64?, damaged: Bool) {
        let unit = H264Parser.scan(payload)
        var parameterSetsChanged = false
        if let newSPS = unit.sps, newSPS != sps { sps = newSPS; parameterSetsChanged = true }
        if let newPPS = unit.pps, newPPS != pps { pps = newPPS; parameterSetsChanged = true }
        if parameterSetsChanged || session == nil, sps != nil, pps != nil {
            rebuildSession()
        }
        guard session != nil, let sequence, let codingType = unit.codingType, !unit.units.isEmpty else { return }
        if waitingForRandomAccess {
            guard unit.isRandomAccess else {
                skippedBeforeIntra += 1
                return
            }
            waitingForRandomAccess = false
        }
        if damaged { damagedPictures += 1 }
        var picture = MPEG2PictureInfo(codingType: codingType, temporalReference: 0)
        picture.progressiveFrame = sequence.progressiveSequence
        if !sequence.progressiveSequence, let parameters {
            picture.topFieldFirst = H264Parser.topFieldFirst(H264Parser.layout(unit.units, parameters: parameters))
        }
        submit(H264Parser.lengthPrefixed(unit.units), pts: pts, dts: dts, sequence: sequence, picture: picture)
    }

    public func reset() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
        waitingForRandomAccess = true
    }

    public func flush() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
    }

    // MARK: - VideoToolbox

    private func rebuildSession() {
        guard let sps, let pps, let parameters = ElementaryStreamFormat.parseSPSParameters(Array(sps.dropFirst())) else { return }
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        waitingForRandomAccess = true
        self.parameters = parameters
        let newSequence = H264FrameDescription.sequence(parameters)
        logger.info("H.264 の SPS: \(newSequence.width, privacy: .public)×\(newSequence.height, privacy: .public)・プログレッシブ \(parameters.frameMBsOnly, privacy: .public)")
        sequence = newSequence

        var description: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBufferPointer { spsPointer in
            pps.withUnsafeBufferPointer { ppsPointer in
                let pointers = [spsPointer.baseAddress!, ppsPointer.baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: Int32(Self.nalLengthSize), formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else {
            logger.error("H.264 の書式記述を作れなかった: \(status, privacy: .public)")
            return
        }
        formatDescription = description

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: MPEG2VideoDecoder.pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { decoderReference, frameReference, status, _, imageBuffer, _, _ in
                guard let decoderReference else { return }
                let decoder = Unmanaged<H264VideoDecoder>.fromOpaque(decoderReference).takeUnretainedValue()
                guard let pending = decoder.takePending(Int(bitPattern: frameReference)) else { return }
                guard status == noErr, let imageBuffer else {
                    decoder.recordError(status)
                    return
                }
                decoder.onFrame(DecodedFrame(pixelBuffer: imageBuffer, pts: pending.pts,
                                             sequence: pending.sequence, picture: pending.picture))
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        var created: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(allocator: nil, formatDescription: description,
                                                        decoderSpecification: nil,
                                                        imageBufferAttributes: attributes as CFDictionary,
                                                        outputCallback: &callback, decompressionSessionOut: &created)
        if createStatus != noErr {
            logger.error("H.264 の VTDecompressionSessionCreate が失敗した: \(createStatus, privacy: .public)")
        }
        session = created
    }

    private func submit(_ sampleData: Data, pts: Int64, dts: Int64?, sequence: MPEG2Sequence, picture: MPEG2PictureInfo) {
        guard let session, let formatDescription else { return }
        var block: CMBlockBuffer?
        let length = sampleData.count
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: length,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else { return }
        sampleData.withUnsafeBytes {
            _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: pts, timescale: 90_000),
                                        decodeTimeStamp: dts.map { CMTime(value: $0, timescale: 90_000) } ?? .invalid)
        var size = length
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: formatDescription,
                                  sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                  sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard let sample else { return }

        pendingLock.lock()
        let token = nextToken
        nextToken += 1
        pending[token] = PendingH264Frame(pts: pts, sequence: sequence, picture: picture)
        pendingLock.unlock()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                                                       flags: [._EnableAsynchronousDecompression],
                                                       frameRefcon: UnsafeMutableRawPointer(bitPattern: token),
                                                       infoFlagsOut: nil)
        if status != noErr, takePending(token) != nil {
            recordError(status)
        }
    }

    fileprivate func takePending(_ token: Int) -> PendingH264Frame? {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pending.removeValue(forKey: token)
    }

    fileprivate func recordError(_ status: OSStatus) {
        countersLock.withLock { errors += 1 }
        logger.debug("H.264 の復号に失敗した: \(status, privacy: .public)")
    }
}

/// 復号に出したフレームのメタデータ
private struct PendingH264Frame {
    let pts: Int64
    let sequence: MPEG2Sequence
    let picture: MPEG2PictureInfo
}

// MARK: - ピクチャの組み方（フィールド・pic_struct）

/// 1 つの PES の中のピクチャの組み方。スライスヘッダの field_pic_flag と、SEI の pic_timing の pic_struct から読む
struct H264PictureLayout: Equatable {
    enum Kind: Equatable { case frame, topField, bottomField }
    /// PES の中のピクチャ（first_mb_in_slice が 0 のスライスごと。PAFF ならフィールドが 2 つ並びうる）
    var pictures: [Kind] = []
    /// SEI の pic_struct（0 フレーム・1 上・2 下・3 上下・4 下上・5 上下上・6 下上下・7 2 倍・8 3 倍）。SEI ごとに 1 つ
    var picStructs: [Int] = []
}

extension H264Parser {
    /// SEI の payloadType のうち pic_timing
    static let picTimingPayload = 1

    /// PES の中のピクチャの組み方を読む（SPS が要る：frame_num の長さ・frame_mbs_only・HRD・pic_struct の有無）
    static func layout(_ data: Data, parameters: ElementaryStreamFormat.H264SequenceParameters) -> H264PictureLayout {
        layout(scan(data).units, parameters: parameters)
    }

    /// `scan` で分けた NAL ユニット（`H264AccessUnit.units`）から、ピクチャの組み方を読む。
    /// 読むのはスライスと SEI だけで、どちらも `units` に入っている。復号器は `scan` の結果を使い回し、PES を分け直さない（2026-11-21）
    static func layout(_ units: [[UInt8]], parameters: ElementaryStreamFormat.H264SequenceParameters) -> H264PictureLayout {
        var layout = H264PictureLayout()
        for nal in units where nal.count > 1 {
            switch nal[0] & H264NALType.typeMask {
            case H264NALType.nonIDRSlice, H264NALType.idrSlice:
                if let kind = slicePictureKind(nal, parameters: parameters) { layout.pictures.append(kind) }
            case H264NALType.sei:
                if let value = picStruct(nal, parameters: parameters) { layout.picStructs.append(value) }
            default:
                break
            }
        }
        return layout
    }

    /// 上のフィールドが先か。PAFF なら PES の中で先に来たフィールド、フレームのピクチャなら pic_struct の 4（下上）・6（下上下）で下が先。
    /// どちらも分からなければ上が先（日本の放送の 1080i）
    static func topFieldFirst(_ layout: H264PictureLayout) -> Bool {
        if let first = layout.pictures.first, first != .frame { return first == .topField }
        if let value = layout.picStructs.first { return value != picStructBottomTop && value != picStructBottomTopBottom }
        return true
    }

    /// pic_struct の 4（下・上の順に表示）と 6（下・上・下）
    static let picStructBottomTop = 4
    static let picStructBottomTopBottom = 6

    /// ピクチャの最初のスライス（first_mb_in_slice が 0）なら、フレームか上・下のフィールドかを返す。続きのスライスは nil
    static func slicePictureKind(_ nal: [UInt8], parameters: ElementaryStreamFormat.H264SequenceParameters) -> H264PictureLayout.Kind? {
        var reader = BitReader(ElementaryStreamFormat.unescapeRBSP(Array(nal.dropFirst().prefix(32))))
        guard reader.ue() == 0,                       // first_mb_in_slice
              reader.ue() != nil, reader.ue() != nil  // slice_type・pic_parameter_set_id
        else { return nil }
        if parameters.separateColourPlane { _ = reader.bits(2) }   // colour_plane_id
        guard reader.bits(parameters.log2MaxFrameNum) != nil else { return nil }  // frame_num
        guard !parameters.frameMBsOnly else { return .frame }
        guard let field = reader.bits(1) else { return nil }        // field_pic_flag
        guard field == 1 else { return .frame }
        guard let bottom = reader.bits(1) else { return nil }       // bottom_field_flag
        return bottom == 1 ? .bottomField : .topField
    }

    /// SEI の pic_timing の pic_struct。SPS が pic_struct を載せないと言っていれば nil
    static func picStruct(_ nal: [UInt8], parameters: ElementaryStreamFormat.H264SequenceParameters) -> Int? {
        guard parameters.picStructPresent else { return nil }
        let rbsp = ElementaryStreamFormat.unescapeRBSP(Array(nal.dropFirst()))
        var i = 0
        while i < rbsp.count, rbsp[i] != 0x80 {
            var payloadType = 0
            while i < rbsp.count, rbsp[i] == 0xFF { payloadType += 255; i += 1 }
            guard i < rbsp.count else { return nil }
            payloadType += Int(rbsp[i]); i += 1
            var payloadSize = 0
            while i < rbsp.count, rbsp[i] == 0xFF { payloadSize += 255; i += 1 }
            guard i < rbsp.count else { return nil }
            payloadSize += Int(rbsp[i]); i += 1
            if payloadType == picTimingPayload {
                var reader = BitReader(Array(rbsp[i..<min(rbsp.count, i + payloadSize)]))
                if let lengths = parameters.hrdDelayLengths {
                    _ = reader.bits(lengths.cpbRemoval); _ = reader.bits(lengths.dpbOutput)
                }
                return reader.bits(4)
            }
            i += payloadSize
        }
        return nil
    }
}

/// H.264 の流れの組み方を数える（計測コマンドの `stream` が使う。復号はしない）
struct H264StructureSurvey {
    private(set) var parameters: ElementaryStreamFormat.H264SequenceParameters?
    private(set) var accessUnits = 0
    /// PES の中のピクチャの組み方（"F" フレーム・"T" 上・"B" 下を並べたもの）ごとの数
    private(set) var layouts: [String: Int] = [:]
    /// pic_struct の値ごとの数（SEI が無い・SPS が載せないと言っているものは -1）
    private(set) var picStructs: [Int: Int] = [:]
    private(set) var idr = 0
    private(set) var recoveryPoints = 0
    private(set) var intra = 0
    /// ランダムアクセスの点の間隔（PES の数）
    private(set) var gopLengths: [Int] = []
    /// ランダムアクセスの点の後に、復号の順で続く B のうち、その点より前に表示するもの（open GOP の頭）
    private(set) var leadingPictures: [Int] = []
    private var sinceRandomAccess: Int?
    private var randomAccessPTS: Int64?
    private var leadingInThisGOP = 0
    private var countingLeading = false

    mutating func add(_ payload: Data, pts: Int64?) {
        let unit = H264Parser.scan(payload)
        if let sps = unit.sps, let parsed = ElementaryStreamFormat.parseSPSParameters(Array(sps.dropFirst())) {
            parameters = parsed
        }
        guard let parameters, let codingType = unit.codingType else { return }
        accessUnits += 1
        let layout = H264Parser.layout(unit.units, parameters: parameters)
        let key = layout.pictures.map { kind -> String in
            switch kind { case .frame: "F"; case .topField: "T"; case .bottomField: "B" }
        }.joined()
        layouts[key.isEmpty ? "?" : key, default: 0] += 1
        if layout.picStructs.isEmpty {
            picStructs[-1, default: 0] += 1
        } else {
            for value in layout.picStructs { picStructs[value, default: 0] += 1 }
        }
        if unit.isIDR { idr += 1 }
        if unit.hasRecoveryPoint { recoveryPoints += 1 }
        if codingType == .intra { intra += 1 }

        if unit.isRandomAccess {
            if let since = sinceRandomAccess { gopLengths.append(since) }
            if countingLeading { leadingPictures.append(leadingInThisGOP) }
            sinceRandomAccess = 1
            randomAccessPTS = pts
            leadingInThisGOP = 0
            countingLeading = true
            return
        }
        sinceRandomAccess = sinceRandomAccess.map { $0 + 1 }
        guard countingLeading else { return }
        if codingType == .bidirectional, let pts, let randomAccessPTS, pts < randomAccessPTS {
            leadingInThisGOP += 1
        } else if codingType != .bidirectional {
            // 次の I・P が来たら、この GOP の頭の B は終わり
            leadingPictures.append(leadingInThisGOP)
            countingLeading = false
        }
    }
}
