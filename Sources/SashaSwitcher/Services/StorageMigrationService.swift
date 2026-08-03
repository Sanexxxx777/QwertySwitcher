import Foundation

enum StorageMigrationService {
    private static let markerKey = AppIdentity.keyPrefix + "migration.v1"

    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: markerKey) else { return }

        let legacyDomain = defaults.persistentDomain(
            forName: AppIdentity.legacyBundleIdentifier
        ) ?? [:]
        let currentValues = defaults.dictionaryRepresentation()

        for oldKey in legacyKeys {
            let newKey = migratedKey(for: oldKey)
            guard currentValues[newKey] == nil else { continue }

            if let value = legacyDomain[oldKey] ?? currentValues[oldKey] {
                defaults.set(value, forKey: newKey)
            }
        }

        defaults.set(true, forKey: markerKey)
        DebugLog.shared.log("MIGRATION", "legacy preferences migration completed")
    }

    private static func migratedKey(for legacyKey: String) -> String {
        guard legacyKey.hasPrefix(AppIdentity.legacyKeyPrefix) else { return legacyKey }
        return AppIdentity.keyPrefix
            + legacyKey.dropFirst(AppIdentity.legacyKeyPrefix.count)
    }

    private static let legacyKeys = [
        "tech.sasha.switcher.autoEnabled",
        "tech.sasha.switcher.soundEnabled",
        "tech.sasha.switcher.yoficator",
        "tech.sasha.switcher.splitShift",
        "tech.sasha.switcher.pasteNoFormat",
        "tech.sasha.switcher.singleShift",
        "tech.sasha.switcher.doubleShift",
        "tech.sasha.switcher.wordExceptions",
        "tech.sasha.switcher.appExceptions",
        "tech.sasha.switcher.autoLearned",
        "tech.sasha.switcher.perAppLayouts.overrides",
        "tech.sasha.switcher.perAppLayouts.remembered",
        "tech.sasha.switcher.perAppLayouts.enabled",
        "tech.sasha.switcher.onboardingSeen",
        "tech.sasha.switcher.stats.firstLaunch",
        "tech.sasha.switcher.stats.autoSwitch",
        "tech.sasha.switcher.stats.typoFix",
        "tech.sasha.switcher.stats.shiftSwitch",
        "tech.sasha.switcher.stats.optionSwitch",
    ]
}
