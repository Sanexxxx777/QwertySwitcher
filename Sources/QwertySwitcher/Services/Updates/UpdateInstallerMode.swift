import Foundation
import Darwin

/// `--install-update` helper mode: this is the SAME app binary, launched
/// FROM THE STAGED copy (`Contents/MacOS/QwertySwitcher --install-update
/// --stage <stage> --target <installed> --parent-pid <pid>`), running
/// BEFORE `NSApplication` is created (see `main.swift`). The outgoing app
/// already quit itself before spawning this, so this file never shells out
/// to `osascript` to ask anything to quit. It also never passes
/// `--allow-identity-change` to the copied `install.sh` — `UpdateStager`
/// already refused to stage a build signed with a different identity than
/// the one at `target`, so that gate is expected to pass on its own.
enum UpdateInstallerMode {
    struct Arguments {
        let stage: URL
        let target: URL
        let parentPid: Int32
    }

    /// Skips the final "open the app and confirm a process from the bundle
    /// actually appears" step — that step's own timeout (15s) and its own
    /// rollback-on-no-launch make it unsuitable for a fast shell contract
    /// test, and launching a throwaway fixture bundle through LaunchServices
    /// is not something a CI-style test should depend on. Every other step
    /// (parent wait, straggler kill, install.sh, post-sync identity/signature
    /// re-check, rollback) runs exactly as in production.
    static var isTestMode: Bool {
        ProcessInfo.processInfo.environment["QSW_UPDATE_HELPER_TEST_MODE"] == "1"
    }

    static func parseArguments(_ raw: [String]) -> Arguments? {
        var stage: URL?
        var target: URL?
        var parentPid: Int32?
        var i = 0
        while i < raw.count {
            switch raw[i] {
            case "--stage" where i + 1 < raw.count:
                stage = URL(fileURLWithPath: raw[i + 1]); i += 2
            case "--target" where i + 1 < raw.count:
                target = URL(fileURLWithPath: raw[i + 1]); i += 2
            case "--parent-pid" where i + 1 < raw.count:
                parentPid = Int32(raw[i + 1]); i += 2
            default:
                i += 1
            }
        }
        guard let stage, let target, let parentPid else { return nil }
        return Arguments(stage: stage, target: target, parentPid: parentPid)
    }

    @discardableResult
    static func run(_ raw: [String] = Array(CommandLine.arguments.dropFirst())) -> Int32 {
        let log = HelperLog()
        guard let args = parseArguments(raw) else {
            log.write("missing --stage/--target/--parent-pid")
            return 2
        }
        return run(stage: args.stage, target: args.target, parentPid: args.parentPid, log: log)
    }

