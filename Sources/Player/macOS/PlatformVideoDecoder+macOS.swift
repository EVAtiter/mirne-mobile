/// OS ごとの映像の復号器（macOS 版）。MPEG-2 は VideoToolbox で復号する
enum PlatformVideoDecoder {
    static func mpeg2(onFrame: @escaping @Sendable (DecodedFrame) -> Void) -> any VideoDecoding {
        MPEG2VideoDecoder(onFrame: onFrame)
    }
}
