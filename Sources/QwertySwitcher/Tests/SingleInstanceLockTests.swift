#if DEBUG
import Foundation
import Darwin

/// Covers `SingleInstanceLock`: `tryLock`/`acquire` on temp paths only (never
/// `defaultURL` — that would fight the real running copy under `--test`),
/// plus a structural guard on `main.swift`'s call order.
enum SingleInstanceLockTests {
    static func run() {
        TestRunner.section("SingleInstanceLock — flock across open file descriptions")
        lockAndConflict()
        acquireRetriesAndTimesOut()
        unavailablePathAndShouldExit()
        mainSwiftOrdering()
    }

    private static func tempLockURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("qsw-single-instance-lock-\(UUID().uuidString)")
            .appendingPathComponent("instance.lock")
    }

    private static func fd(from attempt: SingleInstanceLock.Attempt) -> Int32? {
        if case .locked(let fd) = attempt { return fd }
        return nil
    }

    private static func lockAndConflict() {
        let url = tempLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = SingleInstanceLock.tryLock(at: url)
        guard let firstFD = fd(from: first) else {
            TestRunner.assertTrue(false, "first tryLock on a fresh temp path locks")
            return
        }
        TestRunner.assertTrue(true, "first tryLock on a fresh temp path locks")

        // BSD flock conflicts across independent open file descriptions, even
        // within the same process — a second `open` + `flock` on the same
        // path must report busy, not silently succeed.
        let second = SingleInstanceLock.tryLock(at: url)
        TestRunner.assertEqual(second, .busy(holderPid: getpid()),
                               "a second tryLock on the same path (new fd, same process) reports busy with our own pid")

        close(firstFD)
        let third = SingleInstanceLock.tryLock(at: url)
        TestRunner.assertTrue(fd(from: third) != nil,
                              "after the holder's fd is closed, tryLock locks again")
        if let thirdFD = fd(from: third) { close(thirdFD) }
    }

    private static func acquireRetriesAndTimesOut() {
        let releasedURL = tempLockURL()
        defer { try? FileManager.default.removeItem(at: releasedURL.deletingLastPathComponent()) }

        guard let holderFD = fd(from: SingleInstanceLock.tryLock(at: releasedURL)) else {
            TestRunner.assertTrue(false, "setup: could not take the initial lock to test acquire() against")
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) {
            close(holderFD)
        }
        let start = Date()
        let recovered = SingleInstanceLock.acquire(at: releasedURL, waitSeconds: 2, pollInterval: 0.1)
        let elapsed = Date().timeIntervalSince(start)
        TestRunner.assertTrue(fd(from: recovered) != nil,
                              "acquire() succeeds once the holder releases its fd within the wait window")
        TestRunner.assertTrue(elapsed < 2, "acquire() returned before the full wait window elapsed (took \(elapsed)s)")
        if let recoveredFD = fd(from: recovered) { close(recoveredFD) }

        let heldURL = tempLockURL()
        defer { try? FileManager.default.removeItem(at: heldURL.deletingLastPathComponent()) }
        guard let neverReleasedFD = fd(from: SingleInstanceLock.tryLock(at: heldURL)) else {
            TestRunner.assertTrue(false, "setup: could not take the lock to test acquire()'s timeout")
            return
        }
        let timedOut = SingleInstanceLock.acquire(at: heldURL, waitSeconds: 0.3, pollInterval: 0.05)
        TestRunner.assertEqual(timedOut, .busy(holderPid: getpid()),
                               "acquire() gives up as busy once waitSeconds elapses with the lock still held")
        close(neverReleasedFD)
    }

    private static func unavailablePathAndShouldExit() {
        let impossible = URL(fileURLWithPath: "/dev/null/qsw/instance.lock")
        let attempt = SingleInstanceLock.tryLock(at: impossible)
        var isUnavailable = false
        if case .unavailable = attempt { isUnavailable = true }
        TestRunner.assertTrue(isUnavailable, "tryLock under an impossible path reports unavailable, not locked or busy")

        TestRunner.assertTrue(!SingleInstanceLock.shouldExit(for: attempt),
                              "shouldExit is false for .unavailable — a lock-infrastructure failure must never block startup")
        TestRunner.assertTrue(!SingleInstanceLock.shouldExit(for: .locked(-1)),
                              "shouldExit is false for .locked")
        TestRunner.assertTrue(SingleInstanceLock.shouldExit(for: .busy(holderPid: nil)),
                              "shouldExit is true for .busy")
    }

    private static func mainSwiftOrdering() {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .appendingPathComponent("main.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            TestRunner.skip("main.swift not readable from \(source.path)")
            return
        }

        guard let testModeRange = text.range(of: "TestRunMode.isActive"),
              let installUpdateRange = text.range(of: "\"--install-update\""),
              let startupGuardRange = text.range(of: "UpdateStartupGuard.shouldProceedWithNormalLaunch"),
              let acquireRange = text.range(of: "SingleInstanceLock.acquire"),
              let nsAppRange = text.range(of: "NSApplication.shared")
        else {
            TestRunner.assertTrue(false, "main.swift: expected markers not found — test needs updating")
            return
        }

        TestRunner.assertTrue(testModeRange.lowerBound < acquireRange.lowerBound,
                              "SingleInstanceLock.acquire appears after the --test branch")
        TestRunner.assertTrue(installUpdateRange.lowerBound < acquireRange.lowerBound,
                              "SingleInstanceLock.acquire appears after the --install-update branch")
        TestRunner.assertTrue(startupGuardRange.lowerBound < acquireRange.lowerBound,
                              "SingleInstanceLock.acquire appears after the UpdateStartupGuard check")
        TestRunner.assertTrue(acquireRange.lowerBound < nsAppRange.lowerBound,
                              "SingleInstanceLock.acquire appears before NSApplication.shared")
    }
}
#endif
