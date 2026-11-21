// DTCP-IP の楕円曲線の演算に使う多倍長の非負整数。
//
// 外部のライブラリを使わないため自前で書いた。必要な幅は 160 ビットの値と、
// その積の 320 ビットまで。割り算は Knuth の Algorithm D（Hacker's Delight の divmnu の形）、
// 逆元は奇数の法に対する二進の拡張ユークリッド法。

import Foundation

/// 多倍長の非負整数。32 ビットの桁を下位から並べる（先頭の 0 の桁は持たない。0 は空の配列）
struct DTCPBigUInt: Sendable, Hashable, Comparable, CustomStringConvertible {
    private(set) var limbs: [UInt32]

    /// 1 桁のビット数
    private static let limbBits = 32

    init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    init(_ value: UInt64) {
        self.init(limbs: [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)])
    }

    /// 大きい桁が先（ビッグエンディアン）のバイト列から
    init(bytes: some Collection<UInt8>) {
        var result = [UInt32]()
        result.reserveCapacity(bytes.count / 4 + 1)
        var current: UInt32 = 0
        var shift: UInt32 = 0
        for byte in bytes.reversed() {
            current |= UInt32(byte) << shift
            shift += 8
            if shift == 32 {
                result.append(current)
                current = 0
                shift = 0
            }
        }
        if shift > 0 { result.append(current) }
        self.init(limbs: result)
    }

    /// 16 進の文字列から（大文字・小文字どちらでも）。読めなければ nil
    init?(hex: String) {
        guard let bytes = DTCPBytes.fromHex(hex.count.isMultiple(of: 2) ? hex : "0" + hex) else { return nil }
        self.init(bytes: bytes)
    }

    static let zero = DTCPBigUInt(limbs: [])
    static let one = DTCPBigUInt(1)

    private mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    var isZero: Bool { limbs.isEmpty }
    var isOdd: Bool { (limbs.first ?? 0) & 1 == 1 }
    var isEven: Bool { !isOdd }

    var bitLength: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * Self.limbBits + (Self.limbBits - top.leadingZeroBitCount)
    }

    /// ビット `index`（0 が最下位）が立っているか
    func bit(_ index: Int) -> Bool {
        let limb = index / Self.limbBits
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> UInt32(index % Self.limbBits)) & 1 == 1
    }

    /// ちょうど `length` バイトのビッグエンディアンにする。収まらなければ nil
    func bytes(length: Int) -> [UInt8]? {
        guard bitLength <= length * 8 else { return nil }
        var out = [UInt8](repeating: 0, count: length)
        for index in 0..<length {
            let limb = index / 4
            guard limb < limbs.count else { break }
            out[length - 1 - index] = UInt8(truncatingIfNeeded: limbs[limb] >> UInt32((index % 4) * 8))
        }
        return out
    }

    /// 64 ビットに収まるときの値
    var uint64Value: UInt64? {
        guard limbs.count <= 2 else { return nil }
        let low = UInt64(limbs.first ?? 0)
        let high = limbs.count > 1 ? UInt64(limbs[1]) : 0
        return high << 32 | low
    }

    var description: String {
        guard let bytes = bytes(length: max(1, (bitLength + 7) / 8)) else { return "?" }
        return DTCPBytes.hex(bytes)
    }

    // MARK: 比較

    static func < (lhs: DTCPBigUInt, rhs: DTCPBigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
        for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index]
        }
        return false
    }

    // MARK: 足し算・引き算・掛け算

    static func + (lhs: DTCPBigUInt, rhs: DTCPBigUInt) -> DTCPBigUInt {
        let count = max(lhs.limbs.count, rhs.limbs.count)
        var out = [UInt32](repeating: 0, count: count + 1)
        var carry: UInt64 = 0
        for index in 0..<count {
            let a = index < lhs.limbs.count ? UInt64(lhs.limbs[index]) : 0
            let b = index < rhs.limbs.count ? UInt64(rhs.limbs[index]) : 0
            let sum = a + b + carry
            out[index] = UInt32(truncatingIfNeeded: sum)
            carry = sum >> 32
        }
        out[count] = UInt32(carry)
        return DTCPBigUInt(limbs: out)
    }

    /// `lhs - rhs`。`lhs >= rhs` でなければならない
    static func - (lhs: DTCPBigUInt, rhs: DTCPBigUInt) -> DTCPBigUInt {
        precondition(lhs >= rhs, "DTCPBigUInt: 負になる引き算")
        var out = lhs.limbs
        var borrow: UInt64 = 0
        for index in 0..<out.count {
            let a = UInt64(out[index])
            let b = (index < rhs.limbs.count ? UInt64(rhs.limbs[index]) : 0) + borrow
            if a >= b {
                out[index] = UInt32(a - b)
                borrow = 0
            } else {
                out[index] = UInt32(a + (1 << 32) - b)
                borrow = 1
            }
        }
        return DTCPBigUInt(limbs: out)
    }

    static func * (lhs: DTCPBigUInt, rhs: DTCPBigUInt) -> DTCPBigUInt {
        if lhs.isZero || rhs.isZero { return .zero }
        var out = [UInt32](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for i in 0..<lhs.limbs.count {
            let a = UInt64(lhs.limbs[i])
            var carry: UInt64 = 0
            for j in 0..<rhs.limbs.count {
                // (2^32-1)^2 + (2^32-1) + (2^32-1) = 2^64 - 1 なので 64 ビットに収まる
                let t = a * UInt64(rhs.limbs[j]) + UInt64(out[i + j]) + carry
                out[i + j] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
            }
            out[i + rhs.limbs.count] = UInt32(carry)
        }
        return DTCPBigUInt(limbs: out)
    }

    // MARK: シフト

    static func >> (lhs: DTCPBigUInt, bits: Int) -> DTCPBigUInt {
        guard bits > 0 else { return lhs }
        let limbShift = bits / limbBits
        let bitShift = UInt32(bits % limbBits)
        guard limbShift < lhs.limbs.count else { return .zero }
        var out = [UInt32](repeating: 0, count: lhs.limbs.count - limbShift)
        for index in 0..<out.count {
            let low = lhs.limbs[index + limbShift] >> bitShift
            let high = index + limbShift + 1 < lhs.limbs.count && bitShift > 0
                ? lhs.limbs[index + limbShift + 1] << (32 - bitShift) : 0
            out[index] = low | high
        }
        return DTCPBigUInt(limbs: out)
    }

    static func << (lhs: DTCPBigUInt, bits: Int) -> DTCPBigUInt {
        guard bits > 0, !lhs.isZero else { return lhs }
        let limbShift = bits / limbBits
        let bitShift = UInt32(bits % limbBits)
        var out = [UInt32](repeating: 0, count: lhs.limbs.count + limbShift + 1)
        for index in 0..<lhs.limbs.count {
            out[index + limbShift] |= lhs.limbs[index] << bitShift
            if bitShift > 0 {
                out[index + limbShift + 1] |= lhs.limbs[index] >> (32 - bitShift)
            }
        }
        return DTCPBigUInt(limbs: out)
    }

    // MARK: 割り算

    /// 商と余り。`divisor` は 0 でないこと
    static func divMod(_ dividend: DTCPBigUInt, _ divisor: DTCPBigUInt) -> (quotient: DTCPBigUInt, remainder: DTCPBigUInt) {
        precondition(!divisor.isZero, "DTCPBigUInt: 0 で割った")
        if dividend < divisor { return (.zero, dividend) }
        let u = dividend.limbs
        let v = divisor.limbs
        let m = u.count
        let n = v.count

        // 1 桁で割るとき
        if n == 1 {
            let d = UInt64(v[0])
            var q = [UInt32](repeating: 0, count: m)
            var r: UInt64 = 0
            for i in stride(from: m - 1, through: 0, by: -1) {
                let current = r << 32 | UInt64(u[i])
                q[i] = UInt32(current / d)
                r = current % d
            }
            return (DTCPBigUInt(limbs: q), DTCPBigUInt(r))
        }

        // 割る数の最上位の桁の最上位ビットが立つように、両方を左へずらす（Swift のシフトは 32 で 0 になる）
        let s = UInt32(v[n - 1].leadingZeroBitCount)
        var vn = [UInt32](repeating: 0, count: n)
        for i in stride(from: n - 1, to: 0, by: -1) {
            vn[i] = v[i] << s | (s == 0 ? 0 : v[i - 1] >> (32 - s))
        }
        vn[0] = v[0] << s
        var un = [UInt32](repeating: 0, count: m + 1)
        un[m] = s == 0 ? 0 : u[m - 1] >> (32 - s)
        for i in stride(from: m - 1, to: 0, by: -1) {
            un[i] = u[i] << s | (s == 0 ? 0 : u[i - 1] >> (32 - s))
        }
        un[0] = u[0] << s

        let base: UInt64 = 1 << 32
        var q = [UInt32](repeating: 0, count: m - n + 1)
        for j in stride(from: m - n, through: 0, by: -1) {
            // 商の 1 桁を見積もる
            let numerator = UInt64(un[j + n]) << 32 | UInt64(un[j + n - 1])
            var qhat = numerator / UInt64(vn[n - 1])
            var rhat = numerator % UInt64(vn[n - 1])
            while qhat >= base || qhat * UInt64(vn[n - 2]) > (rhat << 32 | UInt64(un[j + n - 2])) {
                qhat -= 1
                rhat += UInt64(vn[n - 1])
                if rhat >= base { break }
            }
            // 掛けて引く
            var borrow: Int64 = 0
            for i in 0..<n {
                let product = qhat * UInt64(vn[i])
                let t = Int64(un[i + j]) - borrow - Int64(product & 0xFFFF_FFFF)
                un[i + j] = UInt32(truncatingIfNeeded: t)
                borrow = Int64(product >> 32) - (t >> 32)
            }
            let t = Int64(un[j + n]) - borrow
            un[j + n] = UInt32(truncatingIfNeeded: t)
            q[j] = UInt32(truncatingIfNeeded: qhat)
            // 引きすぎたら 1 回足し戻す
            if t < 0 {
                q[j] &-= 1
                var carry: UInt64 = 0
                for i in 0..<n {
                    let sum = UInt64(un[i + j]) + UInt64(vn[i]) + carry
                    un[i + j] = UInt32(truncatingIfNeeded: sum)
                    carry = sum >> 32
                }
                un[j + n] = UInt32(truncatingIfNeeded: UInt64(un[j + n]) + carry)
            }
        }
        var r = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            r[i] = un[i] >> s | (s == 0 ? 0 : un[i + 1] << (32 - s))
        }
        return (DTCPBigUInt(limbs: q), DTCPBigUInt(limbs: r))
    }

    static func % (lhs: DTCPBigUInt, rhs: DTCPBigUInt) -> DTCPBigUInt {
        divMod(lhs, rhs).remainder
    }

    static func / (lhs: DTCPBigUInt, rhs: DTCPBigUInt) -> DTCPBigUInt {
        divMod(lhs, rhs).quotient
    }
}

