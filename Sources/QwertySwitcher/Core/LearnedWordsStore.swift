import Foundation

/// A single learned word-fix pair: the owner manually converted this word
/// (via Double Shift) at least once, and — after a second confirmation
/// within the promotion window — it becomes eligible for automatic
/// correction (Mechanism A, see `learning_spec.md`).
struct LearnedWordEntry: Equatable {
    var count: Int
    var firstConfirmed: Date
    var lastConfirmed: Date
    var originApp: String?
}

/// Result of `LearnedWordsStore.recordManualFix`.
///
/// `.capped` is returned only when THIS call created a brand-new entry that
/// pushed the store over its cap and triggered an eviction of some other
/// entry — it is informational, not a rejection (the new entry is always
/// stored).
enum RecordOutcome: Equatable {
    case recorded
    case promoted
    case capped
}

/// Mechanism A storage: positive Double Shift corrections that graduate into
/// silent, automatic corrections once confirmed twice within 30 days.
///
/// Pure module: the caller is responsible for all conversion/`core()`/
/// `conflictPairs` validation (wave 2). This store only guards non-empty,
/// already-lowercased input and manages counts, promotion, cap eviction and
/// (non-hot-path) persistence.
final class LearnedWordsStore {
    private let defaults: UserDefaults
    private let persistKey = AppIdentity.keyPrefix + "learnedWords"
    private let cap = 300
    private let promotionWindow: TimeInterval = 30 * 24 * 60 * 60

    private var entries: [String: LearnedWordEntry] = [:]
    private var activeSet: Set<String> = []
    private var dirty = false

