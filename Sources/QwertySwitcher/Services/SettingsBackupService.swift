import Foundation

struct SettingsBackup: Codable, Equatable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let createdAt: Int64
    let preferences: PreferencesBackup
    let wordExceptions: [String]
    let appProfiles: [String: AppProfile]
    let autoLearned: [String: String]
    let snippets: [String: String]
    let perAppLayoutEnabled: Bool
    let manualLayoutOverrides: [String: String]
    let rememberedLayouts: [String: String]
    /// Mechanism A (`LearnedWordsStore`) only — learning_spec.md is explicit
    /// that Mechanism C (`PersonalFrequencyStore`) never leaves the Mac, so
    /// no field for it exists here at all (not merely omitted at export
    /// time — there is nothing in this type a future call site could fill
    /// in by accident).
    let learnedWords: [LearnedWordBackupEntry]
}

/// Backup-only Codable projection of `LearnedWordEntry` — the composite
/// `"lang:word"` store key split into plain fields, dates as epoch seconds.
/// Deliberately NOT `LearnedWordsStore`'s own persistence format: keeps this
/// file's (de)serialization independent of that store's internal encoding.
struct LearnedWordBackupEntry: Codable, Equatable {
    let lang: String
    let word: String
    let count: Int
    let firstConfirmed: Int64
    let lastConfirmed: Int64
    let originApp: String?
}

struct PreferencesBackup: Codable, Equatable {
    let autoSwitchEnabled: Bool
    let soundEnabled: Bool
    let layoutSoundEnabled: Bool
    let layoutSoundName: String
    let yoficatorEnabled: Bool
    let splitShiftEnabled: Bool
    let pasteNoFormatEnabled: Bool
    let singleShiftEnabled: Bool
    let doubleShiftEnabled: Bool
    let capsLockSwitchEnabled: Bool
    let instantCorrectionEnabled: Bool
    let snippetExpansionEnabled: Bool
    let smartCaseEnabled: Bool
    let verboseLogEnabled: Bool
    let activeLayoutIDs: [String]
    let themePreference: String
}

