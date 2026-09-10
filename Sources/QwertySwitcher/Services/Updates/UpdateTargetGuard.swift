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
        guard fileManager.isWritableFile(atPath: target.deletingLastPathComponent().path) else { return false }
        guard !fileManager.fileExists(atPath: brokenMarkerURL().path) else { return false }
        return true
    }
}