    /// Injected from outside (mirrors `Preferences.isLearningEnabled`).
    /// Mutes both recording and application — while `false`, no new record
    /// is written and no existing entry reports as active.
    var isEnabled: Bool = true {
        didSet {
            guard oldValue != isEnabled else { return }
            recomputeAllActive()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Recording

    @discardableResult
    func recordManualFix(word: String, lang: String, originApp: String?, at: Date) -> RecordOutcome {
        guard isEnabled, isValid(word: word, lang: lang) else { return .recorded }
        let key = makeKey(word: word, lang: lang)

        guard var entry = entries[key] else {
            entries[key] = LearnedWordEntry(count: 1, firstConfirmed: at, lastConfirmed: at, originApp: originApp)
            recomputeActive(key: key)
            markDirty()
            return enforceCap() ? .capped : .recorded
        }

        let gap = at.timeIntervalSince(entry.firstConfirmed)
        if gap > promotionWindow {
            entries[key] = LearnedWordEntry(count: 1, firstConfirmed: at, lastConfirmed: at, originApp: originApp)
            recomputeActive(key: key)
            markDirty()
            return .recorded
        }

        let wasActive = entry.count >= 2
        entry.count += 1
        entry.lastConfirmed = at
        entry.originApp = originApp
        entries[key] = entry
        recomputeActive(key: key)
        markDirty()
        return (!wasActive && entry.count >= 2) ? .promoted : .recorded
    }

    /// Decrements the record by exactly one (never below zero). Callers are
    /// responsible for one-shot semantics (an anti-toggle slot fires once).
    /// A count that reaches zero removes the entry entirely.
    func revokeRecord(word: String, lang: String) {
        guard isValid(word: word, lang: lang) else { return }
        let key = makeKey(word: word, lang: lang)
        guard var entry = entries[key] else { return }
        entry.count = max(0, entry.count - 1)
        if entry.count == 0 {
            entries.removeValue(forKey: key)
            activeSet.remove(key)
        } else {
            entries[key] = entry
            recomputeActive(key: key)
        }
        markDirty()
    }

    func unlearn(word: String, lang: String) {
        guard isValid(word: word, lang: lang) else { return }
        let key = makeKey(word: word, lang: lang)
        guard entries.removeValue(forKey: key) != nil else { return }
        activeSet.remove(key)
        markDirty()
    }

    func removeAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        activeSet.removeAll()
        markDirty()
    }

    // MARK: - Queries

    func isActive(word: String, lang: String) -> Bool {
        activeSet.contains(makeKey(word: word, lang: lang))
    }

    /// Words (not composite keys) of `lang` currently eligible for automatic
    /// correction — this is what `KeyboardMonitor` hands to
    /// `InstantCorrectionAnalyzer.evaluate(learnedActive:)` / the boundary
    /// path as a plain `Set<String>`.
    func activeKeys(lang: String) -> Set<String> {
        let prefix = lang + ":"
        var result: Set<String> = []
        for key in activeSet where key.hasPrefix(prefix) {
            result.insert(String(key.dropFirst(prefix.count)))
        }
        return result
    }

    var allEntries: [String: LearnedWordEntry] { entries }

    // MARK: - Persistence (no disk I/O on the hot path)

    /// Persists pending mutations. Safe to call from a ~30s timer; a no-op
    /// when nothing changed since the last flush.
    func flush(now: Date) {
        guard dirty else { return }
        persist()
        dirty = false
    }

    private func persist() {
        let payload = entries.mapValues { entry in
            PersistedEntry(
                count: entry.count,
                firstConfirmed: entry.firstConfirmed.timeIntervalSince1970,
                lastConfirmed: entry.lastConfirmed.timeIntervalSince1970,
                originApp: entry.originApp
            )
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: persistKey)
    }

    private func load() {
        guard let data = defaults.data(forKey: persistKey),
              let payload = try? JSONDecoder().decode([String: PersistedEntry].self, from: data) else { return }
        entries = payload.mapValues { p in
            LearnedWordEntry(
                count: p.count,
                firstConfirmed: Date(timeIntervalSince1970: p.firstConfirmed),
                lastConfirmed: Date(timeIntervalSince1970: p.lastConfirmed),
                originApp: p.originApp
            )
        }
        recomputeAllActive()
    }

    private struct PersistedEntry: Codable {
        let count: Int
        let firstConfirmed: TimeInterval
        let lastConfirmed: TimeInterval
        let originApp: String?
    }

    // MARK: - Helpers

    private func markDirty() { dirty = true }

    private func isValid(word: String, lang: String) -> Bool {
        !word.isEmpty && !lang.isEmpty && word == word.lowercased()
    }

    private func makeKey(word: String, lang: String) -> String {
        "\(lang):\(word)"
    }

    private func isEntryActive(_ entry: LearnedWordEntry) -> Bool {
        entry.count >= 2 && entry.lastConfirmed.timeIntervalSince(entry.firstConfirmed) <= promotionWindow
    }

    private func recomputeActive(key: String) {
        guard let entry = entries[key] else {
            activeSet.remove(key)
            return
        }
        if isEnabled && isEntryActive(entry) {
            activeSet.insert(key)
        } else {
            activeSet.remove(key)
        }
    }

    private func recomputeAllActive() {
        activeSet.removeAll()
        guard isEnabled else { return }
        for (key, entry) in entries where isEntryActive(entry) {
            activeSet.insert(key)
        }
    }

    /// Evicts entries with `count == 1` first (oldest `lastConfirmed`
    /// first), then falls back to plain LRU across the rest, until the
    /// store is back at `cap`. Returns whether anything was evicted.
    @discardableResult
    private func enforceCap() -> Bool {
        guard entries.count > cap else { return false }
        var evictedAny = false
        while entries.count > cap {
            if let victim = entries.filter({ $0.value.count == 1 })
                .min(by: { $0.value.lastConfirmed < $1.value.lastConfirmed }) {
                entries.removeValue(forKey: victim.key)
                activeSet.remove(victim.key)
                evictedAny = true
                continue
            }
            guard let victim = entries.min(by: { $0.value.lastConfirmed < $1.value.lastConfirmed }) else { break }
            entries.removeValue(forKey: victim.key)
            activeSet.remove(victim.key)
            evictedAny = true
        }
        return evictedAny
    }
}
