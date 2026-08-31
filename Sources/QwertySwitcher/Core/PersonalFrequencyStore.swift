import Foundation

/// A word the owner has typed and confirmed (border passed, no correction)
/// at least once — Mechanism C's passive personal-frequency signal.
struct PersonalFrequencyEntry: Equatable {
    var count: Int
    var lastSeen: Date
    var isDictionaryWord: Bool
}

/// Result of `PersonalFrequencyStore.bump`.
///
/// `.capped` is returned only when THIS call created a brand-new entry that
/// pushed the store over its cap and triggered an eviction of some other
/// entry — informational, not a rejection.
enum BumpOutcome: Equatable {
    case bumped
    case promoted
    case capped
}

/// Mechanism C storage: passive convergence signal. All gating specific to
/// *whether a word qualifies to be bumped* (own-side junk cleanliness,
/// mixed-script, `core()` extraction, "projection is already a word/learned"
/// anti-#19 check) requires `JunkMeter`/`LanguageDetector`/dictionary
/// lookups and is wave-2 integration work performed by the caller before it
/// ever calls `bump`. This store only guards non-empty/lowercased/len>=3
/// input (the same class of guard `LearnedWordsStore` applies) and owns
/// count/promotion/cap/persistence bookkeeping.
final class PersonalFrequencyStore {
    private let defaults: UserDefaults
    private let persistKey = AppIdentity.keyPrefix + "personalFreq"
    private let cap = 2000
    private let promotionThreshold = 5

    private var entries: [String: PersonalFrequencyEntry] = [:]
    private var promotedSet: Set<String> = []
    private var dirty = false

