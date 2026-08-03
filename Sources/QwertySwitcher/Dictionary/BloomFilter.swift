import Foundation

struct BloomFilter {
    private var bits: [UInt64]
    let bitCount: Int
    let hashCount: Int

    init(expectedCount: Int, falsePositiveRate: Double = 0.01) {
        let safeExpectedCount = Self.normalizedExpectedCount(expectedCount)
        let m = max(64, Int(ceil(-Double(safeExpectedCount) * log(falsePositiveRate) / pow(log(2), 2))))
        let k = max(1, Int(ceil(Double(m) / Double(safeExpectedCount) * log(2))))
        self.bitCount = m
        self.hashCount = k
        self.bits = [UInt64](repeating: 0, count: (m + 63) / 64)
    }

    static func normalizedExpectedCount(_ count: Int) -> Int {
        max(1, count)
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

    func save(to url: URL, sourceFingerprint: UInt64 = 0) throws {
        var data = Data()
        Self.appendLittleEndian(UInt32(0x51574246), to: &data) // "QWBF"
        Self.appendLittleEndian(UInt32(2), to: &data)
        Self.appendLittleEndian(UInt32(bitCount), to: &data)
        Self.appendLittleEndian(UInt32(hashCount), to: &data)
        Self.appendLittleEndian(UInt32(bits.count), to: &data)
        Self.appendLittleEndian(sourceFingerprint, to: &data)
        for word in bits {
            Self.appendLittleEndian(word, to: &data)
        }
        try data.write(to: url, options: .atomic)
    }

    static func load(from url: URL, expectedFingerprint: UInt64? = nil) throws -> BloomFilter {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let headerSize = 28
        guard data.count >= headerSize else { throw BloomFilterError.invalidFormat }

        let magic: UInt32 = try readLittleEndian(from: data, offset: 0)
        guard magic == 0x51574246 else { throw BloomFilterError.invalidMagic }
        let version: UInt32 = try readLittleEndian(from: data, offset: 4)
        guard version == 2 else { throw BloomFilterError.unsupportedVersion }

        let storedBitCount: UInt32 = try readLittleEndian(from: data, offset: 8)
        let storedHashCount: UInt32 = try readLittleEndian(from: data, offset: 12)
        let storedBitsCount: UInt32 = try readLittleEndian(from: data, offset: 16)
        let fingerprint: UInt64 = try readLittleEndian(from: data, offset: 20)
        if let expectedFingerprint, fingerprint != expectedFingerprint {
            throw BloomFilterError.sourceChanged
        }

        let bitCount = Int(storedBitCount)
        let hashCount = Int(storedHashCount)
        let bitsCount = Int(storedBitsCount)
        guard bitCount >= 64, hashCount > 0, bitsCount > 0,
              bitsCount == (bitCount + 63) / 64,
              data.count == headerSize + bitsCount * 8 else {
            throw BloomFilterError.invalidFormat
        }

        var bits = [UInt64](repeating: 0, count: bitsCount)
        for i in 0..<bitsCount {
            bits[i] = try readLittleEndian(from: data, offset: headerSize + i * 8)
        }

        return BloomFilter(bits: bits, bitCount: bitCount, hashCount: hashCount)
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func readLittleEndian<T: FixedWidthInteger>(
        from data: Data, offset: Int
    ) throws -> T {
        guard offset >= 0, offset + MemoryLayout<T>.size <= data.count else {
            throw BloomFilterError.truncated
        }
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size {
            value |= T(data[offset + index]) << T(index * 8)
        }
        return value
    }

    enum BloomFilterError: Error {
        case invalidFormat, invalidMagic, unsupportedVersion, sourceChanged, truncated
    }
}
