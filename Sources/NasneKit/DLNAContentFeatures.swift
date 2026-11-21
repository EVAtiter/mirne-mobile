import Foundation

/// DLNA の 4 番目のフィールド（`contentFeatures.dlna.org` の値、protocolInfo の `:` の後ろ）。
/// シークの可否を決めるのに使う。
///
/// 値の形は DLNA の Guidelines（7.4.1.3）：`;` で区切った `名前=値`。
/// - `DLNA.ORG_OP`：2 桁。1 桁目が時間指定（`TimeSeekRange.dlna.org`）、2 桁目がバイトの範囲（`Range`）に応じるか
/// - `DLNA.ORG_FLAGS`：32 桁の 16 進。先頭の 8 桁（32 ビット）が主なフラグ
/// - `DLNA.ORG_PN`（プロファイル）・`DLNA.ORG_CI`（変換されているか）・`DLNA.ORG_PS`（再生の速さ）
public struct DLNAContentFeatures: Sendable, Equatable {
    /// 名前 → 値（現れた順は捨てる）
    public let fields: [String: String]

    public static let profileField = "DLNA.ORG_PN"
    public static let operationsField = "DLNA.ORG_OP"
    public static let flagsField = "DLNA.ORG_FLAGS"
    public static let conversionField = "DLNA.ORG_CI"
    public static let playSpeedsField = "DLNA.ORG_PS"
    /// 主なフラグの桁数（16 進）
    static let primaryFlagsDigits = 8

    public init(_ value: String) {
        var fields: [String: String] = [:]
        for part in value.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            fields[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        self.fields = fields
    }

    public var profile: String? { fields[Self.profileField] }

    /// 時間指定（`TimeSeekRange.dlna.org`）に応じるか。`DLNA.ORG_OP` が無ければ nil
    public var supportsTimeSeek: Bool? { operationsDigit(0) }
    /// バイトの範囲（`Range`）に応じるか。`DLNA.ORG_OP` が無ければ nil
    public var supportsByteRange: Bool? { operationsDigit(1) }

    private func operationsDigit(_ index: Int) -> Bool? {
        guard let op = fields[Self.operationsField], op.count == 2 else { return nil }
        let digit = op[op.index(op.startIndex, offsetBy: index)]
        return digit == "1"
    }

    /// 主なフラグ（DLNA の Guidelines 7.4.1.3.24 のビットの位置）
    public enum Flag: Int, CaseIterable, Sendable {
        case senderPaced = 31
        case limitedTimeSeek = 30
        case limitedByteSeek = 29
        case playContainer = 28
        case s0Increasing = 27
        case sNIncreasing = 26
        case rtspPause = 25
        case streamingTransfer = 24
        case interactiveTransfer = 23
        case backgroundTransfer = 22
        case connectionStalling = 21
        case dlnaV15 = 20
        case linkProtected = 16
        case clearTextByteFullSeek = 15
        case limitedClearTextByteSeek = 14

        /// 計測の表示に使う DLNA の呼び方（略称）
        public var label: String {
            switch self {
            case .senderPaced: return "sp"
            case .limitedTimeSeek: return "lop-npt"
            case .limitedByteSeek: return "lop-bytes"
            case .playContainer: return "playcontainer"
            case .s0Increasing: return "s0-increasing"
            case .sNIncreasing: return "sN-increasing"
            case .rtspPause: return "rtsp-pause"
            case .streamingTransfer: return "tm-s"
            case .interactiveTransfer: return "tm-i"
            case .backgroundTransfer: return "tm-b"
            case .connectionStalling: return "http-stalling"
            case .dlnaV15: return "dlna-v1.5"
            case .linkProtected: return "link-protected"
            case .clearTextByteFullSeek: return "cleartext-byte-full-seek"
            case .limitedClearTextByteSeek: return "lop-cleartext-bytes"
            }
        }
    }

    /// 立っている主なフラグ。`DLNA.ORG_FLAGS` が無い・読めなければ nil
    public var flags: [Flag]? {
        guard let text = fields[Self.flagsField], text.count >= Self.primaryFlagsDigits,
              let primary = UInt32(text.prefix(Self.primaryFlagsDigits), radix: 16) else { return nil }
        return Flag.allCases.filter { primary & (1 << UInt32($0.rawValue)) != 0 }
    }
}
