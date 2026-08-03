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

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}
