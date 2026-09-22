import Foundation

/// XXH64, the checksum of ASC MHL, Hedge, Silverstack and ShotPut: as good as
/// MD5 at catching a flipped bit and several times faster than the card can
/// read, so checking costs nothing but the second read.
///
/// Streaming, so a 40 GB clip is hashed as it is copied.
struct XXHash64 {
    private static let p1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let p2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let p3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let p4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let p5: UInt64 = 0x27D4_EB2F_1656_67C5

    private let seed: UInt64
    private var v1: UInt64
    private var v2: UInt64
    private var v3: UInt64
    private var v4: UInt64
    private var total: UInt64 = 0
    private var buffer: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    private var buffered = 0

    init(seed: UInt64 = 0) {
        self.seed = seed
        v1 = seed &+ Self.p1 &+ Self.p2
        v2 = seed &+ Self.p2
        v3 = seed
        v4 = seed &- Self.p1
    }

    @inline(__always) private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 {
        (x << r) | (x >> (64 - r))
    }

    @inline(__always) private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        rotl(acc &+ input &* p2, 31) &* p1
    }

    @inline(__always) private static func merge(_ acc: UInt64, _ value: UInt64) -> UInt64 {
        ((acc ^ round(0, value)) &* p1) &+ p4
    }

    @inline(__always) private static func lane(_ p: UnsafeRawPointer, _ offset: Int) -> UInt64 {
        UInt64(littleEndian: p.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard var p = bytes.baseAddress, bytes.count > 0 else { return }
        var count = bytes.count
        total &+= UInt64(count)

        // Top up a stripe started by the previous call.
        if buffered > 0 {
            let take = min(32 - buffered, count)
            withUnsafeMutableBytes(of: &buffer) { stripe in
                stripe.baseAddress!.advanced(by: buffered).copyMemory(from: p, byteCount: take)
            }
            buffered += take
            p = p.advanced(by: take)
            count -= take
            guard buffered == 32 else { return }
            withUnsafeBytes(of: &buffer) { stripe in
                let s = stripe.baseAddress!
                v1 = Self.round(v1, Self.lane(s, 0))
                v2 = Self.round(v2, Self.lane(s, 8))
                v3 = Self.round(v3, Self.lane(s, 16))
                v4 = Self.round(v4, Self.lane(s, 24))
            }
            buffered = 0
        }

        var a = v1, b = v2, c = v3, d = v4
        while count >= 32 {
            a = Self.round(a, Self.lane(p, 0))
            b = Self.round(b, Self.lane(p, 8))
            c = Self.round(c, Self.lane(p, 16))
            d = Self.round(d, Self.lane(p, 24))
            p = p.advanced(by: 32)
            count -= 32
        }
        v1 = a; v2 = b; v3 = c; v4 = d

        if count > 0 {
            withUnsafeMutableBytes(of: &buffer) { stripe in
                stripe.baseAddress!.copyMemory(from: p, byteCount: count)
            }
            buffered = count
        }
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    func digest() -> UInt64 {
        var h: UInt64
        if total >= 32 {
            h = Self.rotl(v1, 1) &+ Self.rotl(v2, 7) &+ Self.rotl(v3, 12) &+ Self.rotl(v4, 18)
            h = Self.merge(h, v1)
            h = Self.merge(h, v2)
            h = Self.merge(h, v3)
            h = Self.merge(h, v4)
        } else {
            h = seed &+ Self.p5
        }
        h &+= total

        var tail = buffer
        withUnsafeBytes(of: &tail) { stripe in
            let s = stripe.baseAddress!
            var i = 0
            while i + 8 <= buffered {
                h ^= Self.round(0, Self.lane(s, i))
                h = Self.rotl(h, 27) &* Self.p1 &+ Self.p4
                i += 8
            }
            if i + 4 <= buffered {
                h ^= UInt64(UInt32(littleEndian: s.loadUnaligned(fromByteOffset: i, as: UInt32.self))) &* Self.p1
                h = Self.rotl(h, 23) &* Self.p2 &+ Self.p3
                i += 4
            }
            while i < buffered {
                h ^= UInt64(s.load(fromByteOffset: i, as: UInt8.self)) &* Self.p5
                h = Self.rotl(h, 11) &* Self.p1
                i += 1
            }
        }

        h ^= h >> 33
        h &*= Self.p2
        h ^= h >> 29
        h &*= Self.p3
        h ^= h >> 32
        return h
    }

    /// The canonical form, as `xxhsum` and MHL files write it.
    var hex: String { String(format: "%016llx", digest()) }

    static func hash(_ data: Data, seed: UInt64 = 0) -> UInt64 {
        var h = XXHash64(seed: seed)
        h.update(data)
        return h.digest()
    }
}
