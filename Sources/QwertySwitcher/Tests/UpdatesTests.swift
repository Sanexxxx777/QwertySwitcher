import Foundation
import CryptoKit

/// Wave W1-B: opt-in auto-updater + "Собрать отчёт". Covers manifest/appcast
/// parsing, signature verification, anti-rollback, policy branches, limits,
/// the Designated Requirement reduction, the diagnostics log filter, feed-URL
/// override validation, and structural guards on the helper's source.
enum UpdatesTests {
    static func run() {
        manifestParsing()
        signatureVerification()
        versionOrdering()
        policyChecks()
        limits()
        designatedRequirementParser()
        reportFilter()
        feedURLOverride()
        structuralGuards()
    }

    // MARK: - Manifest / appcast parsing

    private static func fixtureManifestJSON(build: Int = 40, validUntil: String = "2099-01-01T00:00:00Z") -> Data {
        let manifest = UpdateManifest(
            version: "0.11.1", build: build, minSystemVersion: "13.0",
            archiveURL: "https://example.com/QwertySwitcher-0.11.1.zip", size: 12345,
            sha256: String(repeating: "a", count: 64), publishedAt: "2026-09-10T00:00:00Z",
            validUntil: validUntil, notes: "test"
        )
        return try! JSONEncoder().encode(manifest)
    }

    private static func signedAppcast(manifestBytes: Data, keyId: String = "k1", signWith privateKey: Curve25519.Signing.PrivateKey) -> UpdateAppcast {
        let signature = try! privateKey.signature(for: manifestBytes)
        return UpdateAppcast(
            keyId: keyId, manifestBase64: manifestBytes.base64EncodedString(),
            signature: signature.base64EncodedString()
        )
    }

    private static func manifestParsing() {
        TestRunner.section("Updates — manifest/appcast decoding")

        let goodManifest = fixtureManifestJSON()
        let decoded = try? JSONDecoder().decode(UpdateManifest.self, from: goodManifest)
        TestRunner.assertTrue(decoded != nil, "a well-formed manifest decodes")
        TestRunner.assertEqual(decoded?.build ?? -1, 40, "decoded build matches")

        let missingField = "{\"version\":\"0.11.1\",\"build\":40}".data(using: .utf8)!
        TestRunner.assertNil(
            try? JSONDecoder().decode(UpdateManifest.self, from: missingField),
            "a manifest missing required fields fails to decode"
        )

        let garbage = "not json at all".data(using: .utf8)!
        TestRunner.assertNil(
            try? JSONDecoder().decode(UpdateAppcast.self, from: garbage),
            "garbage bytes never decode as an appcast"
        )

        let appcastJSON = "{\"keyId\":\"k1\",\"manifestBase64\":\"AA==\",\"signature\":\"AA==\"}".data(using: .utf8)!
        let appcast = try? JSONDecoder().decode(UpdateAppcast.self, from: appcastJSON)
        TestRunner.assertTrue(appcast != nil, "a well-formed appcast envelope decodes")

        if let appcast {
            var unknownKeyAppcast = appcast
            unknownKeyAppcast = UpdateAppcast(keyId: "k9-does-not-exist", manifestBase64: appcast.manifestBase64, signature: appcast.signature)
            switch UpdateManifestVerifier.verify(unknownKeyAppcast) {
            case .failure(.unknownKeyId): TestRunner.assertTrue(true, "unknown keyId is rejected before any signature math")
            default: TestRunner.assertTrue(false, "unknown keyId should be rejected as .unknownKeyId")
            }
        }
    }

    // MARK: - Signature verification