    static func run(stage: URL, target: URL, parentPid: Int32, log: HelperLog = HelperLog()) -> Int32 {
        log.write("=== install-update stage=\(stage.path) target=\(target.path) parentPid=\(parentPid) ===")

        // Never create a SECOND install location: install.sh's own dest is
        // computed from `target`'s parent directory + a hardcoded bundle
        // name, so a renamed target would make it build a sibling instead of
        // updating in place.
        guard target.lastPathComponent == "Qwerty Switcher.app" else {
            log.write("refusing: target bundle name is not 'Qwerty Switcher.app' (\(target.lastPathComponent)) — would create a second copy")
            return 11
        }

        // `--parent-pid 0` means "don't wait" — legitimate only from the
        // contract's own throwaway invocations. In production the launcher
        // always passes its real, positive pid; accepting 0 there would skip
        // waiting for the outgoing app to quit AND skip killing stragglers,
        // installing straight over a process that might still be running.
        guard parentPid > 0 || isTestMode else {
            log.write("refusing: --parent-pid 0 is only accepted under QSW_UPDATE_HELPER_TEST_MODE=1")
            return 12
        }

        let markerURL = UpdateTransactionMarker.markerURL()
        if let existing = UpdateTransactionMarker.read(at: markerURL),
           existing.stage != stage.path,
           existing.isLive(now: Date().timeIntervalSince1970, pidIsAlive: UpdateStartupGuard.pidIsAlive) {
            log.write("refusing: another transaction is in flight for stage \(existing.stage)")
            return 10
        }

        let marker = UpdateTransactionMarker(
            helperPid: getpid(), timestampEpoch: Date().timeIntervalSince1970,
            target: target.path, stage: stage.path
        )
        try? marker.write(to: markerURL)
        defer { try? FileManager.default.removeItem(at: markerURL) }

        waitForParentExit(pid: parentPid, log: log)
        terminateStragglers(insideBundle: target, log: log)

        let precedingIdentity = DesignatedRequirement.signingIdentity(
            fromDesignatedRequirement: designatedRequirement(of: target)
        )

        guard let stagedApp = findAppBundle(in: stage) else {
            log.write("no staged .app bundle found under \(stage.path)")
            return 3
        }

        let stagedInstallScriptSource = stagedApp.appendingPathComponent("Contents/Resources/install.sh")
        let copiedInstallScript = stage.appendingPathComponent("install.sh")
        do {
            if FileManager.default.fileExists(atPath: copiedInstallScript.path) {
                try FileManager.default.removeItem(at: copiedInstallScript)
            }
            // Copied OUT of the staged bundle before running — bash reads a
            // script by file offset as it executes, so running it directly
            // from inside the bundle that install.sh itself is about to
            // rsync into `target` (and `target` may equal the source of a
            // self-copy in odd layouts) is not safe.
            try FileManager.default.copyItem(at: stagedInstallScriptSource, to: copiedInstallScript)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copiedInstallScript.path)
        } catch {
            log.write("could not copy install.sh out of the staged bundle: \(error)")
            return 3
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            copiedInstallScript.path,
            "--source", stagedApp.path,
            "--dest", target.deletingLastPathComponent().path,
            "--no-launch",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            log.write("could not launch install.sh: \(error)")
            return 3
        }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        log.write("install.sh exit=\(process.terminationStatus)\n\(output)")

        switch process.terminationStatus {
        case 0:
            break
        case 3, 4, 5, 7:
            log.write("install.sh refused before touching the bundle — nothing to roll back")
            openIfReachable(target)
            return process.terminationStatus
        default:
            log.write("install.sh left the bundle half-updated (exit \(process.terminationStatus)) — rolling back")
            return rollback(stage: stage, target: target, log: log)
        }

        let postSyncIdentity = DesignatedRequirement.signingIdentity(
            fromDesignatedRequirement: designatedRequirement(of: target)
        )
        guard postSyncIdentity == precedingIdentity, runCodesignVerify(target) else {
            log.write("post-install verification failed (identity or signature) — rolling back")
            return rollback(stage: stage, target: target, log: log)
        }

        // CRITICAL fix (security review): the sync is confirmed good — clear
        // the transaction marker NOW, before anything that could start a new
        // process that reads it (the `open()` call below, or — in test mode
        // — this early return). The end-of-function `defer` remains a safety
        // net, but it used to be the ONLY place this happened, and it only
        // fires on RETURN — i.e. AFTER `open()` had already spawned a new
        // instance that could see a still-live marker.
        finishTransaction(markerURL: markerURL, log: log)

        if isTestMode {
            log.write("test mode — skipping launch confirmation")
            log.write("install complete")
            return 0
        }

        open(target)
        if !waitForBundleProcess(target: target, timeout: 15) {
            log.write("no process from \(target.path) appeared within 15s — rolling back")
            return rollback(stage: stage, target: target, log: log)
        }

