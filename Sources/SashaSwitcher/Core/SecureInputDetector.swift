import Foundation
import Carbon
import ApplicationServices

final class SecureInputDetector {
    private var lastCheckTime: CFAbsoluteTime = 0
    private var cachedResult = false
    private let cacheInterval: CFAbsoluteTime = 0.5 // 500ms
    private let nowProvider: () -> CFAbsoluteTime
    private let secureCheck: () -> Bool

    init(
        nowProvider: @escaping () -> CFAbsoluteTime = { CFAbsoluteTimeGetCurrent() },
        secureCheck: (() -> Bool)? = nil
    ) {
        self.nowProvider = nowProvider
        self.secureCheck = secureCheck ?? { Self.checkSystemSecureInput() }
    }

    var isSecureInput: Bool {
        let now = nowProvider()
        if cachedResult && now - lastCheckTime < cacheInterval { return true }
        lastCheckTime = now
        cachedResult = secureCheck()
        return cachedResult
    }

    private static func checkSystemSecureInput() -> Bool {
        if IsSecureEventInputEnabled() { return true }
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
