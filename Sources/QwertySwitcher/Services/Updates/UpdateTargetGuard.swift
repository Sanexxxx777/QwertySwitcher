import Foundation

/// Whether the installed bundle can even be auto-updated in place. Not
/// writable by the current user, or a previous rollback attempt left the
/// `.broken` marker, means "notify only" — no retry loop hammering a target
/// that will never succeed.
enum UpdateTargetGuard {
    static func brokenMarkerURL() -> URL {
        UpdateStager.updatesRootDirectory().appendingPathComponent(".broken")
    }

    static func canAutoInstall(target: URL, fileManager: FileManager = .default) -> Bool {
        // MINOR fix (security review): the helper's own `install.sh` call
        // always targets a bundle literally named "Qwerty Switcher.app"
        // (hardcoded, same as `install.sh` itself) — a renamed installed
        // copy would make it create a SECOND bundle next to the real one
        // instead of updating it. Refuse before ever staging anything.
        guard target.lastPathComponent == "Qwerty Switcher.app" else { return false }
        guard fileManager.isWritableFile(atPath: target.deletingLastPathComponent().path) else { return false }
        guard !fileManager.fileExists(atPath: brokenMarkerURL().path) else { return false }
        return true
    }
}
