import Foundation
import AppKit
import CoreGraphics

final class PermissionsService {
    var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    var hasInputMonitoring: Bool {
        CGPreflightListenEventAccess()
    }

    var hasAllPermissions: Bool {
        hasAccessibility && hasInputMonitoring
    }

    /// Only call this explicitly from UI (e.g., onboarding button), NOT on every launch
    func requestPermissions() {
        requestAccessibility()
        requestInputMonitoring()
    }

    func requestAccessibility() {
        guard !hasAccessibility else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        NSLog("[Permissions] Requested Accessibility access")
    }

    func requestInputMonitoring() {
        guard !hasInputMonitoring else { return }
        CGRequestListenEventAccess()
        NSLog("[Permissions] Requested Input Monitoring access")
    }

    /// Prompt first, open System Settings only if the prompt didn't settle it.
    ///
    /// Calling `request*()` and `open*Settings()` back to back raises TWO
    /// foreign surfaces at once (the TCC alert and the System Settings window),
    /// and both land on top of our onboarding window. Sequencing them means at
    /// most one competitor, and `completion` is where the caller pulls its own
    /// window back to the front.
    func requestAccessibilityThenSettings(delay: TimeInterval = 0.7,
                                          completion: (() -> Void)? = nil) {
        guard !hasAccessibility else { completion?(); return }
        requestAccessibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            if !hasAccessibility { openAccessibilitySettings() }
            completion?()
        }
    }

    func requestInputMonitoringThenSettings(delay: TimeInterval = 0.7,
                                            completion: (() -> Void)? = nil) {
        guard !hasInputMonitoring else { completion?(); return }
        requestInputMonitoring()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            if !hasInputMonitoring { openInputMonitoringSettings() }
            completion?()
        }
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}