/// 法 `modulus` の上での演算（法は奇数の素数。DTCP の曲線の p と位数 n）
struct DTCPModular: Sendable {
    let modulus: DTCPBigUInt

    func reduce(_ a: DTCPBigUInt) -> DTCPBigUInt { a < modulus ? a : a % modulus }

    /// `a`・`b` は法より小さいこと
    func add(_ a: DTCPBigUInt, _ b: DTCPBigUInt) -> DTCPBigUInt {
        let sum = a + b
        return sum < modulus ? sum : sum - modulus
    }

    /// `a`・`b` は法より小さいこと
    func subtract(_ a: DTCPBigUInt, _ b: DTCPBigUInt) -> DTCPBigUInt {
        a >= b ? a - b : a + modulus - b
    }

    func multiply(_ a: DTCPBigUInt, _ b: DTCPBigUInt) -> DTCPBigUInt {
        (a * b) % modulus
    }

    /// 逆元（二進の拡張ユークリッド法。法が奇数のときに使える）。`a` が 0、または法と互いに素でなければ nil
    func inverse(_ value: DTCPBigUInt) -> DTCPBigUInt? {
        let a = reduce(value)
        guard !a.isZero, modulus.isOdd else { return nil }
        var u = a
        var v = modulus
        var x1 = DTCPBigUInt.one
        var x2 = DTCPBigUInt.zero
        while u != .one && v != .one {
            // 法と互いに素でないと 0 に行き着き、偶数の判定が止まらなくなる
            if u.isZero || v.isZero { return nil }
            while u.isEven {
                u = u >> 1
                x1 = x1.isEven ? x1 >> 1 : (x1 + modulus) >> 1
            }
            while v.isEven {
                v = v >> 1
                x2 = x2.isEven ? x2 >> 1 : (x2 + modulus) >> 1
            }
            if u >= v {
                u = u - v
                x1 = subtract(x1, x2)
            } else {
                v = v - u
                x2 = subtract(x2, x1)
            }
        }
        return u == .one ? reduce(x1) : reduce(x2)
    }
}

/// バイト列と 16 進の変換（名前の衝突を避けるため Data の拡張にしない）
enum DTCPBytes {
    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// 16 進の文字列からバイト列へ。長さが奇数・16 進でない文字があれば nil
    static func fromHex(_ text: String) -> [UInt8]? {
        let characters = Array(text.utf8)
        guard characters.count.isMultiple(of: 2) else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
            default: nil
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = nibble(characters[index]), let low = nibble(characters[index + 1]) else { return nil }
            out.append(high << 4 | low)
            index += 2
        }
        return out
    }

    /// 大きい桁が先のバイト列を 64 ビットの整数に（8 バイトまで）
    static func uint64(_ bytes: some Collection<UInt8>) -> UInt64 {
        bytes.reduce(0) { $0 << 8 | UInt64($1) }
    }
}
