import Foundation

/// Pure decision functions for the updater — no I/O, no UserDefaults, no
/// network. `UpdateController` is the only caller in production; tests call
/// these directly.
enum UpdatePolicy {
    static let checkInterval: TimeInterval = 24 * 60 * 60
    static let failureBackoff: TimeInterval = 6 * 60 * 60
    static let firstCheckDelay: TimeInterval = 30
    static let minIdleSecondsForAutoInstall: TimeInterval = 120
    static let deferredInstallWindow: TimeInterval = 6 * 60 * 60

    /// Manual "Проверить сейчас" bypasses this entirely — it is only the gate
    /// for the automatic 24h cadence.
    static func shouldCheck(now: Date, lastCheckAt: Date?, lastFailureAt: Date?, autoCheck: Bool) -> Bool {
        guard autoCheck else { return false }
        if let lastFailureAt, now.timeIntervalSince(lastFailureAt) < failureBackoff {
            return false
        }
        guard let lastCheckAt else { return true }
        return now.timeIntervalSince(lastCheckAt) >= checkInterval
    }

    /// Whether an already-staged update may be installed automatically RIGHT
    /// NOW, without asking. All five conditions are independent gates — any
    /// one of them being false means "not now, keep waiting".
    static func shouldInstallNow(
        autoInstall: Bool,
        idleSeconds: TimeInterval,
        secureInput: Bool,
        replacing: Bool,
        gameModeActive: Bool
    ) -> Bool {
        guard autoInstall else { return false }
        guard idleSeconds >= minIdleSecondsForAutoInstall else { return false }
        guard !secureInput, !replacing, !gameModeActive else { return false }
        return true
    }

    enum Outcome: Equatable {
        case upToDate
        case available(UpdateManifest)
        /// Signed, well-formed, but its own `validUntil` is in the past —
        /// shown, never auto-installed.
        case feedStale
        /// `minSystemVersion` is newer than the running macOS — never offered.
        case systemTooOld
    }

    /// `build` must be strictly greater than the installed build AND not
    /// less than the highest build this Mac has ever successfully run
    /// (`lastSeenBuild`) — the second half of that guard is what makes a
    /// rollback of the feed to an older signed manifest a no-op instead of a
    /// downgrade.
    static func evaluate(
        manifest: UpdateManifest,
        installedBuild: Int,
        lastSeenBuild: Int,
        currentSystemVersion: OperatingSystemVersion,
        now: Date
    ) -> Outcome {
        if let validUntil = parseISO8601(manifest.validUntil), validUntil < now {
            return .feedStale
        }
        guard systemVersionSatisfies(minimum: manifest.minSystemVersion, current: currentSystemVersion) else {
            return .systemTooOld
        }
        guard manifest.build > installedBuild, manifest.build >= lastSeenBuild else {
            return .upToDate
        }
        return .available(manifest)
    }

    /// "13.0" / "13" / "13.0.1" style version strings, compared component-wise.
    static func systemVersionSatisfies(minimum: String, current: OperatingSystemVersion) -> Bool {
        let parts = minimum.split(separator: ".").compactMap { Int($0) }
        let minMajor = parts.count > 0 ? parts[0] : 0
        let minMinor = parts.count > 1 ? parts[1] : 0
        let minPatch = parts.count > 2 ? parts[2] : 0
        if current.majorVersion != minMajor { return current.majorVersion > minMajor }
        if current.minorVersion != minMinor { return current.minorVersion > minMinor }
        return current.patchVersion >= minPatch
    }

    /// Override feed URL accepted only as https, or http(s)://127.0.0.1 /
    /// localhost — the latter exists solely for local e2e testing.
    static func isAcceptableFeedURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased()
        else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && (host == "127.0.0.1" || host == "localhost")
    }

    static func parseISO8601(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
