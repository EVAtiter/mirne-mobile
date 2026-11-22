// MPEG-2 Video を FFmpeg（libavcodec の mpeg2video の復号器）で復号する。iOS / iPadOS 版だけ。
// iOS の VideoToolbox には MPEG-2 の映像の復号器が無い（macOS には VideoToolbox のソフトウェアの復号器がある）。
// FFmpeg は LGPL-2.1 のまま組み、動的なフレームワークで同梱する（組み方は scripts/build-ffmpeg-ios.sh）

import Accelerate
import CFFmpegMPEG2
import CoreVideo
import Foundation
import os

/// FFmpeg で復号する MPEG-2 の復号器。どのピクチャを回すかは macOS 版と同じ `MPEG2PictureGate` で決める。
///
/// - `avcodec_send_packet` / `avcodec_receive_frame` を同期で回す。パケットの pts に番号を入れ、出てきたフレーム
///   （表示の順）から元の PTS・シーケンス・ピクチャの情報を引き当てる
/// - 出力の yuv420p（3 平面）を、描画が読む NV12（2 平面・ビデオレンジ）の `CVPixelBuffer` へ並べ替える
/// - シーケンス（大きさ・アスペクト比）が変わったら、復号器を作り直す
public final class FFmpegMPEG2VideoDecoder: VideoDecoding, @unchecked Sendable {
    public typealias FrameHandler = @Sendable (DecodedFrame) -> Void

    /// 復号の並列の数（フレームとスライスの並列）。iPad Air（M3）で、1440×1080i の DR を 1 コアの約 4% で復号できた（2026-11-22 実測）
    static let decoderThreads: Int32 = 4

    private let onFrame: FrameHandler
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    private var sequence: MPEG2Sequence?
    private var gate = MPEG2PictureGate()
    private let logger = Logger(subsystem: AppLog.subsystem, category: "video")

    /// 復号に出したフレームのメタデータ。FFmpeg には番号だけを渡し、出てきたフレームの pts で引き当てる
    private var pending: [Int64: PendingPicture] = [:]
    private var nextToken: Int64 = 1

    public var skippedBeforeIntra: Int { gate.skippedBeforeIntra }
    public var skippedLeadingB: Int { gate.skippedLeadingB }
    public var damagedPictures: Int { gate.damagedPictures }
    public private(set) var decodeErrors = 0

    public init(onFrame: @escaping FrameHandler) {
        self.onFrame = onFrame
    }

    deinit {
        var context = codecContext
        avcodec_free_context(&context)
        av_packet_free(&packet)
        av_frame_free(&frame)
    }

    /// 1 つの PES（1 ピクチャ）を渡す。`pts` は巻き戻りを解いた値
    public func decode(_ payload: Data, pts: Int64, dts: Int64?, damaged: Bool) {
        let scanned = MPEG2Parser.scan(payload)
        if let newSequence = scanned.sequence, newSequence != sequence {
            logger.info("シーケンスが変わった: \(newSequence.width, privacy: .public)×\(newSequence.height, privacy: .public)")
            rebuild(for: newSequence)
        }
        guard let picture = scanned.picture, let sequence else { return }
        guard gate.admit(picture, hasSequenceHeader: scanned.sequence != nil, damaged: damaged) else { return }
        submit(payload, pts: pts, sequence: sequence, picture: picture)
    }

    /// 選局し直したときなど、復号途中のものを捨てて最初の I から始め直す
    public func reset() {
        if let codecContext { avcodec_flush_buffers(codecContext) }
        pending.removeAll()
        gate.restart()
    }

    /// 並列の復号で遅れているフレームを出しきる（録画の終わりなど）。出しきった後は最初の I から始め直す
    public func flush() {
        guard let codecContext else { return }
        if avcodec_send_packet(codecContext, nil) >= 0 {
            receiveFrames()
        }
        avcodec_flush_buffers(codecContext)
        pending.removeAll()
        gate.restart()
    }

    // MARK: - FFmpeg

