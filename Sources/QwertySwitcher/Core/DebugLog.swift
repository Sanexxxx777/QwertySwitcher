import Foundation

/// `.normal` is always written. `.verbose` is dropped unless the user turned
/// on "Подробный лог" (`PreferencesService.isVerboseLogEnabled`) — reserved
/// for per-word telemetry (`detect: noSwitch`, `word too short`) that made up
/// 72% of a real user's log and drowned out the events worth reading.
enum DebugLogLevel {
    case normal
    case verbose
}

/// Compact debug logger. Writes to `~/Library/Logs/QwertySwitcher/debug.log`.
/// Rotates at 512 KB into `debug.1.log` (keeps exactly two files, ≤1MB total)
/// instead of truncating — the old scheme kept only the last 10KB of a 1MB
/// file, destroying most of the history needed to debug a reported issue.
/// Privacy-first: we log metadata (lengths, language codes, scores, event
/// kinds) — never the word itself.
final class DebugLog {
    static let shared = DebugLog()

    private let fm = FileManager.default
    private let url: URL
    private let rotatedURL: URL
    private let queue = DispatchQueue(label: AppIdentity.keyPrefix + "debuglog", qos: .utility)
    private let maxBytes = 512_000    // rotate at 512 KB, keeping at most 2 files
    /// Age cap, checked once per launch. Size alone bounds disk use (≤1MB
    /// total) but says nothing about how long a record of someone's typing
    /// sits around: on a quiet week the same file survives for months. This
    /// is a privacy bound, not a disk one — the log's whole purpose is
    /// diagnosing something that just happened.
    private let maxAgeDays = 5
    private let iso: ISO8601DateFormatter
    private let compact: DateFormatter
    private let verboseKey = AppIdentity.keyPrefix + "verboseLog"
    /// One append-only handle kept open for the life of the process instead
    /// of open/seek/close per line; `currentFileSize` tracks size in memory
    /// so rotation no longer stats the file on every write. Both live only
    /// on `queue` (see `openHandleIfNeeded`/`write`/`rotate`) — the one
    /// direct call from `init` runs before `shared` is reachable from any
    /// other thread, so it never races the queue.
    private var writeHandle: FileHandle?
    private var currentFileSize = 0

    /// `directory` is injectable for tests only — production always uses the
    /// default `~/Library/Logs/QwertySwitcher`, UNLESS `QSW_LOG_DIR` is set
    /// in the environment (see `defaultLogsDirectory`).
    init(directory: URL? = nil) {
        let logsDir = directory ?? Self.defaultLogsDirectory()
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logsDir.path)
        for name in ["debug.log", "debug.1.log", "update.log"] {
            try? fm.setAttributes([.posixPermissions: 0o600],
                                  ofItemAtPath: logsDir.appendingPathComponent(name).path)
        }
        url = logsDir.appendingPathComponent("debug.log")
        rotatedURL = logsDir.appendingPathComponent("debug.1.log")

        iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        compact = DateFormatter()
        compact.dateFormat = "HH:mm:ss.SSS"
        compact.locale = Locale(identifier: "en_US_POSIX")

        pruneAgedLogs(now: Date())

