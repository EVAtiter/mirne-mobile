/// OS ごとの映像の復号器（iOS / iPadOS 版）。MPEG-2 は FFmpeg で復号する（iOS の VideoToolbox には MPEG-2 の復号器が無い）
enum PlatformVideoDecoder {
    static func mpeg2(onFrame: @escaping @Sendable (DecodedFrame) -> Void) -> any VideoDecoding {
        FFmpegMPEG2VideoDecoder(onFrame: onFrame)
    }
}
