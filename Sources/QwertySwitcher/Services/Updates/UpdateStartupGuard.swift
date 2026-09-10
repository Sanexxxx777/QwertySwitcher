import Foundation

/// Runs once, very early in a NORMAL launch (before `NSApplication` is
/// created — see `main.swift`; never during `--test` or `--install-update`).
enum UpdateStartupGuard {
    /// False means: the caller should quietly `exit(0)` instead of running —
    /// a transaction targeting this install is still live, so this launch is
    /// a spurious duplicate (e.g. `open` racing the helper's own bookkeeping).
    static func shouldProceedWithNormalLaunch(now: Date = Date()) -> Bool {
        let url = UpdateTransactionMarker.markerURL()
        guard let marker = UpdateTransactionMarker.read(at: url) else { return true }
        return !marker.isLive(now: now.timeIntervalSince1970, pidIsAlive: pidIsAlive)
    }

    static func pidIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Garbage-collects stage directories left over from previous
    /// checks/installs and records the build that just started successfully
    /// — the anti-rollback floor `UpdatePolicy.evaluate` reads back next
    /// time as `lastSeenBuild`.
    static func onNormalLaunchStarted(prefs: PreferencesService) {
        cleanupOldStages()
        if let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init), build > 0 {
            prefs.updatesLastSeenBuild = build
        }
    }

    private static func cleanupOldStages() {
        let root = UpdateStager.updatesRootDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent != ".transaction" && entry.lastPathComponent != ".broken" {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
