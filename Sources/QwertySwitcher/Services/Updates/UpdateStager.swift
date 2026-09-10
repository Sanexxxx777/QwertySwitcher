import Foundation
import CryptoKit

/// Downloads and validates an update archive into
/// `<updatesRoot>/<uuid>/`, but never installs it — installation is a
/// separate, privileged step (`UpdateInstallerMode`) so a bad stage can
/// always be thrown away without having touched the running copy.
final class UpdateStager {
    enum StageError: Error, Equatable {
        case network(UpdateHTTPClient.ClientError)
        case checksumMismatch
        case unzipFailed(Int32)
        case tooManyFiles
        case tooLarge
        case symlinkEscape
        case signatureInvalid
        case identityMismatch(installed: String, staged: String)
        case bundleIdentifierMismatch
        case buildMismatch
        case sizeMismatch
        case stageBundleMissing
    }

    struct StagedUpdate {
        let stageDirectory: URL
        let appBundle: URL
        let manifest: UpdateManifest
    }

    private let userAgent: String
    private let fileManager = FileManager.default
    private let maxDownloadBytes = 40_000_000
    private let maxUnpackedBytes = 150_000_000
    private let maxUnpackedFiles = 5000

    init(userAgent: String) {
        self.userAgent = userAgent
    }

    /// `~/Library/Application Support/QwertySwitcher/updates` by default —
    /// overridable via `QSW_UPDATES_ROOT_DIR` (same test-isolation pattern
    /// `DebugLog` already uses for `QSW_LOG_DIR`), so contract tests and unit
    /// tests never touch the owner's real staging directory.
    static func updatesRootDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["QSW_UPDATES_ROOT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QwertySwitcher/updates", isDirectory: true)
    }

    func stage(manifest: UpdateManifest, installedBundle: URL,
               completion: @escaping (Result<StagedUpdate, StageError>) -> Void) {
        guard let archiveURL = URL(string: manifest.archiveURL) else {
            completion(.failure(.network(.badStatus(0))))
            return
        }
        let client = UpdateHTTPClient(maxBytes: maxDownloadBytes, userAgent: userAgent)
        client.fetch(archiveURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(.network(error)))
            case .success(let data):
                self.validateAndUnpack(data: data, manifest: manifest, installedBundle: installedBundle, completion: completion)
            }
        }
    }

    // MARK: - Pure limit evaluation (unit-testable without touching disk)

    struct UnpackedEntry {
        let isSymlink: Bool
        let size: Int
        /// True if a symlink's resolved target stays inside the stage root.
        /// Meaningless (ignored) for non-symlink entries.
        let symlinkStaysInside: Bool
    }

    static func evaluateUnpackedEntries(_ entries: [UnpackedEntry], maxFiles: Int, maxBytes: Int) -> Result<Void, StageError> {
        var fileCount = 0
        var totalBytes = 0
        for entry in entries {
            if entry.isSymlink, !entry.symlinkStaysInside {
                return .failure(.symlinkEscape)
            }
            fileCount += 1
            totalBytes += entry.size
            if fileCount > maxFiles { return .failure(.tooManyFiles) }
            if totalBytes > maxBytes { return .failure(.tooLarge) }
        }
        return .success(())
    }

    // MARK: - Disk-touching implementation

    private func validateAndUnpack(data: Data, manifest: UpdateManifest, installedBundle: URL,
                                    completion: @escaping (Result<StagedUpdate, StageError>) -> Void) {
        guard data.count <= maxDownloadBytes else {
            completion(.failure(.tooLarge))
            return
        }
        guard data.count == manifest.size else {
            completion(.failure(.sizeMismatch))
            return
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.sha256.lowercased() else {
            completion(.failure(.checksumMismatch))
            return
        }

        let stageDir = Self.updatesRootDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: stageDir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
        } catch {
            completion(.failure(.unzipFailed(-1)))
            return
        }

        let zipPath = stageDir.appendingPathComponent("update.zip")
        do {
            try data.write(to: zipPath)
        } catch {
            completion(.failure(.unzipFailed(-1)))
            return
        }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipPath.path, stageDir.path]
        do {
            try ditto.run()
            ditto.waitUntilExit()
        } catch {
            completion(.failure(.unzipFailed(-1)))
            return
        }
        try? fileManager.removeItem(at: zipPath)
        guard ditto.terminationStatus == 0 else {
            completion(.failure(.unzipFailed(ditto.terminationStatus)))
            return
        }

        guard let appBundle = findAppBundle(in: stageDir) else {
            completion(.failure(.stageBundleMissing))
            return
        }

        switch validateUnpackedLimits(root: stageDir) {
        case .failure(let error): completion(.failure(error)); return
        case .success: break
        }

        guard runCodesignVerify(appBundle) else {
            completion(.failure(.signatureInvalid))
            return
        }

        let stagedIdentity = DesignatedRequirement.signingIdentity(fromDesignatedRequirement: designatedRequirement(of: appBundle))
        let installedIdentity = DesignatedRequirement.signingIdentity(fromDesignatedRequirement: designatedRequirement(of: installedBundle))
        // MAJOR fix (security review): comparing the two REDUCED strings for
        // equality alone lets "adhoc" == "adhoc" through — but "adhoc" means
        // a cdhash-based DR that changes on EVERY rebuild, so two ad-hoc
        // builds reading as "the same identity" is exactly backwards: the
        // stored TCC csreq would stop matching the moment this installs,
        // even though this gate just approved it. Untrusted, unreproducible
        // identities are refused outright, matching == not being enough.
        guard stagedIdentity == installedIdentity,
              stagedIdentity != "adhoc", stagedIdentity != "unsigned"
        else {
            completion(.failure(.identityMismatch(installed: installedIdentity, staged: stagedIdentity)))
            return
        }

        guard let info = NSDictionary(contentsOf: appBundle.appendingPathComponent("Contents/Info.plist")) else {
            completion(.failure(.stageBundleMissing))
            return
        }
        guard (info["CFBundleIdentifier"] as? String) == AppIdentity.bundleIdentifier else {
            completion(.failure(.bundleIdentifierMismatch))
            return
        }
        let bundleVersion = (info["CFBundleVersion"] as? String).flatMap(Int.init)
        guard bundleVersion == manifest.build else {
            completion(.failure(.buildMismatch))
            return
        }

        removeQuarantine(appBundle)
        completion(.success(StagedUpdate(stageDirectory: stageDir, appBundle: appBundle, manifest: manifest)))
    }

    private func findAppBundle(in dir: URL) -> URL? {
        (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "app" }
    }

    private func validateUnpackedLimits(root: URL) -> Result<Void, StageError> {
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey]
        ) else { return .failure(.stageBundleMissing) }

        var entries: [UnpackedEntry] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            let isSymlink = values?.isSymbolicLink == true
            entries.append(UnpackedEntry(
                isSymlink: isSymlink,
                size: values?.fileSize ?? 0,
                symlinkStaysInside: isSymlink ? isSymlinkContained(url, root: root) : true
            ))
            // Bail out early on an obviously hostile archive instead of
            // enumerating millions of entries first.
            if entries.count > maxUnpackedFiles * 2 { break }
        }
        return Self.evaluateUnpackedEntries(entries, maxFiles: maxUnpackedFiles, maxBytes: maxUnpackedBytes)
    }

    /// MINOR fix (security review): the old check compared raw
    /// `standardizedFileURL` paths with a bare `hasPrefix` — a symlink into
    /// `<root>SIBLING/...` would pass (no path-boundary separator), and
    /// `standardizedFileURL` doesn't resolve symlinks in the PARENT chain
    /// (e.g. macOS's own `/tmp` → `/private/tmp`), so `root` and the
    /// symlink's target could disagree on what "the same directory" even
    /// looks like. Both sides now go through `resolvingSymlinksInPath()` and
    /// the containment check requires an exact match or a `/`-terminated
    /// prefix.
    private func isSymlinkContained(_ url: URL, root: URL) -> Bool {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else { return false }
        let rawResolvedPath = destination.hasPrefix("/")
            ? destination
            : url.deletingLastPathComponent().appendingPathComponent(destination).path
        let realResolved = URL(fileURLWithPath: rawResolvedPath).resolvingSymlinksInPath().path
        let realRoot = root.resolvingSymlinksInPath().path
        return realResolved == realRoot || realResolved.hasPrefix(realRoot + "/")
    }

    private func runCodesignVerify(_ bundle: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func designatedRequirement(of bundle: URL) -> String? {
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
        for line in output.split(separator: "\n") where line.contains("designated => ") {
            if let range = line.range(of: "designated => ") {
                return String(line[range.upperBound...])
            }
        }
        return nil
    }

    private func removeQuarantine(_ bundle: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-rd", "com.apple.quarantine", bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            // MINOR fix (security review): `try? process.run()` swallowed a
            // launch failure and fell straight into `waitUntilExit()` on a
            // process that never started — `Process` traps in that state.
            try process.run()
            process.waitUntilExit()
        } catch {
            // Best-effort only: a failed quarantine removal doesn't block
            // the install, it just means Gatekeeper may prompt once.
        }
    }
}
