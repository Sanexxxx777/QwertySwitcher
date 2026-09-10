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
        gameModeActive: Bool,
        screenLocked: Bool = false
    ) -> Bool {
        guard autoInstall else { return false }
        // A locked screen (field e2e 10.09.2026: loginwindow holds secure
        // input the whole time the Mac is locked, so the plain gates below
        // would defer for hours) is the SAFEST window there is — nobody is
        // typing into anything. Only an in-flight replacement transaction
        // still blocks, because that is the one thing a restart can corrupt.
        if screenLocked { return !replacing }
        guard idleSeconds >= minIdleSecondsForAutoInstall else { return false }
        guard !secureInput, !replacing, !gameModeActive else { return false }
        return true
    }

    /// Whether a MANUAL "Установить" click may install right now. Only the
    /// two gates that protect against actively destroying in-progress work
    /// apply — idle time and Game Mode exist to keep the automatic path
    /// silent/unsurprising, not to block an explicit user action.
    static func shouldInstallManuallyNow(secureInput: Bool, replacing: Bool) -> Bool {
        !secureInput && !replacing
    }

    /// Whether a NEW feed check may start. The 24h timer and the manual
    /// button both funnel through this so a scheduled tick can never stomp
    /// an already in-flight `.downloading`/`.installing`, and a manual click
    /// during one is a no-op rather than a second, racing `stage()` call.
    enum ActivityState { case idle, checking, downloading, installing }

    static func canStartNewCheck(current: ActivityState) -> Bool {
        current == .idle
    }

    enum Outcome: Equatable {
        case upToDate
        case available(UpdateManifest)
        /// Signed, well-formed, but its own `validUntil` is in the past —
        /// shown, never auto-installed. Carries the manifest so the UI can
        /// report how long ago the feed itself expired.
        case feedStale(UpdateManifest)
        /// `minSystemVersion` is newer than the running macOS — never
        /// offered. Carries the manifest so the UI can name the version and
        /// the macOS floor it needs.
        case systemTooOld(UpdateManifest)
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
            return .feedStale(manifest)
        }
        guard systemVersionSatisfies(minimum: manifest.minSystemVersion, current: currentSystemVersion) else {
            return .systemTooOld(manifest)
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
