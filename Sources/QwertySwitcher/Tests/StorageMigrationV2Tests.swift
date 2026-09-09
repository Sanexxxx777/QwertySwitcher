import Foundation

/// v2 storage migration (0.11.0): licence/trial rows left behind by the
/// 0.10.0 removal are purged once. Uses a throwaway UserDefaults suite so the
/// owner's real preferences are never touched by a test run.
enum StorageMigrationV2Tests {
    static func run() {
        TestRunner.section("Storage migration v2 — licence leftovers purged once")

        let prefix = AppIdentity.keyPrefix
        let keys = [
            prefix + "licenseFirstSeen.33E452AA-426D-52D4-99E0-A6384EDF266A",
            prefix + "autoEnabled",
            prefix + "trialStart",
            prefix + "learnedWords",
            "com.apple.unrelated.license.key",
        ]
        let stale = StorageMigrationService.staleLicenseKeys(in: keys)
        TestRunner.assertEqual(
            stale,
            [prefix + "licenseFirstSeen.33E452AA-426D-52D4-99E0-A6384EDF266A", prefix + "trialStart"],
            "only our own licence/trial rows are selected — settings and foreign domains untouched"
        )

        let suiteName = prefix + "tests.migration.v2"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            TestRunner.assertTrue(false, "throwaway UserDefaults suite could not be created")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        defaults.set("2026-08-09", forKey: prefix + "licenseFirstSeen.TEST-UUID")
        defaults.set(true, forKey: prefix + "autoEnabled")

        StorageMigrationService.purgeLicenseLeftoversIfNeeded(defaults: defaults)
        TestRunner.assertNil(
            defaults.object(forKey: prefix + "licenseFirstSeen.TEST-UUID"),
            "licence row removed"
        )
        TestRunner.assertTrue(
            defaults.bool(forKey: prefix + "autoEnabled"),
            "ordinary setting survives the purge"
        )
        TestRunner.assertTrue(
            defaults.bool(forKey: prefix + "migration.v2"),
            "v2 marker written"
        )

        // Marker guards the second run: a row re-created later is NOT purged
        // again (no silent background deletion of anything named like it).
        defaults.set("again", forKey: prefix + "licenseFirstSeen.TEST-UUID")
        StorageMigrationService.purgeLicenseLeftoversIfNeeded(defaults: defaults)
        TestRunner.assertEqual(
            defaults.string(forKey: prefix + "licenseFirstSeen.TEST-UUID"),
            "again",
            "purge is one-shot — marker prevents a second pass"
        )
    }
}
