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
        return spellCheckValid(word, language: language)
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

            // Try cached BloomFilter first (instant)
            if let cached = loadCachedBloom(lang: lang) {
                bloomFilters[lang] = cached
                NSLog("[Dictionary] Loaded \(lang): bloom from cache \(cached.sizeInBytes / 1024)KB")
                continue
            }

            // Build from text file
            if let words = loadWordList(named: fileName) {
                var bloom = BloomFilter(expectedCount: words.count, falsePositiveRate: 0.005) // 0.5% FPR
                for word in words { bloom.insert(word) }
                bloomFilters[lang] = bloom
                saveCachedBloom(bloom, lang: lang)
                NSLog("[Dictionary] Loaded \(lang): \(words.count) words, bloom built \(bloom.sizeInBytes / 1024)KB")
            } else {
                NSLog("[Dictionary] WARNING: No dictionary found for \(lang)")
            }
        }
    }

    private func loadWordList(named name: String) -> [String]? {
        let searchPaths = [
            Bundle.main.resourceURL?.appendingPathComponent("Dictionaries/\(name).txt"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Dictionaries/\(name).txt"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/Dictionaries/\(name).txt"),
        ]

        for url in searchPaths.compactMap({ $0 }) {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var words: [String] = []
            for line in content.split(separator: "\n") {
                let word = String(line).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if word.count >= 2 { words.append(word) }
            }
            if !words.isEmpty { return words }
        }
        return nil
    }

    private func spellCheckValid(_ word: String, language: String) -> Bool {
        let lang: String
        switch language {
        case "ru": lang = "ru"
        case "en": lang = "en"
        default: return true // for unknown languages, trust BloomFilter
        }
        let range = spellChecker.checkSpelling(
            of: word, startingAt: 0, language: lang,
            wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        )
        return range.location == NSNotFound
    }

    // MARK: - BloomFilter Cache

    private func bloomCacheURL(lang: String) -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("SashaSwitcher")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(lang).ssbf")
    }

    private func loadCachedBloom(lang: String) -> BloomFilter? {
        guard let url = bloomCacheURL(lang: lang) else { return nil }
        return try? BloomFilter.load(from: url)
    }

    private func saveCachedBloom(_ bloom: BloomFilter, lang: String) {
        guard let url = bloomCacheURL(lang: lang) else { return }
        try? bloom.save(to: url)
    }
}
