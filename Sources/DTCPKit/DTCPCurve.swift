// DTCP-IP の楕円曲線・ECDSA（SHA-1、RFC 6979 の決定的な署名）・ECDH。
//
// 出典: torne mobile HB（MIT、© mar1mo-41414）の lib/core/dtcp/dtcp_crypto.dart。
// その元は pydtcpip（MIT、© tsukumijima、https://github.com/tsukumijima/pydtcpip）の dtcp/crypto.py。
// 曲線のパラメータ・署名の作り方は pydtcpip のもの（実機で検証済み）で、既知答テストで pydtcpip に揃えてある。
//
// torne mobile HB からの変更: 点の演算をヤコビ座標で行い、逆元はスカラー倍の最後に 1 回だけ取る
// （アフィン座標のままだと点の足し算ごとに逆元が要る）。結果のアフィン座標は同じ。

import CryptoKit
import Foundation
import Security

/// DTCP の楕円曲線（Fp 上、160 ビット級。寸法が近い SECP160R1 とは別物）
enum DTCPCurve {
    static let p = DTCPBigUInt(hex: "94A8E16AAD4F50EFE29B9D5C0C0B6D481B27DE53")!
    static let a = DTCPBigUInt(hex: "94A8E16AAD4F50EFE29B9D5C0C0B6D481B27DE50")!
    static let b = DTCPBigUInt(hex: "04FD918E5B0C4513FA3EF3033FE08F07C3B08C76D")!
    static let order = DTCPBigUInt(hex: "02278C8AD247A46B5C53DE4CC9A0072488F028A3")!
    static let generator = DTCPPoint(
        x: DTCPBigUInt(hex: "078668913DEAB22759E587EB393D7DA46CE24B196")!,
        y: DTCPBigUInt(hex: "4D2BA996A7E3D9AF4D266AFE00443B95D6870606")!
    )

    /// 座標・スカラーのバイト数
    static let size = 20

    static let field = DTCPModular(modulus: p)
    static let scalars = DTCPModular(modulus: order)
}

/// 曲線上の点（アフィン座標。無限遠点は Optional の nil で表す）
struct DTCPPoint: Sendable, Hashable {
    let x: DTCPBigUInt
    let y: DTCPBigUInt

    var isOnCurve: Bool {
        let f = DTCPCurve.field
        let lhs = f.multiply(y, y)
        let rhs = f.add(f.add(f.multiply(f.multiply(x, x), x), f.multiply(DTCPCurve.a, x)), f.reduce(DTCPCurve.b))
        return lhs == rhs
    }

    /// 証明書・AKE のペイロードで使う 40 バイトの X || Y
    var bytes: [UInt8] {
        x.bytes(length: DTCPCurve.size)! + y.bytes(length: DTCPCurve.size)!
    }

    /// 40 バイトの X || Y から。曲線に載っていなければ nil
    init?(bytes: some Collection<UInt8>) {
        let array = Array(bytes)
        guard array.count == DTCPCurve.size * 2 else { return nil }
        let x = DTCPBigUInt(bytes: array[0..<DTCPCurve.size])
        let y = DTCPBigUInt(bytes: array[DTCPCurve.size...])
        guard x < DTCPCurve.p, y < DTCPCurve.p else { return nil }
        self.init(x: x, y: y)
        guard isOnCurve else { return nil }
    }

    init(x: DTCPBigUInt, y: DTCPBigUInt) {
        self.x = x
        self.y = y
    }

    /// スカラー倍（スカラーは位数で割った余りを使う。torne mobile HB・pydtcpip と同じ）。結果が無限遠点なら nil
    func multiplied(by scalar: DTCPBigUInt) -> DTCPPoint? {
        let k = DTCPCurve.scalars.reduce(scalar)
        guard !k.isZero else { return nil }
        let base = JacobianPoint(self)
        var result = JacobianPoint.infinity
        for index in stride(from: k.bitLength - 1, through: 0, by: -1) {
            result = result.doubled()
            if k.bit(index) { result = result.adding(base) }
        }
        return result.affine
    }

    /// 2 点の和（どちらかが nil なら無限遠点として扱う）
    static func sum(_ lhs: DTCPPoint?, _ rhs: DTCPPoint?) -> DTCPPoint? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return JacobianPoint(lhs).adding(JacobianPoint(rhs)).affine
    }
}

/// ヤコビ座標の点 (X, Y, Z)。アフィン座標は (X/Z², Y/Z³)。Z = 0 は無限遠点
private struct JacobianPoint {
    let x: DTCPBigUInt
    let y: DTCPBigUInt
    let z: DTCPBigUInt

