import Foundation
import Darwin

/// Runs in the CURRENT (old) app process, right before it hands off to the
/// staged copy's `--install-update` helper and quits. `launch` calls back on
/// success once the helper is spawned — the caller (`UpdateController`) is
/// the one that calls `NSApp.terminate(nil)`, keeping AppKit calls out of
/// this file.
enum UpdateInstallLauncher {
    enum LaunchError: Error {
        case backupFailed
        case spawnFailed
    }

    static func launch(staged: UpdateStager.StagedUpdate, installedBundle: URL,
                        completion: @escaping (Result<Void, LaunchError>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let backupDir = staged.stageDirectory.appendingPathComponent("backup")
            let rsync = Process()
            rsync.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
            rsync.arguments = ["-a", "--delete", installedBundle.path + "/", backupDir.path + "/"]
            do { try rsync.run() } catch { completion(.failure(.backupFailed)); return }
            rsync.waitUntilExit()
            guard rsync.terminationStatus == 0 else { completion(.failure(.backupFailed)); return }

            let markerURL = UpdateTransactionMarker.markerURL()
            let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/QwertySwitcher/update.log")
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let logFD = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)

            let helperBinary = staged.appBundle.appendingPathComponent("Contents/MacOS/QwertySwitcher").path
            let helperArguments = [
                helperBinary, "--install-update",
                "--stage", staged.stageDirectory.path,
                "--target", installedBundle.path,
                "--parent-pid", String(getpid()),
            ]

            guard let pid = spawnDetached(executable: helperBinary, arguments: helperArguments, redirectingOutputTo: logFD) else {
                if logFD >= 0 { close(logFD) }
                completion(.failure(.spawnFailed))
                return
            }
            if logFD >= 0 { close(logFD) }

            let marker = UpdateTransactionMarker(
                helperPid: pid, timestampEpoch: Date().timeIntervalSince1970,
                target: installedBundle.path, stage: staged.stageDirectory.path
            )
            try? marker.write(to: markerURL)

            completion(.success(()))
        }
    }

    /// `posix_spawn` with `POSIX_SPAWN_SETSID` — the helper is detached from
    /// this process's session so it survives this process's own termination
    /// cleanly (no controlling terminal, no signal group it would inherit).
    private static func spawnDetached(executable: String, arguments: [String], redirectingOutputTo fd: Int32) -> pid_t? {
        var pid: pid_t = 0

        // Darwin imports posix_spawnattr_t / posix_spawn_file_actions_t as
        // opaque `UnsafeMutableRawPointer?` — they are allocated by their
        // own `_init` functions, not by a zero-argument struct initializer.
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        if fd >= 0 {
            posix_spawn_file_actions_adddup2(&fileActions, fd, 1)
            posix_spawn_file_actions_adddup2(&fileActions, fd, 2)
        }

        // `arguments` is the FULL argv, including argv[0] (the executable
        // path again, by Unix convention) — see the call site.
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { if let pointer = $0 { free(pointer) } } }

        let status = posix_spawn(&pid, executable, &fileActions, &attr, &argv, environ)
        return status == 0 ? pid : nil
    }
}