    private func rebuild(for newSequence: MPEG2Sequence) {
        var old = codecContext
        avcodec_free_context(&old)
        codecContext = nil
        sequence = newSequence
        gate.restart()
        pending.removeAll()
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_MPEG2VIDEO), let context = avcodec_alloc_context3(codec) else {
            logger.error("FFmpeg の mpeg2video の復号器を用意できない")
            return
        }
        context.pointee.thread_count = Self.decoderThreads
        context.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE
        let status = avcodec_open2(context, codec, nil)
        guard status >= 0 else {
            logger.error("avcodec_open2 が失敗した: \(status, privacy: .public)")
            var failed: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&failed)
            return
        }
        codecContext = context
        if packet == nil { packet = av_packet_alloc() }
        if frame == nil { frame = av_frame_alloc() }
    }

    private func submit(_ payload: Data, pts: Int64, sequence: MPEG2Sequence, picture: MPEG2PictureInfo) {
        guard let codecContext, let packet else { return }
        let token = nextToken
        nextToken += 1
        pending[token] = PendingPicture(pts: pts, sequence: sequence, picture: picture)
        guard av_new_packet(packet, Int32(payload.count)) >= 0 else {
            pending.removeValue(forKey: token)
            decodeErrors += 1
            return
        }
        payload.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(packet.pointee.data, base, payload.count) }
        }
        packet.pointee.pts = token
        let sent = avcodec_send_packet(codecContext, packet)
        av_packet_unref(packet)
        if sent < 0 {
            pending.removeValue(forKey: token)
            decodeErrors += 1
            logger.debug("FFmpeg に渡せなかった: \(sent, privacy: .public)")
        }
        receiveFrames()
    }

    /// 出てきたフレームを全部受け取って渡す
    private func receiveFrames() {
        guard let codecContext, let frame else { return }
        while avcodec_receive_frame(codecContext, frame) >= 0 {
            defer { av_frame_unref(frame) }
            guard let meta = pending.removeValue(forKey: frame.pointee.pts) else { continue }
            guard let buffer = makePixelBuffer(frame) else {
                decodeErrors += 1
                continue
            }
            onFrame(DecodedFrame(pixelBuffer: buffer, pts: meta.pts, sequence: meta.sequence, picture: meta.picture))
        }
        // 出てこなかった（捨てられた）ピクチャのメタデータが溜まり続けないように、古いものを捨てる
        if pending.count > Self.pendingLimit {
            let keep = Set(pending.keys.sorted().suffix(Self.pendingLimit))
            pending = pending.filter { keep.contains($0.key) }
        }
    }

    /// 出てくる前のピクチャのメタデータを持つ上限（並列の数と B の並びより十分大きく）
    static let pendingLimit = 64

    /// yuv420p（3 平面）を NV12（2 平面・ビデオレンジ）へ並べ替える
    private func makePixelBuffer(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        guard frame.pointee.format == AV_PIX_FMT_YUV420P.rawValue, width > 0, height > 0 else { return nil }
        if pixelBufferPool == nil || poolSize != (width, height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: MPEG2VideoDecoder.pixelFormat,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            pixelBufferPool = pool
            poolSize = (width, height)
        }
        guard let pixelBufferPool else { return nil }
        var created: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &created)
        guard let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let dstY = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let dstCbCr = CVPixelBufferGetBaseAddressOfPlane(buffer, 1),
              let srcY = frame.pointee.data.0, let srcCb = frame.pointee.data.1, let srcCr = frame.pointee.data.2 else { return nil }
        let dstYStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let dstCbCrStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let lineY = Int(frame.pointee.linesize.0)
        for row in 0..<height {
            memcpy(dstY + row * dstYStride, srcY + row * lineY, width)
        }
        // Cb と Cr の 2 平面を、1 画素 2 バイトの交互の並びへ
        let chromaWidth = vImagePixelCount(width / 2)
        let chromaHeight = vImagePixelCount(height / 2)
        var planeCb = vImage_Buffer(data: srcCb, height: chromaHeight, width: chromaWidth, rowBytes: Int(frame.pointee.linesize.1))
        var planeCr = vImage_Buffer(data: srcCr, height: chromaHeight, width: chromaWidth, rowBytes: Int(frame.pointee.linesize.2))
        let status = withUnsafePointer(to: &planeCb) { cb in
            withUnsafePointer(to: &planeCr) { cr in
                var sources: [UnsafePointer<vImage_Buffer>?] = [cb, cr]
                var destinations: [UnsafeMutableRawPointer?] = [dstCbCr, dstCbCr + 1]
                return vImageConvert_PlanarToChunky8(&sources, &destinations, 2, 2, chromaWidth, chromaHeight,
                                                     dstCbCrStride, vImage_Flags(kvImageNoFlags))
            }
        }
        return status == kvImageNoError ? buffer : nil
    }
}

/// 復号に出したピクチャのメタデータ
private struct PendingPicture {
    let pts: Int64
    let sequence: MPEG2Sequence
    let picture: MPEG2PictureInfo
}
