import Foundation
import AppKit

/// Dictionary uses BloomFilter (834KB) as primary + NSSpellChecker as confirmation.
/// No Set<String> in memory — saves ~60MB RAM.
final class WordDictionary {
    private var bloomFilters: [String: BloomFilter] = [:]
    private let spellChecker = NSSpellChecker.shared

    init() {
        loadDictionaries()
    }

    /// BloomFilter pre-check: might this word be in the dictionary?
    func mightContain(_ word: String, language: String) -> Bool {
        guard let bloom = bloomFilters[language] else { return false }
        return bloom.contains(word)
    }

    /// Exact check via BloomFilter + SpellChecker confirmation
    /// BloomFilter has ~1% false positive, SpellChecker confirms
    func contains(_ word: String, language: String) -> Bool {
        guard mightContain(word, language: language) else { return false }
        // Confirm with system spell checker (eliminates false positives)
        return isSpellCheckerValid(word, language: language)
    }

    /// Independent system-dictionary fallback for words absent from our bundle.
    func isSpellCheckerValid(_ word: String, language: String) -> Bool {
        let lang: String
        switch language {
        case "ru": lang = "ru"
        case "en": lang = "en"
        default: return false
        }
        let range = spellChecker.checkSpelling(
            of: word, startingAt: 0, language: lang,
            wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        )
        return range.location == NSNotFound
    }

    var stats: String {
        let parts = bloomFilters.map { "\($0.key) bloom: \($0.value.sizeInBytes / 1024)KB" }
        return parts.joined(separator: ", ")
    }

    // MARK: - Loading

    private func loadDictionaries() {
        let supportedLanguages = ["en", "ru"]

        for lang in supportedLanguages {
            let fileName = lang == "en" ? "en_US" : "ru_RU"

            guard let source = loadWordListData(named: fileName) else {
                NSLog("[Dictionary] WARNING: No dictionary found for \(lang)")
                continue
            }
            let fingerprint = Self.fingerprint(source.data)

            if let cached = loadCachedBloom(lang: lang, fingerprint: fingerprint) {
                bloomFilters[lang] = cached
                NSLog("[Dictionary] Loaded \(lang): bloom from cache \(cached.sizeInBytes / 1024)KB")
                continue
            }

            let words = parseWordList(source.data)
            var bloom = BloomFilter(expectedCount: words.count, falsePositiveRate: 0.005)
            for word in words { bloom.insert(word) }
            bloomFilters[lang] = bloom
            saveCachedBloom(bloom, lang: lang, fingerprint: fingerprint)
            NSLog("[Dictionary] Loaded \(lang): \(words.count) words, bloom built \(bloom.sizeInBytes / 1024)KB")
        }
    }

    private func loadWordListData(named name: String) -> (data: Data, url: URL)? {
        let searchPaths = [
            Bundle.main.resourceURL?.appendingPathComponent("Dictionaries/\(name).txt"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Dictionaries/\(name).txt"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/Dictionaries/\(name).txt"),
        ]

        for url in searchPaths.compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            return (data, url)
        }
        return nil
    }

    private func parseWordList(_ data: Data) -> [String] {
        guard let content = String(data: data, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").compactMap { line in
            let word = String(line).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return word.count >= 2 ? word : nil
        }
    }

    private static func fingerprint(_ data: Data) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }

    // MARK: - BloomFilter Cache

    private func bloomCacheURL(lang: String) -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent(AppIdentity.compactName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(lang).ssbf")
    }

    private func loadCachedBloom(lang: String, fingerprint: UInt64) -> BloomFilter? {
        guard let url = bloomCacheURL(lang: lang) else { return nil }
        return try? BloomFilter.load(from: url, expectedFingerprint: fingerprint)
    }

    private func saveCachedBloom(_ bloom: BloomFilter, lang: String, fingerprint: UInt64) {
        guard let url = bloomCacheURL(lang: lang) else { return }
        try? bloom.save(to: url, sourceFingerprint: fingerprint)
    }
}
