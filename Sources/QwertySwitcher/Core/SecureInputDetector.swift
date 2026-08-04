import Foundation
import Carbon
import ApplicationServices

/// Two-tier detector, split for a real hot-path bug found in the perf audit
/// (CLAUDE.md): the old single-check version called `secureCheck` on EVERY
/// keystroke whenever the cache held `false` (the caching only ever skipped
/// re-checking a `true` result) — and the real check fell through to 3-4
/// `AXUIElementCopyAttributeValue` Mach IPC round trips to the FOCUSED APP.
/// For any normal (non-secure) text field, that's every single keydown,
/// synchronously inside the CGEventTap callback — exactly the kind of call
/// that blocks for hundreds of ms when the target app is busy and trips
/// macOS's tap-disable-by-timeout (dropping/duplicating keystrokes).
///
/// Fix: split into a FAST tier (`secureCheck`, default
/// `IsSecureEventInputEnabled()` — a direct, no-IPC WindowServer flag, the
/// same one `NSSecureTextField`/Terminal/Keychain-integrated password
/// prompts set the instant they gain focus) always evaluated synchronously —
/// preserving the "secure input activation is never hidden" guarantee for
/// the primary, documented mechanism real password fields use — and a SLOW,
/// supplementary tier (`axProbe`, the AX subrole/role check, for the rarer
/// field that marks itself `AXSecureTextField` without toggling the global
/// flag) which is NEVER called synchronously from `isSecureInput` — only
/// refreshed on a background queue at most every `cacheInterval`.
final class SecureInputDetector {
    private let lock = NSLock()
    private var lastAXCheckTime: CFAbsoluteTime = -.infinity
    private var cachedAXResult = false
    private var axRefreshInFlight = false
    private let cacheInterval: CFAbsoluteTime = 0.5 // 500ms
    private let nowProvider: () -> CFAbsoluteTime
    private let secureCheck: () -> Bool
    private let axProbe: () -> Bool
    // Shared across every instance (production has exactly one; tests
    // construct many short-lived `SecureInputDetector`s via
    // `KeyboardMonitorHarness`) — a dedicated queue per instance meant every
    // harness in the integration suite spun up its own GCD queue on first
    // access, which under rapid back-to-back test execution added enough
    // scheduling churn to occasionally delay the real system's
    // TISSelectInputSource notification and flake unrelated layout-switch
    // assertions. One shared utility queue avoids the pile-up.
    private static let axQueue = DispatchQueue(
        label: AppIdentity.keyPrefix + "secure-input-ax-probe", qos: .utility
    )

    init(
        nowProvider: @escaping () -> CFAbsoluteTime = { CFAbsoluteTimeGetCurrent() },
        secureCheck: (() -> Bool)? = nil,
        axProbe: (() -> Bool)? = nil
    ) {
        self.nowProvider = nowProvider
        self.secureCheck = secureCheck ?? { IsSecureEventInputEnabled() }
        self.axProbe = axProbe ?? { Self.checkAXSecureField() }
    }

    /// Safe to call from the CGEventTap callback on every keystroke: the
    /// fast tier is a direct, synchronous, no-IPC read; the AX tier below it
    /// only ever returns an already-computed cached value.
    var isSecureInput: Bool {
        if secureCheck() { return true }
        return cachedOrRefreshingAXResult()
    }

    private func cachedOrRefreshingAXResult() -> Bool {
        lock.lock()
        let now = nowProvider()
        let result = cachedAXResult
        let stale = now - lastAXCheckTime >= cacheInterval
        if stale && !axRefreshInFlight {
            axRefreshInFlight = true
            let probe = axProbe
            lock.unlock()
            Self.axQueue.async { [weak self] in
                let fresh = probe()
                guard let self else { return }
                self.lock.lock()
                self.cachedAXResult = fresh
                self.lastAXCheckTime = self.nowProvider()
                self.axRefreshInFlight = false
                self.lock.unlock()
            }
            return result
        }
        lock.unlock()
        return result
    }

    private static func checkAXSecureField() -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success else { return false }
        // AXUIElement is a CFType — cast via unsafeBitCast
        let appElement: AXUIElement = unsafeBitCast(focusedApp, to: AXUIElement.self)

        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else { return false }
        let element: AXUIElement = unsafeBitCast(focusedElement, to: AXUIElement.self)

        var subrole: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           let sr = subrole as? String, sr == "AXSecureTextField" { return true }

        var role: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           let r = role as? String, r == "AXSecureTextField" { return true }

        return false
    }
}