    static let infinity = JacobianPoint(x: .one, y: .one, z: .zero)

    init(x: DTCPBigUInt, y: DTCPBigUInt, z: DTCPBigUInt) {
        self.x = x
        self.y = y
        self.z = z
    }

    init(_ point: DTCPPoint) {
        self.init(x: point.x, y: point.y, z: .one)
    }

    var isInfinity: Bool { z.isZero }

    var affine: DTCPPoint? {
        guard !isInfinity, let zInverse = DTCPCurve.field.inverse(z) else { return nil }
        let f = DTCPCurve.field
        let zInverse2 = f.multiply(zInverse, zInverse)
        let zInverse3 = f.multiply(zInverse2, zInverse)
        return DTCPPoint(x: f.multiply(x, zInverse2), y: f.multiply(y, zInverse3))
    }

    /// 2 倍（一般の a に対する式）
    func doubled() -> JacobianPoint {
        if isInfinity || y.isZero { return .infinity }
        let f = DTCPCurve.field
        let xx = f.multiply(x, x)
        let yy = f.multiply(y, y)
        let yyyy = f.multiply(yy, yy)
        let zz = f.multiply(z, z)
        let s = f.multiply(Constants.four, f.multiply(x, yy))
        let m = f.add(f.multiply(Constants.three, xx), f.multiply(DTCPCurve.a, f.multiply(zz, zz)))
        let x3 = f.subtract(f.multiply(m, m), f.add(s, s))
        let y3 = f.subtract(f.multiply(m, f.subtract(s, x3)), f.multiply(Constants.eight, yyyy))
        let z3 = f.multiply(f.add(y, y), z)
        return JacobianPoint(x: x3, y: y3, z: z3)
    }

    func adding(_ other: JacobianPoint) -> JacobianPoint {
        if isInfinity { return other }
        if other.isInfinity { return self }
        let f = DTCPCurve.field
        let z1z1 = f.multiply(z, z)
        let z2z2 = f.multiply(other.z, other.z)
        let u1 = f.multiply(x, z2z2)
        let u2 = f.multiply(other.x, z1z1)
        let s1 = f.multiply(f.multiply(y, other.z), z2z2)
        let s2 = f.multiply(f.multiply(other.y, z), z1z1)
        if u1 == u2 {
            // 同じ x 座標：同じ点なら 2 倍、互いに逆の点なら無限遠点
            return s1 == s2 ? doubled() : .infinity
        }
        let h = f.subtract(u2, u1)
        let r = f.subtract(s2, s1)
        let hh = f.multiply(h, h)
        let hhh = f.multiply(h, hh)
        let v = f.multiply(u1, hh)
        let x3 = f.subtract(f.subtract(f.multiply(r, r), hhh), f.add(v, v))
        let y3 = f.subtract(f.multiply(r, f.subtract(v, x3)), f.multiply(s1, hhh))
        let z3 = f.multiply(f.multiply(z, other.z), h)
        return JacobianPoint(x: x3, y: y3, z: z3)
    }

    /// 2 倍・足し算の式に出てくる小さな係数
    private enum Constants {
        static let three = DTCPBigUInt(3)
        static let four = DTCPBigUInt(4)
        static let eight = DTCPBigUInt(8)
    }
}

/// ECDSA（SHA-1）と ECDH。python-ecdsa（pydtcpip が使う）と同じ結果を出す
enum DTCPSignature {
    /// SHA-1 の出力のバイト数（RFC 6979 の holen）
    private static let digestLength = 20

    /// 位数のビット数（RFC 6979 の qlen）
    private static var orderBitLength: Int { DTCPCurve.order.bitLength }

    /// ダイジェストを位数のビット数まで切り詰めて整数にする（python-ecdsa の truncate_and_convert_digest）
    static func hashToInteger(_ digest: some Collection<UInt8>) -> DTCPBigUInt {
        let value = DTCPBigUInt(bytes: digest)
        let excess = digest.count * 8 - orderBitLength
        return excess > 0 ? value >> excess : value
    }

    /// 40 バイト（r || s）の ECDSA-SHA1 の署名を確かめる
    static func verify(publicKey: DTCPPoint, data: some Collection<UInt8>, signature: some Collection<UInt8>) -> Bool {
        let signature = Array(signature)
        guard signature.count == DTCPCurve.size * 2 else { return false }
        let n = DTCPCurve.order
        let r = DTCPBigUInt(bytes: signature[0..<DTCPCurve.size])
        let s = DTCPBigUInt(bytes: signature[DTCPCurve.size...])
        guard !r.isZero, r < n, !s.isZero, s < n else { return false }
        let z = hashToInteger(DTCPHash.sha1(data))
        guard let w = DTCPCurve.scalars.inverse(s) else { return false }
        let u1 = DTCPCurve.scalars.multiply(DTCPCurve.scalars.reduce(z), w)
        let u2 = DTCPCurve.scalars.multiply(r, w)
        guard let point = DTCPPoint.sum(DTCPCurve.generator.multiplied(by: u1), publicKey.multiplied(by: u2)) else {
            return false
        }
        return point.x % n == r
    }

