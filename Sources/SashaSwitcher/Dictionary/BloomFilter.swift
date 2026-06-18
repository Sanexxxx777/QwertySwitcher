import Foundation

struct BloomFilter {
    private var bits: [UInt64]
    let bitCount: Int
    let hashCount: Int

    init(expectedCount: Int, falsePositiveRate: Double = 0.01) {
        let m = max(64, Int(ceil(-Double(expectedCount) * log(falsePositiveRate) / pow(log(2), 2))))
        let k = max(1, Int(ceil(Double(m) / Double(expectedCount) * log(2))))
        self.bitCount = m
        self.hashCount = k
        self.bits = [UInt64](repeating: 0, count: (m + 63) / 64)
    }

    private init(bits: [UInt64], bitCount: Int, hashCount: Int) {
        self.bits = bits
        self.bitCount = bitCount
        self.hashCount = hashCount
    }

    // FNV-1a double hashing
    private func hashes(_ value: String) -> [Int] {
        let data = Array(value.utf8)
        var h1: UInt64 = 14695981039346656037  // FNV offset basis
        var h2: UInt64 = 0xcbf29ce484222325
        for byte in data {
            h1 ^= UInt64(byte)
            h1 &*= 1099511628211  // FNV prime
            h2 ^= UInt64(byte)
            h2 &*= 6364136223846793005
        }
        return (0..<hashCount).map { i in
            Int((h1 &+ UInt64(i) &* h2) % UInt64(bitCount))
        }
    }

    mutating func insert(_ value: String) {
        for h in hashes(value) {
            bits[h / 64] |= (1 << (h % 64))
        }
    }

    func contains(_ value: String) -> Bool {
        for h in hashes(value) {
            if bits[h / 64] & (1 << (h % 64)) == 0 { return false }
        }
        return true
    }

    var sizeInBytes: Int { bits.count * 8 }

    // MARK: - Serialization

    func save(to url: URL) throws {
        var data = Data()
        // Header: magic(4) + bitCount(4) + hashCount(4) + bitsCount(4) = 16 bytes
        let magic: UInt32 = 0x53534246  // "SSBF" — SashaSwitcher BloomFilter
        data.append(contentsOf: withUnsafeBytes(of: magic) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(bitCount)) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(hashCount)) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(bits.count)) { Array($0) })
        // Bit data
        for word in bits {
            data.append(contentsOf: withUnsafeBytes(of: word) { Array($0) })
        }
        try data.write(to: url)
    }

    static func load(from url: URL) throws -> BloomFilter {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= 16 else { throw BloomFilterError.invalidFormat }

        let magic = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        guard magic == 0x53534246 else { throw BloomFilterError.invalidMagic }

        let bitCount = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
        let hashCount = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) })
        let bitsCount = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) })

        guard data.count >= 16 + bitsCount * 8 else { throw BloomFilterError.truncated }

        var bits = [UInt64](repeating: 0, count: bitsCount)
        for i in 0..<bitsCount {
            bits[i] = data.withUnsafeBytes { $0.load(fromByteOffset: 16 + i * 8, as: UInt64.self) }
        }

        return BloomFilter(bits: bits, bitCount: bitCount, hashCount: hashCount)
    }

    enum BloomFilterError: Error {
        case invalidFormat, invalidMagic, truncated
    }
}
