import Foundation
import Darwin

/// On 23.09.2026 three copies of the installed app ran at once — each with
/// its own live keyboard event tap, each independently correcting the
/// owner's text (a Double Shift on "fd" typed «ав» three times interleaved).
/// The trigger that let LaunchServices start a second copy is already fixed,
/// but nothing stopped a second copy started by any OTHER path (LaunchServices
/// edge cases, a copy run from a mounted DMG, a developer build). This is
/// that stop, independent of LaunchServices — which is exactly what failed.
///
/// The mechanism is an exclusive, non-blocking `flock(2)` on a fixed file:
/// the kernel releases the lock the instant the holding process's file
/// descriptor table goes away (normal exit, crash, `kill -9` — all included),
/// so there is no stale-lock file to detect or clean up, unlike a PID file.
enum SingleInstanceLock {
    /// `~/Library/Application Support/QwertySwitcher/instance.lock`.
    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent(AppIdentity.compactName)
            .appendingPathComponent("instance.lock")
    }

    enum Attempt: Equatable {
        /// This process holds the lock; `fd` must stay open for the rest of
        /// the process lifetime (closing it releases the lock).
        case locked(Int32)
        /// Another process already holds the lock. `holderPid` is read from
        /// the file for diagnostics only — best-effort, may be nil.
        case busy(holderPid: Int32?)
        /// Could not create/open the lock file at all (permissions, missing
        /// volume, anything other than the lock being held). Carries `errno`.
        case unavailable(Int32)
    }

    /// Single attempt: create the parent directory (0700) and lock file
    /// (0600) if missing, open it, and try to take an exclusive non-blocking
    /// flock. Never blocks.
    static func tryLock(at url: URL) -> Attempt {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            return .unavailable(errno)
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            if failure == EWOULDBLOCK {
                let holderPid = readHolderPID(fd: fd)
                close(fd)
                return .busy(holderPid: holderPid)
            }
            close(fd)
            return .unavailable(failure)
        }

        writeOwnPID(fd: fd)
        return .locked(fd)
    }

    /// Retries `tryLock` while it reports `.busy`, up to `waitSeconds` (a
    /// relaunch — onboarding «Перезапустить приложение», the updater,
    /// `install.sh` — can start the new copy while the old one is still
    /// exiting and has not yet released the lock).
    static func acquire(at url: URL, waitSeconds: TimeInterval = 5, pollInterval: TimeInterval = 0.1) -> Attempt {
        let deadline = Date().addingTimeInterval(waitSeconds)
        while true {
            let attempt = tryLock(at: url)
            guard case .busy = attempt, Date() < deadline else {
                return attempt
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    /// Only `.busy` means a live copy is already running. `.unavailable`
    /// (lock infrastructure broken) must never keep the switcher from
    /// starting — it logs a warning and starts normally instead.
    static func shouldExit(for attempt: Attempt) -> Bool {
        if case .busy = attempt { return true }
        return false
    }

    // MARK: - Private

    private static func readHolderPID(fd: Int32) -> Int32? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let bytesRead = buffer.withUnsafeMutableBytes { raw in
            pread(fd, raw.baseAddress, raw.count, 0)
        }
        guard bytesRead > 0 else { return nil }
        let text = String(decoding: buffer[0..<bytesRead], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int32(text)
    }

    private static func writeOwnPID(fd: Int32) {
        let text = "\(getpid())\n"
        guard let data = text.data(using: .utf8) else { return }
        ftruncate(fd, 0)
        data.withUnsafeBytes { raw in
            _ = pwrite(fd, raw.baseAddress, raw.count, 0)
        }
    }
}