    /// RFC 6979 の決定的な nonce（HMAC-SHA1）。python-ecdsa の rfc6979.generate_k と同じ。
    /// `retry` 個の有効な候補を読み飛ばす（r == 0・s == 0 でやり直すときだけ）
    private static func deterministicNonce(privateKey: DTCPBigUInt, digest: [UInt8], retry: Int) -> DTCPBigUInt {
        let n = DTCPCurve.order
        let rolen = (orderBitLength + 7) / 8
        var z = hashToInteger(digest)
        if z >= n { z = z - n }
        let bx = privateKey.bytes(length: rolen)! + z.bytes(length: rolen)!

        var v = [UInt8](repeating: 0x01, count: digestLength)
        var k = [UInt8](repeating: 0x00, count: digestLength)
        k = DTCPHash.hmacSHA1(key: k, data: v + [0x00] + bx)
        v = DTCPHash.hmacSHA1(key: k, data: v)
        k = DTCPHash.hmacSHA1(key: k, data: v + [0x01] + bx)
        v = DTCPHash.hmacSHA1(key: k, data: v)

        var skip = retry
        while true {
            v = DTCPHash.hmacSHA1(key: k, data: v)
            let candidate = hashToInteger(v)
            if !candidate.isZero && candidate < n {
                if skip == 0 { return candidate }
                skip -= 1
            }
            k = DTCPHash.hmacSHA1(key: k, data: v + [0x00])
            v = DTCPHash.hmacSHA1(key: k, data: v)
        }
    }

    /// ECDSA-SHA1 で署名する（nonce は RFC 6979）。40 バイトの r || s。
    /// 同じ鍵とデータなら python-ecdsa の sign_deterministic とバイト単位で同じ
    static func signDeterministic(privateKey: DTCPBigUInt, data: some Collection<UInt8>) -> [UInt8] {
        let n = DTCPCurve.order
        let digest = DTCPHash.sha1(data)
        let z = hashToInteger(digest)
        var retry = 0
        while true {
            let k = deterministicNonce(privateKey: privateKey, digest: digest, retry: retry)
            guard let point = DTCPCurve.generator.multiplied(by: k) else {
                retry += 1
                continue
            }
            let r = point.x % n
            guard !r.isZero, let kInverse = DTCPCurve.scalars.inverse(k) else {
                retry += 1
                continue
            }
            let s = DTCPCurve.scalars.multiply(kInverse, DTCPCurve.scalars.reduce(z + DTCPCurve.scalars.multiply(privateKey, r)))
            guard !s.isZero else {
                retry += 1
                continue
            }
            return r.bytes(length: DTCPCurve.size)! + s.bytes(length: DTCPCurve.size)!
        }
    }

    /// ECDH：共有点の x 座標（20 バイト）。python-ecdsa の generate_sharedsecret_bytes と同じ
    static func sharedSecret(privateKey: DTCPBigUInt, peerPublicKey: DTCPPoint) throws -> [UInt8] {
        guard let shared = peerPublicKey.multiplied(by: privateKey) else {
            throw DTCPError.validation("dtcp:crypto", "ECDH failed")
        }
        return shared.x.bytes(length: DTCPCurve.size)!
    }

    /// AKE の一時鍵に使う、[1, 位数) の一様な乱数
    static func randomScalar() -> DTCPBigUInt {
        while true {
            let value = DTCPBigUInt(bytes: DTCPRandom.bytes(DTCPCurve.size))
            if !value.isZero && value < DTCPCurve.order { return value }
        }
    }
}

/// SHA-1 と HMAC-SHA1（CryptoKit）
enum DTCPHash {
    static func sha1(_ data: some Collection<UInt8>) -> [UInt8] {
        Array(Insecure.SHA1.hash(data: Array(data)))
    }

    static func hmacSHA1(key: [UInt8], data: [UInt8]) -> [UInt8] {
        Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}

/// 暗号用の乱数（SecRandomCopyBytes）
enum DTCPRandom {
    static func bytes(_ count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &out)
        precondition(status == errSecSuccess, "SecRandomCopyBytes が失敗した")
        return out
    }
}
