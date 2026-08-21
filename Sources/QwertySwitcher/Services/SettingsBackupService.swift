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

    init(
        prefsService: PreferencesService,
        exceptionsService: ExceptionsService,
        perAppLayoutService: PerAppLayoutService,
        snippetService: SnippetService
    ) {
        self.prefsService = prefsService
        self.exceptionsService = exceptionsService
        self.perAppLayoutService = perAppLayoutService
        self.snippetService = snippetService
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
            rememberedLayouts: perAppLayoutService.rememberedLayouts
        )
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
        return backup
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