        log.write("install complete")
        return 0
    }

    // MARK: - Steps

    private static func waitForParentExit(pid: Int32, log: HelperLog) {
        guard pid > 0 else { return }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return }
            usleep(200_000)
        }
        log.write("parent pid \(pid) still alive after the 20s ceiling — proceeding anyway")
    }

    private static func terminateStragglers(insideBundle target: URL, log: HelperLog) {
        let pids = ProcessBundleScanner.pids(insideBundlePath: target.path).filter { $0 != getpid() }
        guard !pids.isEmpty else { return }
        log.write("terminating stragglers: \(pids)")
        for pid in pids { kill(pid, SIGTERM) }
        usleep(5_000_000)
        for pid in pids where ProcessBundleScanner.isAlive(pid) { kill(pid, SIGKILL) }
    }

    private static func rollback(stage: URL, target: URL, log: HelperLog) -> Int32 {
        let backup = stage.appendingPathComponent("backup")
        guard FileManager.default.fileExists(atPath: backup.path) else {
            log.write("no backup at \(backup.path) — marking broken")
            markBroken(log: log)
            return 9
        }
        guard runRsync(source: backup, destination: target), runCodesignVerify(target) else {
            log.write("rollback failed — marking broken")
            markBroken(log: log)
            return 9
        }
        log.write("rolled back to the previous copy")
        openIfReachable(target)
        return 1
    }

    private static func markBroken(log: HelperLog) {
        let url = UpdateTargetGuard.brokenMarkerURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("\(Date())\n".utf8).write(to: url)
        log.write("wrote broken marker at \(url.path)")
    }

    private static func openIfReachable(_ target: URL) {
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        open(target)
    }

    /// Single choke point for every `/usr/bin/open` call this file makes
    /// (success path, early-refusal path, rollback path) — clearing the
    /// transaction marker here as the FIRST action means every one of them
    /// is covered, not just the ones that happened to remember to call
    /// `finishTransaction` themselves.
    private static func open(_ target: URL) {
        finishTransaction(markerURL: UpdateTransactionMarker.markerURL(), log: HelperLog())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [target.path]
        try? process.run()
    }

    /// Marks the transaction marker `.launching` (in case removal itself
    /// races or fails) and then removes it — a fresh launch racing this
    /// exact moment sees either no marker, or one that no longer reads as
    /// "live" (`UpdateTransactionMarker.isLive` requires `phase == .syncing`).
    private static func finishTransaction(markerURL: URL, log: HelperLog) {
        if var marker = UpdateTransactionMarker.read(at: markerURL) {
            marker.phase = .launching
            try? marker.write(to: markerURL)
        }
        try? FileManager.default.removeItem(at: markerURL)
        log.write("transaction marker cleared")
    }

    private static func waitForBundleProcess(target: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !ProcessBundleScanner.pids(insideBundlePath: target.path).isEmpty { return true }
            usleep(300_000)
        }
        return false
    }

    private static func runRsync(source: URL, destination: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments = ["-a", "--delete", source.path + "/", destination.path + "/"]
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func runCodesignVerify(_ bundle: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func designatedRequirement(of bundle: URL) -> String? {
        guard FileManager.default.fileExists(atPath: bundle.path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "-r-", bundle.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        for line in output.split(separator: "\n") {
            if let range = line.range(of: "designated => ") {
                return String(line[range.upperBound...])
            }
        }
        return nil
    }

    private static func findAppBundle(in dir: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "app" }
    }
}

/// Appends to `~/Library/Logs/QwertySwitcher/update.log`, capped at 1MB —
/// separate from `DebugLog` because this code runs before any app services
/// exist (headless helper mode, no `NSApplication`).
final class HelperLog {
    private let url: URL
    private let maxBytes = 1_000_000

    init() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/QwertySwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("update.log")
    }

    func write(_ line: String) {
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

/// libproc-based scan for processes executing from inside a given bundle —
/// used both to clear stragglers before the sync and to confirm the new
/// build actually launched after it.
enum ProcessBundleScanner {
    static func pids(insideBundlePath bundlePath: String) -> [Int32] {
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bufferSize) / MemoryLayout<pid_t>.size)
        let actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        guard actualSize > 0 else { return [] }
        let count = Int(actualSize) / MemoryLayout<pid_t>.size
        var matches: [Int32] = []
        for pid in pids.prefix(count) where pid > 0 {
            // `PROC_PIDPATHINFO_MAXSIZE` (`4*MAXPATHLEN`) itself is flagged
            // unavailable by this SDK's proc_info.h — the value (4096) is
            // stable ABI (MAXPATHLEN=1024 has not changed), so it's inlined.
            var pathBuffer = [Int8](repeating: 0, count: 4 * 1024)
            let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard len > 0 else { continue }
            let path = String(cString: pathBuffer)
            if path.hasPrefix(bundlePath) { matches.append(pid) }
        }
        return matches
    }

    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
