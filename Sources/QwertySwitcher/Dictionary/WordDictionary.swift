import Foundation
import AppKit

/// Dictionary uses BloomFilter (834KB) as primary + NSSpellChecker as confirmation.
/// No Set<String> in memory for membership checks — saves ~60MB RAM.
///
/// `sortedWords` is the one exception: instant (mid-word) correction needs a
/// reliable PREFIX check (bloom filters can't do that, and NSSpellChecker's
/// completions/spellcheck are unreliable for short unrecognized tokens — e.g.
/// it accepts "fdef"/"zzzz" as correctly-spelled English). It is built on a
/// background queue after `init` returns so it never delays app startup or
/// blocks the event tap, and read behind a lock (~11MB combined for en+ru).
final class WordDictionary {
    private var bloomFilters: [String: BloomFilter] = [:]
    private var sortedWords: [String: [String]] = [:]
    /// All bigrams occurring in any bundled word of length >=3, per language —
    /// junk-override's "is this letter pair even possible" check
    /// (`JunkMeter`, `LanguageDetector`). Built alongside `sortedWords` in the
    /// same background pass (len-2 dictionary garbage — see `twoLetterWords`
    /// in LanguageDetector — is excluded so it can't widen the possible set).
    /// Python mirror: Scripts/research/false_switch_sim.py `POSSIBLE` — keep
    /// both in sync.
    private var bigramSets: [String: Set<String>] = [:]
    private let sortedWordsLock = NSLock()
    private let sortedWordsGroup = DispatchGroup()
    private let spellChecker = NSSpellChecker.shared

    init() {
        loadDictionaries()
        loadSortedWordsAsync()
    }

    /// Blocks until the background prefix index (see `sortedWords`) finishes
    /// loading, or `timeout` elapses. Production code never needs this —
    /// `isPrefixOfBundledWord` just answers "not confirmed yet" until the
    /// index is ready. Tests that need a deterministic result right after
    /// `init` should call this first.
    func waitUntilPrefixIndexReady(timeout: TimeInterval = 5) {
        _ = sortedWordsGroup.wait(timeout: .now() + timeout)
    }

    /// BloomFilter pre-check: might this word be in the dictionary?
    func mightContain(_ word: String, language: String) -> Bool {
        guard let bloom = bloomFilters[language] else { return false }
        return bloom.contains(word)
    }

    /// Exact check via BloomFilter + SpellChecker confirmation
    /// BloomFilter has ~1% false positive, SpellChecker confirms
    ///
    /// ⚠️NOT safe to call from the CGEventTap callback / any per-keystroke hot
    /// path — `isSpellCheckerValid` below can block for 100+ms (macOS
    /// spell-checking IPC). `LanguageDetector`/`InstantCorrectionAnalyzer`
    /// use `mightContain` (bloom-only) instead for exactly this reason (see
    /// CLAUDE.md perf audit). Kept here for any future non-hot-path caller.
    func contains(_ word: String, language: String) -> Bool {
        guard mightContain(word, language: language) else { return false }
        // Confirm with system spell checker (eliminates false positives)
        return isSpellCheckerValid(word, language: language)
    }

    /// Independent system-dictionary fallback for words absent from our
    /// bundle. ⚠️Calls `NSSpellChecker.checkSpelling` synchronously — see the
    /// hot-path warning on `contains` above, same caller restriction applies.
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

    /// Whether `prefix` is the start of at least one word in our own bundled
    /// dictionary (binary search over a sorted array — deterministic, and not
    /// limited to whatever macOS's spellchecker happens to recognize). Used
    /// by instant (mid-word) correction, where the buffered text is not a
    /// complete word yet. Returns false until the background load finishes.
    func isPrefixOfBundledWord(_ prefix: String, language: String) -> Bool {
        guard !prefix.isEmpty else { return false }
        sortedWordsLock.lock()
        let words = sortedWords[language]
        sortedWordsLock.unlock()
        guard let words else { return false }

        var lo = 0
        var hi = words.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if words[mid] < prefix { lo = mid + 1 } else { hi = mid }
        }
        guard lo < words.count else { return false }
        return words[lo].hasPrefix(prefix)
    }

    /// Nil until the same background load `isPrefixOfBundledWord` depends on
    /// finishes — callers (junk-override) MUST treat nil as "don't fire",
    /// never as "empty set = nothing possible" (that would junk-flag every
    /// word during the brief startup window).
    func possibleBigrams(language: String) -> Set<String>? {
        sortedWordsLock.lock()
        defer { sortedWordsLock.unlock() }
        return bigramSets[language]
    }

    /// Exact membership in the bundled word list — binary search over the same
    /// `sortedWords` index `isPrefixOfBundledWord` uses. `nil` while the
    /// background index is still loading (first seconds after launch).
    func containsBundled(_ word: String, language: String) -> Bool? {
        guard !word.isEmpty else { return false }
        sortedWordsLock.lock()
        let words = sortedWords[language]
        sortedWordsLock.unlock()
        guard let words else { return nil }

        var lo = 0
        var hi = words.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if words[mid] < word { lo = mid + 1 } else { hi = mid }
        }
        guard lo < words.count else { return false }
        return words[lo] == word
    }

    /// Dictionary hit as the hot paths must see it: Bloom stays the O(1)
    /// pre-filter (rejects almost everything instantly), and a positive is
    /// confirmed exactly whenever the index is ready. Field 07–08.09.2026:
    /// three Bloom false positives (`jgnbvbpbhjdfyyhj`, `ghjghwb`, `erfposdf`
    /// all pass the en filter) each flipped a Russian typo into Latin garbage.
    /// Before the index is ready this degrades to Bloom-only (documented).
    func isConfirmedWord(_ word: String, language: String) -> Bool {
        guard mightContain(word, language: language) else { return false }
        return containsBundled(word, language: language) ?? true
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

    /// Populates `sortedWords` off the main thread. Re-reads the same word
    /// list files the bloom filters were built from (or loaded, cached,
    /// from disk) — a second, cheap I/O pass rather than plumbing the
    /// already-freed `words` array out of the (possibly cache-hit) bloom path.
    private func loadSortedWordsAsync() {
        let group = sortedWordsGroup
        group.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { group.leave() }
            guard let self else { return }
            for lang in ["en", "ru"] {
                let fileName = lang == "en" ? "en_US" : "ru_RU"
                guard let source = self.loadWordListData(named: fileName) else { continue }
                let words = self.parseWordList(source.data)
                let sorted = words.sorted()
                var bigrams = Set<String>()
                for word in words where word.count >= 3 {
                    let chars = Array(word)
                    for i in 0..<(chars.count - 1) {
                        bigrams.insert(String(chars[i...i + 1]))
                    }
                }
                self.sortedWordsLock.lock()
                self.sortedWords[lang] = sorted
                self.bigramSets[lang] = bigrams
                self.sortedWordsLock.unlock()
            }
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
