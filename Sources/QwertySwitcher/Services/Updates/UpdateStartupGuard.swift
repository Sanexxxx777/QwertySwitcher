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
    /// `currentBuild` is injectable (defaults to reading `Bundle.main`, same
    /// as every other production call site) — the debug test binary is a
    /// bare Mach-O, not wrapped in a `.app` bundle, so `Bundle.main` carries
    /// no real `Info.plist` there and `CFBundleVersion` reads back nil. Tests
    /// pass an explicit value instead of relying on that environment quirk.
    static func onNormalLaunchStarted(prefs: PreferencesService, currentBuild: Int? = nil) {
        let build = currentBuild ?? (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0
        cleanupOldStages(currentBuild: build)
        if build > 0 {
            // CRITICAL fix (security review): a plain assignment here means
            // ANY launch of an OLDER build (e.g. a rollback the owner did on
            // purpose, or a stale second copy) would silently LOWER the
            // anti-rollback floor, undoing what `UpdatePolicy.evaluate`'s
            // `lastSeenBuild` check exists to prevent. The floor may only
            // ever move up.
            prefs.updatesLastSeenBuild = max(prefs.updatesLastSeenBuild, build)
        }
    }

    /// CRITICAL fix (security review): this used to delete EVERYTHING under
    /// the updates root unconditionally, including `<stage>/backup` for a
    /// helper that might still be mid-flight (the helper keeps running for
    /// up to ~15s after the sync to confirm the new build actually launched,
    /// and can still roll back in that window). Three independent guards:
    /// (1) never touch the stage a still-PRESENT `.transaction` marker names,
    /// regardless of its phase or liveness — the marker file existing at all
    /// means some helper hasn't finished cleaning up yet; (2) only consider
    /// stages older than an hour, well past any real install's lifetime;
    /// (3) for a stage that still has a `backup` subfolder, only remove it
    /// once the build it was staging is confirmed the one actually running
    /// now — read from the staged `.app`'s own Info.plist (the helper never
    /// deletes that file, only rsyncs FROM it).
    private static func cleanupOldStages(currentBuild: Int) {
        let root = UpdateStager.updatesRootDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        let protectedStage = UpdateTransactionMarker.read(at: UpdateTransactionMarker.markerURL(updatesRoot: root))?.stage
        let ageThreshold: TimeInterval = 60 * 60
        let now = Date()

        for entry in entries {
            let name = entry.lastPathComponent
            guard name != ".transaction", name != ".broken" else { continue }
            if let protectedStage, entry.path == protectedStage { continue }

            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? now
            guard now.timeIntervalSince(created) >= ageThreshold else { continue }

            let backup = entry.appendingPathComponent("backup")
            if FileManager.default.fileExists(atPath: backup.path) {
                guard stagedBuild(in: entry) == currentBuild else { continue }
            }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private static func stagedBuild(in stageDirectory: URL) -> Int? {
        guard let app = (try? FileManager.default.contentsOfDirectory(at: stageDirectory, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }),
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        else { return nil }
        return (info["CFBundleVersion"] as? String).flatMap(Int.init)
    }
}