    private static func signatureVerification() {
        TestRunner.section("Updates — Ed25519 signature verification")

        let key = Curve25519.Signing.PrivateKey()
        let otherKey = Curve25519.Signing.PrivateKey()
        let manifestBytes = fixtureManifestJSON()

        // The verifier only ever looks up embedded keyIds (k1/k2), so a
        // throwaway test key is verified directly, not through UpdateKeyRing.
        let signature = try! key.signature(for: manifestBytes)
        TestRunner.assertTrue(
            key.publicKey.isValidSignature(signature, for: manifestBytes),
            "a validly signed manifest verifies against its own public key"
        )
        TestRunner.assertTrue(
            !otherKey.publicKey.isValidSignature(signature, for: manifestBytes),
            "the same signature fails against a different public key"
        )

        var tampered = manifestBytes
        tampered[tampered.count / 2] ^= 0xFF
        TestRunner.assertTrue(
            !key.publicKey.isValidSignature(signature, for: tampered),
            "flipping a byte inside the signed manifest (e.g. sha256 field) invalidates the signature"
        )

        // End-to-end through UpdateManifestVerifier with the REAL embedded k1.
        guard let k1Raw = Data(base64Encoded: UpdateKeyRing.publicKeys["k1"] ?? "") else {
            TestRunner.assertTrue(false, "k1 public key must be embedded and valid base64")
            return
        }
        TestRunner.assertEqual(k1Raw.count, 32, "k1 is a raw 32-byte Ed25519 public key")
        guard let k2Raw = Data(base64Encoded: UpdateKeyRing.publicKeys["k2"] ?? "") else {
            TestRunner.assertTrue(false, "k2 public key must be embedded and valid base64")
            return
        }
        TestRunner.assertEqual(k2Raw.count, 32, "k2 is a raw 32-byte Ed25519 public key")

        // We don't have the real k1/k2 private keys in the test suite (by
        // design — they live only in ~/.claude/secrets/, never in the repo),
        // so the "verify() succeeds" path is exercised through the throwaway
        // key above, and the "unknown keyId" / "bad signature" paths are
        // exercised end-to-end here.
        let unknownAppcast = signedAppcast(manifestBytes: manifestBytes, keyId: "not-a-real-key", signWith: key)
        switch UpdateManifestVerifier.verify(unknownAppcast) {
        case .failure(.unknownKeyId): TestRunner.assertTrue(true, "verify() rejects an unrecognized keyId")
        default: TestRunner.assertTrue(false, "expected .unknownKeyId")
        }

        let wrongKeyAppcast = signedAppcast(manifestBytes: manifestBytes, keyId: "k1", signWith: otherKey)
        switch UpdateManifestVerifier.verify(wrongKeyAppcast) {
        case .failure(.badSignature): TestRunner.assertTrue(true, "verify() rejects a signature made with the wrong key for keyId=k1")
        default: TestRunner.assertTrue(false, "expected .badSignature")
        }

        let malformedBase64 = UpdateAppcast(keyId: "k1", manifestBase64: "not base64 at all!!", signature: "AA==")
        switch UpdateManifestVerifier.verify(malformedBase64) {
        case .failure(.malformedManifestBase64): TestRunner.assertTrue(true, "verify() rejects malformed manifestBase64")
        default: TestRunner.assertTrue(false, "expected .malformedManifestBase64")
        }
    }

    // MARK: - Version ordering / anti-rollback

    private static func versionOrdering() {
        TestRunner.section("Updates — version ordering (anti-rollback floor)")

        let manifest40 = try! JSONDecoder().decode(UpdateManifest.self, from: fixtureManifestJSON(build: 40))
        let now = Date()
        let macOS13 = OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)

        switch UpdatePolicy.evaluate(manifest: manifest40, installedBuild: 36, lastSeenBuild: 0, currentSystemVersion: macOS13, now: now) {
        case .available(let m): TestRunner.assertEqual(m.build, 40, "a higher build than installed, above lastSeenBuild, is offered")
        default: TestRunner.assertTrue(false, "expected .available")
        }

        switch UpdatePolicy.evaluate(manifest: manifest40, installedBuild: 40, lastSeenBuild: 0, currentSystemVersion: macOS13, now: now) {
        case .upToDate: TestRunner.assertTrue(true, "an equal build is up to date, not offered again")
        default: TestRunner.assertTrue(false, "expected .upToDate for build == installed")
        }

        switch UpdatePolicy.evaluate(manifest: manifest40, installedBuild: 30, lastSeenBuild: 41, currentSystemVersion: macOS13, now: now) {
        case .upToDate: TestRunner.assertTrue(true, "a stale-feed manifest below lastSeenBuild is refused even though it beats installedBuild — anti-rollback")
        default: TestRunner.assertTrue(false, "expected .upToDate (rollback refused)")
        }