        // Mark app start
        write(module: "APP", event: "---- session start \(iso.string(from: Date())) ----", at: Date())
    }

    /// Pure age decision, extracted so the retention rule is testable without
    /// waiting five days or backdating a real file.
    static func isExpired(created: Date, now: Date, maxAgeDays: Int) -> Bool {
        now.timeIntervalSince(created) > Double(maxAgeDays) * 24 * 60 * 60
    }

    /// Deletes either log file whose FIRST line is older than the cap. Keyed on
    /// creation date, not modification: the active file is touched on every
    /// write, so its mtime is always "now" and would never expire no matter how
    /// far back its earliest entries go.
    private func pruneAgedLogs(now: Date) {
        for candidate in [url, rotatedURL] {
            guard let created = (try? fm.attributesOfItem(atPath: candidate.path))?[.creationDate] as? Date,
                  Self.isExpired(created: created, now: now, maxAgeDays: maxAgeDays)
            else { continue }
            try? fm.removeItem(at: candidate)
        }
    }

    /// Compact log line: `HH:mm:ss.SSS [MOD] event`. `.verbose` events are
    /// dropped before ever reaching the write queue when verbose logging is
    /// off — `event` is `@autoclosure` so its string interpolation is never
    /// built in that case either. The timestamp is captured HERE, on the
    /// caller's thread, before the write is dispatched to `queue`: the queue
    /// can be backed up (a burst of calls, or a slow disk), and a timestamp
    /// taken at write time would then record when the line was FLUSHED, not
    /// when the event actually happened — turning a busy log into false
    /// evidence about event timing.
    func log(_ module: String, _ event: @autoclosure () -> String, level: DebugLogLevel = .normal) {
        if level == .verbose && !isVerboseEnabled { return }
        let message = event()
        let now = Date()
        queue.async { [weak self] in
            self?.write(module: module, event: message, at: now)
        }
    }

    /// Synchronously fetch the current log contents (for the "Show logs" menu).
    var currentContents: String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    var fileURL: URL { url }

    /// Blocks until all previously queued log writes have completed. Test-only.
    func waitForPendingWrites() {
        queue.sync {}
    }

    // MARK: - Private

    private var isVerboseEnabled: Bool {
        UserDefaults.standard.bool(forKey: verboseKey)
    }

    private func write(module: String, event: String, at date: Date) {
        let line = "\(compact.string(from: date)) [\(module)] \(event)\n"
        guard let data = line.data(using: .utf8) else { return }

        // The file — or its whole directory — can disappear out from under
        // a held-open handle: by hand, or via
        // `PrivacyService.deleteAllLocalData()`, which removes the entire
        // logs directory. A handle open on the now-unlinked inode keeps
        // writing successfully and silently into nothing. This runs on
        // `queue`, never the tap thread, so one extra `fileExists` stat per
        // line is fine — drop the stale handle so `openHandleIfNeeded`
        // below is forced to recreate directory + file instead of reusing
        // a handle to a deleted inode.
        if writeHandle != nil, !fm.fileExists(atPath: url.path) {
            try? writeHandle?.close()
            writeHandle = nil
        }
        guard let handle = openHandleIfNeeded() else { return }

        try? handle.write(contentsOf: data)
        currentFileSize += data.count

        // Rotate if oversized
        if currentFileSize > maxBytes {
            rotate()
        }
    }

    /// Returns the one long-lived append handle, opening it on first use (or
    /// after `write` dropped a stale one). Recreates the logs directory
    /// (0700) if it's gone, then the file (0600) if it's gone — covers both
    /// "file deleted" and "whole directory deleted" the same way `init` sets
    /// them up originally. Called only from `write`, which itself only ever
    /// runs on `queue`.
    private func openHandleIfNeeded() -> FileHandle? {
        if let writeHandle { return writeHandle }
        let logsDir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: logsDir.path) {
            try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                return nil
            }
            currentFileSize = 0
        } else {
            currentFileSize = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        writeHandle = handle
        return handle
    }

    /// Renames the full (already-oversized) `debug.log` to `debug.1.log`,
    /// overwriting whatever was there before, and lets the next write start a
    /// fresh `debug.log`. Nothing is truncated — the old file's entire
    /// content survives one rotation back. The handle is closed and reopened
    /// around the rename — a handle keeps writing to the same inode after a
    /// rename, which would silently keep appending to what is now `debug.1.log`.
    private func rotate() {
        try? writeHandle?.close()
        writeHandle = nil
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: url, to: rotatedURL)
        currentFileSize = 0
    }

    /// Test isolation (incident 05.08.2026): `DebugLog.shared` is a true
    /// process-wide singleton, but its default directory used to be a bare
    /// folder NAME (`Logs/QwertySwitcher`), not scoped by bundle ID or
    /// process — the standalone test binary (`QwertySwitcher --test`) landed
    /// in the exact same path as the installed app, so running the suite
    /// interleaved "session start"/"LIC activate…" test noise into the
    /// owner's real, user-facing log and made it useless for diagnosis.
    /// Primary defense is the `--test` launch argument itself (same signal
    /// `main.swift` uses to pick the headless test path, and `InputSourceManager`
    /// uses for the matching layout-switch isolation): a plain `--test` run
    /// always lands under a scratch temp directory, no cooperation from
    /// `Scripts/test.sh` required. `QSW_LOG_DIR` remains an explicit override
    /// on top (set by `Scripts/test.sh` so a failed run's log has a stable,
    /// inspectable path instead of a throwaway one). Production (no `--test`
    /// argument, no env var set) is completely unaffected either way.
    private static func defaultLogsDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["QSW_LOG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if TestRunMode.isActive {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("QwertySwitcherTestLogs", isDirectory: true)
        }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/QwertySwitcher", isDirectory: true)
    }
}
