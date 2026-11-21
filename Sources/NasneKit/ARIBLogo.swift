import Foundation

// 局のロゴの PNG にパレットを足す。
//
// nasne の `channelLogoDataGet` のロゴは 64×36・8 ビットのパレット式（色の型 3）だが、パレット（PLTE）が無い
// （チャンクは IHDR・IDAT・IEND だけ。2026-11-19 実機・31 件すべて）。地上デジタルのロゴは、受信機が持つ
// ARIB の共通固定色（ARIB STD-B24 の 128 色）を使う前提で、パレットを省いて送られる。
// このままでは macOS（ImageIO）は絵として読めないので、IHDR のすぐ後に共通固定色の PLTE と、透明度の tRNS を差し込む。

public enum ARIBLogo {
    /// 共通固定色（128 色の RGBA）。
    ///
    /// - 0〜7：R・G・B を 0 か 255 にした 8 色（番号の 1 の位が R、2 の位が G、4 の位が B）
    /// - 8：透明
    /// - 9〜15：0〜7 の 255 を 170 にした 7 色（黒を除く）
    /// - 16〜64：R・G・B を 0・85・170・255 にした 64 通りのうち、上に出ていない 49 色を (R, G, B) の小さい順に
    /// - 65〜127：1〜7 と 9〜64 の 63 色を、半透明（不透明度 128）にしたもの
    public static let commonFixedColors: [(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)] = {
        typealias Color = (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)
        func primary(_ index: Int, level: UInt8) -> Color {
            (index & 1 != 0 ? level : 0, index & 2 != 0 ? level : 0, index & 4 != 0 ? level : 0, opaque)
        }
        var colors: [Color] = (0..<8).map { primary($0, level: 255) }
        colors.append((0, 0, 0, 0))
        colors += (1..<8).map { primary($0, level: 170) }
        let levels: [UInt8] = [0, 85, 170, 255]
        for red in levels {
            for green in levels {
                for blue in levels where !colors.contains(where: { $0.red == red && $0.green == green && $0.blue == blue }) {
                    colors.append((red, green, blue, opaque))
                }
            }
        }
        let halfTransparent = colors.enumerated().filter { $0.offset != 0 && $0.offset != transparentIndex }
            .map { Color($0.element.red, $0.element.green, $0.element.blue, translucent) }
        return colors + halfTransparent
    }()

    static let opaque: UInt8 = 255
    /// 65〜127 の不透明度（半透明）
    static let translucent: UInt8 = 128
    /// 透明の番号
    static let transparentIndex = 8
    /// 色の型「パレット式」（PNG の IHDR）
    static let indexedColorType: UInt8 = 3
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    /// 署名（8）+ IHDR のチャンク（長さ 4・種類 4・中身 13・CRC 4）
    static let endOfHeader = 8 + 4 + 4 + 13 + 4

    /// パレット式で PLTE の無い PNG に、共通固定色の PLTE と tRNS を足す。それ以外（PLTE がある・パレット式でない・
    /// PNG でない）は、そのまま返す
    public static func addingCommonPalette(to png: Data) -> Data {
        let bytes = [UInt8](png)
        guard bytes.count >= endOfHeader, bytes.starts(with: signature),
              Array(bytes[12..<16]) == Array("IHDR".utf8), bytes[25] == indexedColorType,
              !chunkTypes(bytes).contains("PLTE") else { return png }
        let colors = commonFixedColors
        var output = Array(bytes[..<endOfHeader])
        output += chunk("PLTE", colors.flatMap { [$0.red, $0.green, $0.blue] })
        output += chunk("tRNS", colors.map(\.alpha))
        output += bytes[endOfHeader...]
        return Data(output)
    }

    /// チャンクの種類の並び（署名の後から）
    static func chunkTypes(_ bytes: [UInt8]) -> [String] {
        var types: [String] = []
        var offset = signature.count
        while offset + 8 <= bytes.count {
            let length = bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
            types.append(String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self))
            offset += 12 + length
        }
        return types
    }

    /// チャンク（長さ・種類・中身・CRC）
    static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let body = Array(type.utf8) + data
        return bigEndian(UInt32(data.count)) + body + bigEndian(crc32(body))
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    /// PNG の CRC-32（多項式 0xEDB88320）
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }
}
