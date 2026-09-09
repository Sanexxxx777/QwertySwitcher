import Foundation

enum StorageMigrationService {
    private static let markerKey = AppIdentity.keyPrefix + "migration.v1"
    private static let licensePurgeMarkerKey = AppIdentity.keyPrefix + "migration.v2"

    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        migrateLegacyKeysIfNeeded(defaults: defaults)
        purgeLicenseLeftoversIfNeeded(defaults: defaults)
    }

    private static func migrateLegacyKeysIfNeeded(defaults: UserDefaults) {
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

    /// v2 (0.11.0): the subscription/trial/licence contour was removed in
    /// 0.10.0, but its UserDefaults rows outlived it on every existing install
    /// (found 10.09.2026: `licenseFirstSeen.<hwid-uuid>` still on the owner's
    /// Mac). Removed once, marker-guarded like v1. Pure key selection is
    /// exposed for the test suite.
    static func purgeLicenseLeftoversIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: licensePurgeMarkerKey) else { return }
        let stale = staleLicenseKeys(in: Array(defaults.dictionaryRepresentation().keys))
        for key in stale { defaults.removeObject(forKey: key) }
        defaults.set(true, forKey: licensePurgeMarkerKey)
        DebugLog.shared.log("MIGRATION", "license leftovers removed: \(stale.count)")
    }

    static let licenseLeftoverPrefixes = [
        "licenseFirstSeen.", "license.", "licenseKey", "licenseState",
        "trial.", "trialStart", "trialFirstSeen", "deviceId", "hwid",
    ].map { AppIdentity.keyPrefix + $0 }

    static func staleLicenseKeys(in keys: [String]) -> [String] {
        keys.filter { key in licenseLeftoverPrefixes.contains { key.hasPrefix($0) } }.sorted()
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