    /// Injected from outside (mirrors `Preferences.isLearningEnabled`).
    var isEnabled: Bool = true {
        didSet {
            guard oldValue != isEnabled else { return }
            recomputeAllPromoted()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// Store size (number of tracked words, including in-memory-only
    /// `count == 1` entries) — for UI ("Личный словарь: N слов").
    var count: Int { entries.count }

    // MARK: - Recording

    @discardableResult
    func bump(word: String, lang: String, isDictionaryWord: Bool, at: Date) -> BumpOutcome {
        guard isEnabled, isValid(word: word, lang: lang) else { return .bumped }
        let key = makeKey(word: word, lang: lang)

        guard var entry = entries[key] else {
            entries[key] = PersonalFrequencyEntry(count: 1, lastSeen: at, isDictionaryWord: isDictionaryWord)
            recomputePromoted(key: key)
            markDirty()
            return enforceCap() ? .capped : .bumped
        }

        let wasPromoted = entry.count >= promotionThreshold
        entry.count += 1
        entry.lastSeen = at
        entry.isDictionaryWord = isDictionaryWord
        entries[key] = entry
        recomputePromoted(key: key)
        markDirty()
        return (!wasPromoted && entry.count >= promotionThreshold) ? .promoted : .bumped
    }

    func unlearn(word: String, lang: String) {
        guard isValid(word: word, lang: lang) else { return }
        let key = makeKey(word: word, lang: lang)
        guard entries.removeValue(forKey: key) != nil else { return }
        promotedSet.remove(key)
        markDirty()
    }

    func removeAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        promotedSet.removeAll()
        markDirty()
    }

    // MARK: - Queries

    func isPromoted(word: String, lang: String) -> Bool {
        promotedSet.contains(makeKey(word: word, lang: lang))
    }

    /// Words (not composite keys) of `lang` with dictionary-equivalent
    /// status — applied only on the boundary path (see spec Mechanism C).
    func promotedKeys(lang: String) -> Set<String> {
        let prefix = lang + ":"
        var result: Set<String> = []
        for key in promotedSet where key.hasPrefix(prefix) {
            result.insert(String(key.dropFirst(prefix.count)))
        }
        return result
    }

    /// Same as `promotedKeys`, but excludes entries whose most recent bump
    /// was a dictionary word — for callers that need only the non-dictionary
    /// half of Mechanism C's promoted set (wave-2 provider wiring in
    /// `KeyboardMonitor`). `promotedSet`/`isPromoted` are untouched:
    /// `undoLastCorrection`'s unlearn path is keyed on `isPromoted` and must
    /// keep seeing the full set regardless of this split.
    func promotedNonDictionaryKeys(lang: String) -> Set<String> {
        let prefix = lang + ":"
        var result: Set<String> = []
        for key in promotedSet where key.hasPrefix(prefix) {
            guard let entry = entries[key], !entry.isDictionaryWord else { continue }
            result.insert(String(key.dropFirst(prefix.count)))
        }
        return result
    }

    /// For UI ("топ-20 по частоте" etc.) — includes in-memory-only
    /// `count == 1` entries, unlike what actually reaches disk.
    var allEntries: [String: PersonalFrequencyEntry] { entries }

    // MARK: - Persistence (no disk I/O on the hot path)

    /// Persists pending mutations. Safe to call from a ~30s timer; a no-op
    /// when nothing changed since the last flush.
    ///
    /// Privacy: `count == 1` entries never reach disk regardless of
    /// `isDictionaryWord` (this is a record of what the owner typed).
    /// Dictionary words persist at `count >= 2`, non-dictionary words only
    /// at `count >= 3`.
    func flush(now: Date) {
        guard dirty else { return }
        persist()
        dirty = false
    }

    private func persist() {
        let payload = entries.compactMapValues { entry -> PersistedEntry? in
            let threshold = entry.isDictionaryWord ? 2 : 3
            guard entry.count >= threshold else { return nil }
            return PersistedEntry(
                count: entry.count,
                lastSeen: entry.lastSeen.timeIntervalSince1970,
                isDictionaryWord: entry.isDictionaryWord
            )
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: persistKey)
    }

    private func load() {
        guard let data = defaults.data(forKey: persistKey),
              let payload = try? JSONDecoder().decode([String: PersistedEntry].self, from: data) else { return }
        entries = payload.mapValues { p in
            PersonalFrequencyEntry(
                count: p.count,
                lastSeen: Date(timeIntervalSince1970: p.lastSeen),
                isDictionaryWord: p.isDictionaryWord
            )
        }
        recomputeAllPromoted()
    }

    private struct PersistedEntry: Codable {
        let count: Int
        let lastSeen: TimeInterval
        let isDictionaryWord: Bool
    }

    // MARK: - Helpers

    private func markDirty() { dirty = true }

    private func isValid(word: String, lang: String) -> Bool {
        !word.isEmpty && !lang.isEmpty && word == word.lowercased() && word.count >= 3
    }

    private func makeKey(word: String, lang: String) -> String {
        "\(lang):\(word)"
    }

    private func isEntryPromoted(_ entry: PersonalFrequencyEntry) -> Bool {
        entry.count >= promotionThreshold
    }

    private func recomputePromoted(key: String) {
        guard let entry = entries[key] else {
            promotedSet.remove(key)
            return
        }
        if isEnabled && isEntryPromoted(entry) {
            promotedSet.insert(key)
        } else {
            promotedSet.remove(key)
        }
    }

    private func recomputeAllPromoted() {
        promotedSet.removeAll()
        guard isEnabled else { return }
        for (key, entry) in entries where isEntryPromoted(entry) {
            promotedSet.insert(key)
        }
    }

    /// Same eviction policy as `LearnedWordsStore`: `count == 1` entries
    /// first (oldest `lastSeen`), then plain LRU across the rest.
    @discardableResult
    private func enforceCap() -> Bool {
        guard entries.count > cap else { return false }
        var evictedAny = false
        while entries.count > cap {
            if let victim = entries.filter({ $0.value.count == 1 })
                .min(by: { $0.value.lastSeen < $1.value.lastSeen }) {
                entries.removeValue(forKey: victim.key)
                promotedSet.remove(victim.key)
                evictedAny = true
                continue
            }
            guard let victim = entries.min(by: { $0.value.lastSeen < $1.value.lastSeen }) else { break }
            entries.removeValue(forKey: victim.key)
            promotedSet.remove(victim.key)
            evictedAny = true
        }
        return evictedAny
    }
}