        let macOS14 = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        let highMinManifest = try! JSONDecoder().decode(
            UpdateManifest.self,
            from: try! JSONEncoder().encode(UpdateManifest(
                version: "0.12.0", build: 99, minSystemVersion: "99.0", archiveURL: "https://example.com/x.zip",
                size: 1, sha256: "aa", publishedAt: "2026-01-01T00:00:00Z", validUntil: "2099-01-01T00:00:00Z", notes: ""
            ))
        )
        switch UpdatePolicy.evaluate(manifest: highMinManifest, installedBuild: 1, lastSeenBuild: 0, currentSystemVersion: macOS14, now: now) {
        case .systemTooOld: TestRunner.assertTrue(true, "minSystemVersion above the running macOS is never offered")
        default: TestRunner.assertTrue(false, "expected .systemTooOld")
        }

        let expiredManifest = try! JSONDecoder().decode(UpdateManifest.self, from: fixtureManifestJSON(build: 99, validUntil: "2000-01-01T00:00:00Z"))
        switch UpdatePolicy.evaluate(manifest: expiredManifest, installedBuild: 1, lastSeenBuild: 0, currentSystemVersion: macOS13, now: now) {
        case .feedStale: TestRunner.assertTrue(true, "a manifest past its own validUntil is reported stale, not installed")
        default: TestRunner.assertTrue(false, "expected .feedStale")
        }
    }

    // MARK: - Policy (shouldCheck / shouldInstallNow)

    private static func policyChecks() {
        TestRunner.section("Updates — UpdatePolicy.shouldCheck / shouldInstallNow")

        let now = Date()
        TestRunner.assertTrue(
            !UpdatePolicy.shouldCheck(now: now, lastCheckAt: nil, lastFailureAt: nil, autoCheck: false),
            "shouldCheck is false when the master toggle is off, even with no history"
        )
        TestRunner.assertTrue(
            UpdatePolicy.shouldCheck(now: now, lastCheckAt: nil, lastFailureAt: nil, autoCheck: true),
            "shouldCheck is true on first-ever check when the toggle is on"
        )
        TestRunner.assertTrue(
            !UpdatePolicy.shouldCheck(now: now, lastCheckAt: now.addingTimeInterval(-3600), lastFailureAt: nil, autoCheck: true),
            "shouldCheck is false 1h after a successful check (24h cadence)"
        )
        TestRunner.assertTrue(
            UpdatePolicy.shouldCheck(now: now, lastCheckAt: now.addingTimeInterval(-25 * 3600), lastFailureAt: nil, autoCheck: true),
            "shouldCheck is true 25h after the last successful check"
        )
        TestRunner.assertTrue(
            !UpdatePolicy.shouldCheck(now: now, lastCheckAt: now.addingTimeInterval(-25 * 3600), lastFailureAt: now.addingTimeInterval(-3600), autoCheck: true),
            "a recent failure (1h ago) blocks retry even though the 24h success cadence would allow it"
        )
        TestRunner.assertTrue(
            UpdatePolicy.shouldCheck(now: now, lastCheckAt: nil, lastFailureAt: now.addingTimeInterval(-7 * 3600), autoCheck: true),
            "a 7h-old failure has cleared the 6h backoff"
        )

        TestRunner.assertTrue(
            UpdatePolicy.shouldInstallNow(autoInstall: true, idleSeconds: 200, secureInput: false, replacing: false, gameModeActive: false),
            "install allowed: auto-install on, idle ≥120s, nothing blocking"
        )
        TestRunner.assertTrue(
            !UpdatePolicy.shouldInstallNow(autoInstall: false, idleSeconds: 200, secureInput: false, replacing: false, gameModeActive: false),
            "install refused when auto-install itself is off"
        )
        TestRunner.assertTrue(
            !UpdatePolicy.shouldInstallNow(autoInstall: true, idleSeconds: 60, secureInput: false, replacing: false, gameModeActive: false),
            "install refused below the 120s idle floor"
        )
        TestRunner.assertTrue(
            !UpdatePolicy.shouldInstallNow(autoInstall: true, idleSeconds: 200, secureInput: true, replacing: false, gameModeActive: false),
            "install refused during secure input"
        )
        TestRunner.assertTrue(
            !UpdatePolicy.shouldInstallNow(autoInstall: true, idleSeconds: 200, secureInput: false, replacing: true, gameModeActive: false),
            "install refused mid-replacement"
        )
        TestRunner.assertTrue(
            !UpdatePolicy.shouldInstallNow(autoInstall: true, idleSeconds: 200, secureInput: false, replacing: false, gameModeActive: true),
            "install refused while Game Mode is active"
        )
    }

    // MARK: - Limits

    private static func limits() {
        TestRunner.section("Updates — unpacked-archive limits")

        let smallFine = (0..<10).map { _ in UpdateStager.UnpackedEntry(isSymlink: false, size: 100, symlinkStaysInside: true) }
        TestRunner.assertTrue(
            isSuccess(UpdateStager.evaluateUnpackedEntries(smallFine, maxFiles: 5000, maxBytes: 150_000_000)),
            "a small, ordinary set of entries passes"
        )

        let tooManyFiles = (0..<5001).map { _ in UpdateStager.UnpackedEntry(isSymlink: false, size: 1, symlinkStaysInside: true) }
        TestRunner.assertEqual(
            errorCase(UpdateStager.evaluateUnpackedEntries(tooManyFiles, maxFiles: 5000, maxBytes: 150_000_000)),
            "tooManyFiles", "over 5000 files is refused"
        )

        let tooBig = [UpdateStager.UnpackedEntry(isSymlink: false, size: 150_000_001, symlinkStaysInside: true)]
        TestRunner.assertEqual(
            errorCase(UpdateStager.evaluateUnpackedEntries(tooBig, maxFiles: 5000, maxBytes: 150_000_000)),
            "tooLarge", "over 150MB unpacked is refused"
        )

        let escapingSymlink = [UpdateStager.UnpackedEntry(isSymlink: true, size: 0, symlinkStaysInside: false)]
        TestRunner.assertEqual(
            errorCase(UpdateStager.evaluateUnpackedEntries(escapingSymlink, maxFiles: 5000, maxBytes: 150_000_000)),
            "symlinkEscape", "a symlink resolving outside the stage root is refused"
        )

        let containedSymlink = [UpdateStager.UnpackedEntry(isSymlink: true, size: 0, symlinkStaysInside: true)]
        TestRunner.assertTrue(
            isSuccess(UpdateStager.evaluateUnpackedEntries(containedSymlink, maxFiles: 5000, maxBytes: 150_000_000)),
            "a symlink that resolves inside the stage root is allowed"
        )
    }

    private static func isSuccess(_ result: Result<Void, UpdateStager.StageError>) -> Bool {
        if case .success = result { return true }
        return false
    }

    private static func errorCase(_ result: Result<Void, UpdateStager.StageError>) -> String {
        guard case .failure(let error) = result else { return "success" }
        switch error {
        case .tooManyFiles: return "tooManyFiles"
        case .tooLarge: return "tooLarge"
        case .symlinkEscape: return "symlinkEscape"
        default: return "other"
        }
    }

    // MARK: - Designated Requirement parser

    private static func designatedRequirementParser() {
        TestRunner.section("Updates — DesignatedRequirement.signingIdentity (mirrors install.sh's signing_identity_of)")

        TestRunner.assertEqual(
            DesignatedRequirement.signingIdentity(fromDesignatedRequirement: nil), "unsigned",
            "no DR at all reduces to 'unsigned'"
        )
        TestRunner.assertEqual(
            DesignatedRequirement.signingIdentity(fromDesignatedRequirement: ""), "unsigned",
            "an empty DR reduces to 'unsigned'"
        )
        TestRunner.assertEqual(
            DesignatedRequirement.signingIdentity(fromDesignatedRequirement: "cdhash H\"abc123\""), "adhoc",
            "a cdhash-based DR (ad-hoc signature) reduces to 'adhoc'"
        )
        let identityDR = "identifier \"tech.sasha.qwertyswitch\" and certificate leaf = H\"a80cd00f\""
        TestRunner.assertEqual(
            DesignatedRequirement.signingIdentity(fromDesignatedRequirement: identityDR), identityDR,
            "an identity-bearing DR is compared verbatim, not reduced"
        )
    }

    // MARK: - Diagnostics report filter

    private static func reportFilter() {
        TestRunner.section("Updates — DiagnosticsExportService.filterReportLog")

        let raw = """
        12:00:00.000 [APP] session start
        12:00:01.000 [KM] key kc=0 len=3
        12:00:01.100 [KM] shift: kc=56 down
        12:00:02.000 [KM] auto-switch: en -> ru len=5
        """
        let filtered = DiagnosticsExportService.filterReportLog(raw)
        TestRunner.assertTrue(!filtered.contains("key kc="), "per-key trace lines are removed from the report log")
        TestRunner.assertTrue(!filtered.contains("shift: kc="), "shift-state trace lines are removed from the report log")
        TestRunner.assertTrue(filtered.contains("session start"), "ordinary session lines survive the filter")
        TestRunner.assertTrue(filtered.contains("auto-switch: en -> ru"), "summary event lines survive the filter")
    }

    // MARK: - Feed URL override

    private static func feedURLOverride() {
        TestRunner.section("Updates — feed URL override validation")

        TestRunner.assertTrue(
            UpdatePolicy.isAcceptableFeedURL("https://shulgin.is-a.dev/store/downloads/qwertyswitcher/appcast.json"),
            "the production https feed URL is accepted"
        )
        TestRunner.assertTrue(
            UpdatePolicy.isAcceptableFeedURL("http://127.0.0.1:8000/appcast.json"),
            "http://127.0.0.1 is accepted (local e2e testing)"
        )
        TestRunner.assertTrue(
            UpdatePolicy.isAcceptableFeedURL("http://localhost:8000/appcast.json"),
            "http://localhost is accepted (local e2e testing)"
        )
        TestRunner.assertTrue(
            !UpdatePolicy.isAcceptableFeedURL("http://example.com/appcast.json"),
            "arbitrary http hosts are rejected"
        )
        TestRunner.assertTrue(
            !UpdatePolicy.isAcceptableFeedURL("ftp://example.com/appcast.json"),
            "non-http(s) schemes are rejected"
        )
        TestRunner.assertTrue(
            !UpdatePolicy.isAcceptableFeedURL("not a url"),
            "unparseable strings are rejected"
        )
    }

    // MARK: - Structural guards (source-level, #filePath)

    private static func structuralGuards() {
        TestRunner.section("Updates — structural guards on the install helper's source")

        let sourcesRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // QwertySwitcher/
            .appendingPathComponent("Services/Updates")

        guard let helperSource = try? String(contentsOf: sourcesRoot.appendingPathComponent("UpdateInstallerMode.swift"), encoding: .utf8) else {
            TestRunner.skip("UpdateInstallerMode.swift not readable — structural guards skipped")
            return
        }
        let helperCode = codeOnly(helperSource)
        TestRunner.assertTrue(
            !helperCode.contains("osascript"),
            "the install helper never shells out to osascript — the outgoing app already quit itself"
        )
        TestRunner.assertTrue(
            !helperCode.contains("--allow-identity-change"),
            "the automatic install path never passes --allow-identity-change to install.sh"
        )
        TestRunner.assertTrue(
            helperCode.contains("copyItem(at: stagedInstallScriptSource, to: copiedInstallScript)"),
            "install.sh is copied out of the staged bundle before it is ever executed"
        )

        guard let launcherSource = try? String(contentsOf: sourcesRoot.appendingPathComponent("UpdateInstallLauncher.swift"), encoding: .utf8) else {
            TestRunner.skip("UpdateInstallLauncher.swift not readable — structural guard skipped")
            return
        }
        let launcherCode = codeOnly(launcherSource)
        TestRunner.assertTrue(
            !launcherCode.contains("--allow-identity-change"),
            "the parent-side launcher never passes --allow-identity-change either"
        )
        TestRunner.assertTrue(
            launcherCode.contains("POSIX_SPAWN_SETSID"),
            "the helper is spawned detached (POSIX_SPAWN_SETSID), so it survives the parent's own termination"
        )
    }

    /// Drops `//`-comment lines (including `///` doc comments) — this file's
    /// own doc comments legitimately NAME "osascript" and
    /// "--allow-identity-change" while explaining why they are absent, which
    /// would otherwise defeat the two checks above.
    private static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
