import Foundation

/// XXTEA (Corrected Block TEA, Needham–Wheeler) as used by Link PCLink for
/// `.pclx` (G4X/G5) and `.pcl5` (G4+) tune files.
///
/// Recovered by reverse-engineering PCLink.exe 7.8.2:
///   - core routine at VA 0x4516D4 (DELTA 0x9E3779B9, key index `(p & 3) ^ e`)
///   - wrapper at VA 0x4518D8 reads the whole file into one block
///   - 16-byte key table at VA 0x8EDA90, little-endian uint32 words
///
/// File layout (little-endian uint32 array, encrypted as ONE XXTEA block):
///   word[0] = count field (decoy/ignored on read)
///   word[1] = plaintext length in bytes
///   word[2] = direction flag (0)
///   word[3...] = plaintext (UTF-8 / latin1 XML), `word[1]` bytes long
public enum TuneCrypt {

    /// The `.pclx` / `.pcl5` content key (VA 0x8EDA90), little-endian words.
    public static let fileKey: [UInt32] = [0x0000_4D5C, 0x0000_B091, 0x0091_FCC8, 0x0007_C4FE]

    /// Secondary key at VA 0x8EDAB0 (used for an encrypted-basemap path).
    public static let basemapKey: [UInt32] = [0xD7CE_5219, 0x1E81_08D4, 0xF036_3673, 0xA38B_AA9A]

    private static let delta: UInt32 = 0x9E37_79B9

    /// In-place XXTEA over a word array. `n > 0` encodes, `n < 0` decodes.
    static func btea(_ v: inout [UInt32], _ n: Int, _ key: [UInt32]) {
        guard v.count >= 2 else { return }
        func mx(_ sum: UInt32, _ y: UInt32, _ z: UInt32, _ p: Int, _ e: UInt32) -> UInt32 {
            let a = (z >> 5) ^ (y << 2)
            let b = (y >> 3) ^ (z << 4)
            let c = (sum ^ y) &+ (key[(p & 3) ^ Int(e)] ^ z)
            return (a &+ b) ^ c
        }
        if n > 1 {
            let count = n
            let rounds = 6 + 52 / count
            var sum: UInt32 = 0
            var z = v[count - 1]
            for _ in 0..<rounds {
                sum = sum &+ delta
                let e = (sum >> 2) & 3
                for p in 0..<(count - 1) {
                    let y = v[p + 1]
                    v[p] = v[p] &+ mx(sum, y, z, p, e)
                    z = v[p]
                }
                let p = count - 1
                let y = v[0]
                v[p] = v[p] &+ mx(sum, y, z, p, e)
                z = v[p]
            }
        } else if n < -1 {
            let count = -n
            let rounds = 6 + 52 / count
            var sum = UInt32(truncatingIfNeeded: rounds) &* delta
            var y = v[0]
            for _ in 0..<rounds {
                let e = (sum >> 2) & 3
                var p = count - 1
                while p > 0 {
                    let z = v[p - 1]
                    v[p] = v[p] &- mx(sum, y, z, p, e)
                    y = v[p]
                    p -= 1
                }
                let z = v[count - 1]
                v[0] = v[0] &- mx(sum, y, z, 0, e)
                y = v[0]
                sum = sum &- delta
            }
        }
    }

    public enum CryptError: Error { case tooShort, badLength }

    /// Decrypt a tune file's bytes into its plaintext XML bytes.
    public static func decrypt(_ raw: Data, key: [UInt32] = fileKey) throws -> Data {
        guard raw.count >= 16 else { throw CryptError.tooShort }
        let n = raw.count / 4
        var v = [UInt32](repeating: 0, count: n)
        raw.withUnsafeBytes { buf in
            for i in 0..<n { v[i] = buf.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self).littleEndian }
        }
        btea(&v, -n, key)
        var out = Data(count: n * 4)
        out.withUnsafeMutableBytes { dst in
            for i in 0..<n { dst.storeBytes(of: v[i].littleEndian, toByteOffset: i * 4, as: UInt32.self) }
        }
        let plen = Int(out.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian })
        guard plen >= 0, 12 + plen <= out.count else { throw CryptError.badLength }
        return out.subdata(in: 12..<(12 + plen))
    }

    /// Encrypt plaintext XML bytes back into a tune file. Functionally correct
    /// (decode ignores word[0]); the count field uses a simple word count.
    public static func encrypt(_ plain: Data, key: [UInt32] = fileKey) -> Data {
        let size = plain.count
        let n = size / 4 + 4
        var buf = Data(count: n * 4)
        buf.withUnsafeMutableBytes { dst in
            dst.storeBytes(of: UInt32((size + 3) / 4).littleEndian, toByteOffset: 0, as: UInt32.self)
            dst.storeBytes(of: UInt32(size).littleEndian, toByteOffset: 4, as: UInt32.self)
            dst.storeBytes(of: UInt32(0).littleEndian, toByteOffset: 8, as: UInt32.self)
        }
        buf.replaceSubrange(12..<(12 + size), with: plain)
        var v = [UInt32](repeating: 0, count: n)
        buf.withUnsafeBytes { b in
            for i in 0..<n { v[i] = b.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self).littleEndian }
        }
        btea(&v, n, key)
        var out = Data(count: n * 4)
        out.withUnsafeMutableBytes { dst in
            for i in 0..<n { dst.storeBytes(of: v[i].littleEndian, toByteOffset: i * 4, as: UInt32.self) }
        }
        return out
    }
}
