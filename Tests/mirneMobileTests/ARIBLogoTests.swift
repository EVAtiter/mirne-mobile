import CoreGraphics
import Foundation
import ImageIO
import Testing

// 局のロゴにパレットを足す。nasne のロゴは PLTE の無いパレット式の PNG なので、
// ARIB の共通固定色を足して、ImageIO で絵として読めるようにする

/// PLTE の無いパレット式の PNG（幅 = 番号の数・高さ 1）を手で作る。IDAT は無圧縮の deflate
private func paletteLessPNG(indices: [UInt8]) -> Data {
    let raw: [UInt8] = [0] + indices   // 行の先頭はフィルタの種類（0 = なし）
    let length = UInt16(raw.count)
    var zlib: [UInt8] = [0x78, 0x01, 0x01, UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8(~length >> 8)]
    zlib += raw
    zlib += ARIBLogo.bigEndian(ZlibStream.adler32(raw))
    let ihdr = ARIBLogo.bigEndian(UInt32(indices.count)) + ARIBLogo.bigEndian(1) + [8, ARIBLogo.indexedColorType, 0, 0, 0]
    return Data(ARIBLogo.signature + ARIBLogo.chunk("IHDR", ihdr) + ARIBLogo.chunk("IDAT", zlib) + ARIBLogo.chunk("IEND", []))
}

/// 絵として読み、各画素の RGBA を返す（読めなければ nil）
private func decodePixels(_ png: Data) -> [[UInt8]]? {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width
    var pixels = [UInt8](repeating: 0, count: width * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: 1))
        return true
    }
    guard drawn else { return nil }
    return stride(from: 0, to: pixels.count, by: 4).map { Array(pixels[$0..<($0 + 4)]) }
}

@Suite("局のロゴのパレット")
struct ARIBLogoTests {
    @Test("共通固定色は 128 色。0〜7 は原色、8 は透明、9〜15 は半分の明るさ、65 からは半透明")
    func commonFixedColors() {
        let colors = ARIBLogo.commonFixedColors
        #expect(colors.count == 128)
        #expect(colors[1] == (255, 0, 0, 255))
        #expect(colors[6] == (0, 255, 255, 255))
        #expect(colors[7] == (255, 255, 255, 255))
        #expect(colors[8].alpha == 0)
        #expect(colors[9] == (170, 0, 0, 255))
        #expect(colors[16] == (0, 0, 85, 255))
        #expect(colors[64] == (255, 255, 170, 255))
        #expect(colors[65] == (255, 0, 0, 128))   // 1 の半透明
        #expect(colors[72] == (170, 0, 0, 128))   // 9 の半透明（8 は飛ばす）
        // 0〜64 の不透明な色に、同じ色は 2 つ無い
        let opaque = colors[0...64].enumerated().filter { $0.offset != ARIBLogo.transparentIndex }
            .map { "\($0.element.red)-\($0.element.green)-\($0.element.blue)" }
        #expect(Set(opaque).count == opaque.count)
    }

    @Test("PLTE の無いパレット式の PNG は、足すと絵として読め、番号の色になる")
    func addsPalette() throws {
        let png = paletteLessPNG(indices: [1, 7, 8])
        #expect(decodePixels(png) == nil)   // このままでは読めない（nasne のロゴと同じ）
        let fixed = ARIBLogo.addingCommonPalette(to: png)
        #expect(ARIBLogo.chunkTypes([UInt8](fixed)) == ["IHDR", "PLTE", "tRNS", "IDAT", "IEND"])
        let pixels = try #require(decodePixels(fixed))
        #expect(pixels[0] == [255, 0, 0, 255])
        #expect(pixels[1] == [255, 255, 255, 255])
        #expect(pixels[2][3] == 0)   // 透明
    }

    @Test("PLTE のある PNG・PNG でないものは、そのまま返す")
    func leavesOthersAlone() {
        let fixed = ARIBLogo.addingCommonPalette(to: paletteLessPNG(indices: [1]))
        #expect(ARIBLogo.addingCommonPalette(to: fixed) == fixed)
        let notPNG = Data("not a png".utf8)
        #expect(ARIBLogo.addingCommonPalette(to: notPNG) == notPNG)
    }

    @Test("CRC-32 は PNG の既知の値")
    func crc() {
        #expect(ARIBLogo.crc32(Array("IEND".utf8)) == 0xAE42_6082)
    }
}