final class SettingsBackupService {
    enum BackupError: LocalizedError {
        case unsupportedVersion(Int)
        case invalidData(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "Версия резервной копии \(version) не поддерживается"
            case .invalidData(let detail):
                return "Некорректная резервная копия: \(detail)"
            }
        }
    }

    private let prefsService: PreferencesService
    private let exceptionsService: ExceptionsService
    private let perAppLayoutService: PerAppLayoutService
    private let snippetService: SnippetService
    private let learnedWordsStore: LearnedWordsStore

    init(
        prefsService: PreferencesService,
        exceptionsService: ExceptionsService,
        perAppLayoutService: PerAppLayoutService,
        snippetService: SnippetService,
        // Defaulted so the existing call site needs no change (same pattern
        // as `KeyboardMonitor`'s own default): reads/writes the same
        // `AppIdentity.keyPrefix + "learnedWords"` UserDefaults key that the
        // live `KeyboardMonitor`-owned store persists to. Caveat (out of
        // this wave's file boundary to close): a backup taken via this
        // default reflects only what's already been flushed to disk (up to
        // the ~30s flush interval), and an import writes through to disk
        // but the running process's in-memory store won't see it until
        // restart — passing the SAME instance `KeyboardMonitor` owns
        // removes both caveats.
        learnedWordsStore: LearnedWordsStore = LearnedWordsStore()
    ) {
        self.prefsService = prefsService
        self.exceptionsService = exceptionsService
        self.perAppLayoutService = perAppLayoutService
        self.snippetService = snippetService
        self.learnedWordsStore = learnedWordsStore
    }

    func makeBackup(now: Date = Date()) -> SettingsBackup {
        SettingsBackup(
            formatVersion: SettingsBackup.currentFormatVersion,
            createdAt: Int64(now.timeIntervalSince1970),
            preferences: PreferencesBackup(
                autoSwitchEnabled: prefsService.isAutoSwitchEnabled,
                soundEnabled: prefsService.isSoundEnabled,
                layoutSoundEnabled: prefsService.isLayoutSoundEnabled,
                layoutSoundName: prefsService.layoutSoundName,
                yoficatorEnabled: prefsService.isYoficatorEnabled,
                splitShiftEnabled: prefsService.isSplitShiftEnabled,
                pasteNoFormatEnabled: prefsService.isPasteNoFormatEnabled,
                singleShiftEnabled: prefsService.isSingleShiftEnabled,
                doubleShiftEnabled: prefsService.isDoubleShiftEnabled,
                capsLockSwitchEnabled: prefsService.isCapsLockSwitchEnabled,
                instantCorrectionEnabled: prefsService.isInstantCorrectionEnabled,
                snippetExpansionEnabled: prefsService.isSnippetExpansionEnabled,
                smartCaseEnabled: prefsService.isSmartCaseEnabled,
                verboseLogEnabled: prefsService.isVerboseLogEnabled,
                activeLayoutIDs: prefsService.activeLayoutIDs,
                themePreference: prefsService.themePreference.rawValue
            ),
            wordExceptions: exceptionsService.wordExceptions.sorted(),
            appProfiles: exceptionsService.appProfiles,
            autoLearned: exceptionsService.autoLearned,
            snippets: snippetService.snippets,
            perAppLayoutEnabled: perAppLayoutService.isEnabled,
            manualLayoutOverrides: perAppLayoutService.manualOverrides,
            rememberedLayouts: perAppLayoutService.rememberedLayouts,
            learnedWords: Self.learnedWordBackupEntries(from: learnedWordsStore)
        )
    }

    /// Splits `LearnedWordsStore`'s `"lang:word"` composite key back into
    /// plain fields. Sorted for a deterministic (diffable) JSON export —
    /// `allEntries`' dictionary order is not guaranteed.
    private static func learnedWordBackupEntries(from store: LearnedWordsStore) -> [LearnedWordBackupEntry] {
        store.allEntries.compactMap { key, entry -> LearnedWordBackupEntry? in
            guard let separator = key.firstIndex(of: ":") else { return nil }
            let lang = String(key[key.startIndex..<separator])
            let word = String(key[key.index(after: separator)...])
            guard !lang.isEmpty, !word.isEmpty else { return nil }
            return LearnedWordBackupEntry(
                lang: lang, word: word, count: entry.count,
                firstConfirmed: Int64(entry.firstConfirmed.timeIntervalSince1970),
                lastConfirmed: Int64(entry.lastConfirmed.timeIntervalSince1970),
                originApp: entry.originApp
            )
        }.sorted { $0.lang == $1.lang ? $0.word < $1.word : $0.lang < $1.lang }
    }

    func encodedBackup(now: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(makeBackup(now: now))
    }

    func decodeAndValidate(_ data: Data) throws -> SettingsBackup {
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: data)
        guard backup.formatVersion == SettingsBackup.currentFormatVersion else {
            throw BackupError.unsupportedVersion(backup.formatVersion)
        }
        guard backup.wordExceptions.count <= 10_000 else {
            throw BackupError.invalidData("слишком много слов-исключений")
        }
        guard backup.appProfiles.count <= 2_000,
              backup.manualLayoutOverrides.count <= 2_000,
              backup.rememberedLayouts.count <= 2_000 else {
            throw BackupError.invalidData("слишком много профилей приложений")
        }
        guard backup.autoLearned.count <= 10_000 else {
            throw BackupError.invalidData("слишком много обученных пар")
        }
        guard backup.snippets.count <= 2_000,
              backup.snippets.allSatisfy({ trigger, replacement in
                  snippetService.isValidTrigger(trigger)
                      && snippetService.isValidReplacement(replacement)
              }) else {
            throw BackupError.invalidData("недопустимые текстовые шаблоны")
        }
        guard backup.preferences.activeLayoutIDs.count <= 2 else {
            throw BackupError.invalidData("должно быть не больше двух активных раскладок")
        }
        guard backup.preferences.layoutSoundName.count <= 100 else {
            throw BackupError.invalidData("слишком длинное имя звука")
        }
        guard backup.wordExceptions.allSatisfy(exceptionsService.isValidException) else {
            throw BackupError.invalidData("недопустимое слово-исключение")
        }
        let bundleIDs = Set(backup.appProfiles.keys)
            .union(backup.manualLayoutOverrides.keys)
            .union(backup.rememberedLayouts.keys)
        guard bundleIDs.allSatisfy(Self.isValidBundleID) else {
            throw BackupError.invalidData("недопустимый bundle ID")
        }
        guard backup.autoLearned.allSatisfy({ key, value in
            !key.isEmpty && key.count <= 100 && !value.isEmpty && value.count <= 100
        }) else {
            throw BackupError.invalidData("недопустимая обученная пара")
        }
        // Same cap as `LearnedWordsStore`'s own eviction ceiling.
        guard backup.learnedWords.count <= 300 else {
            throw BackupError.invalidData("слишком много выученных слов")
        }
        guard backup.learnedWords.allSatisfy(Self.isValidLearnedWordBackupEntry) else {
            throw BackupError.invalidData("недопустимая запись выученного слова")
        }
        return backup
    }

    private static func isValidLearnedWordBackupEntry(_ entry: LearnedWordBackupEntry) -> Bool {
        !entry.lang.isEmpty && entry.lang.count <= 10
            && !entry.word.isEmpty && entry.word.count <= 100 && entry.word == entry.word.lowercased()
            // `LearnedWordsStore.recordManualFix` is replayed `count` times on
            // import (see `importBackup`) — a bound well above anything real
            // usage produces keeps a malformed/hostile file from turning
            // import into an unbounded loop.
            && entry.count >= 1 && entry.count <= 100
            && entry.firstConfirmed <= entry.lastConfirmed
            && (entry.originApp?.count ?? 0) <= 255
    }

    func importBackup(_ data: Data) throws {
        let backup = try decodeAndValidate(data)
        let prefs = backup.preferences
        prefsService.isAutoSwitchEnabled = prefs.autoSwitchEnabled
        prefsService.isSoundEnabled = prefs.soundEnabled
        prefsService.isLayoutSoundEnabled = prefs.layoutSoundEnabled
        prefsService.layoutSoundName = prefs.layoutSoundName
        prefsService.isYoficatorEnabled = prefs.yoficatorEnabled
        prefsService.isSplitShiftEnabled = prefs.splitShiftEnabled
        prefsService.isPasteNoFormatEnabled = prefs.pasteNoFormatEnabled
        prefsService.isSingleShiftEnabled = prefs.singleShiftEnabled
        prefsService.isDoubleShiftEnabled = prefs.doubleShiftEnabled
        prefsService.isCapsLockSwitchEnabled = prefs.capsLockSwitchEnabled
        prefsService.isInstantCorrectionEnabled = prefs.instantCorrectionEnabled
        prefsService.isSnippetExpansionEnabled = prefs.snippetExpansionEnabled
        prefsService.isSmartCaseEnabled = prefs.smartCaseEnabled
        prefsService.isVerboseLogEnabled = prefs.verboseLogEnabled
        prefsService.activeLayoutIDs = prefs.activeLayoutIDs
        prefsService.themePreference = ThemePreference(rawValue: prefs.themePreference) ?? .system
        exceptionsService.wordExceptions = Set(backup.wordExceptions)
        exceptionsService.appProfiles = backup.appProfiles
        exceptionsService.autoLearned = backup.autoLearned
        snippetService.snippets = backup.snippets
        perAppLayoutService.isEnabled = backup.perAppLayoutEnabled
        perAppLayoutService.manualOverrides = backup.manualLayoutOverrides
        perAppLayoutService.replaceRememberedLayouts(backup.rememberedLayouts)
        // Same "replace" policy as the exceptions above. `LearnedWordsStore`
        // exposes no bulk setter (wave 3's file boundary keeps that store's
        // contract untouched — read-only for the UI), so `removeAll()` +
        // replaying `recordManualFix` the exact `count` times it takes to
        // reach each entry's stored count is the only way to reconstruct
        // (count, firstConfirmed, lastConfirmed, originApp) through the
        // store's own already-tested state machine. Safe by construction:
        // any entry that reached `count >= 2` in the live app already
        // satisfies `lastConfirmed - firstConfirmed <= promotionWindow`
        // (`recordManualFix` resets to count 1 otherwise), so replaying the
        // first confirmation at `firstConfirmed` and the rest at
        // `lastConfirmed` never crosses the 30-day reset itself.
        learnedWordsStore.removeAll()
        for entry in backup.learnedWords {
            let first = Date(timeIntervalSince1970: TimeInterval(entry.firstConfirmed))
            let last = Date(timeIntervalSince1970: TimeInterval(entry.lastConfirmed))
            learnedWordsStore.recordManualFix(word: entry.word, lang: entry.lang, originApp: entry.originApp, at: first)
            if entry.count > 1 {
                for _ in 1..<entry.count {
                    learnedWordsStore.recordManualFix(
                        word: entry.word, lang: entry.lang, originApp: entry.originApp, at: last
                    )
                }
            }
        }
        NotificationCenter.default.post(name: .settingsImported, object: self)
        NotificationCenter.default.post(name: .autoSwitchToggled, object: self)
        NotificationCenter.default.post(name: .activeLayoutsChanged, object: self)
        NotificationCenter.default.post(name: .themePreferenceChanged, object: self)
    }

    private static func isValidBundleID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

extension Notification.Name {
    static let settingsImported = Notification.Name(AppIdentity.keyPrefix + "settingsImported")
}
