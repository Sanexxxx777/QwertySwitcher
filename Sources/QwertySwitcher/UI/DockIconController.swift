import AppKit

/// Pure reference-counting core for "how many of our windows are currently
/// open" — no AppKit calls, so it's directly testable. Separated from
/// `DockIconController` below the same way `EventTapHealth`/`SwitchBlockReason`
/// separate pure resolution from side effects elsewhere in this app.
struct DockIconPolicy: Equatable {
    private(set) var openWindowCount = 0

    /// Returns `true` exactly when this open just brought the count from 0 to
    /// 1 — the caller should show the Dock icon.
    @discardableResult
    mutating func windowOpened() -> Bool {
        openWindowCount += 1
        return openWindowCount == 1
    }

    /// Returns `true` exactly when this close just brought the count to 0 —
    /// the caller should hide the Dock icon. A close with nothing open is a
    /// no-op (double-close guards upstream already exist per window, but this
    /// stays safe even if one is ever missed).
    @discardableResult
    mutating func windowClosed() -> Bool {
        guard openWindowCount > 0 else { return false }
        openWindowCount -= 1
        return openWindowCount == 0
    }
}

/// Centralized Dock-icon reference count for every window the app can show
/// while it's normally `.accessory` (menu-bar only, `LSUIElement`): Settings,
/// Exceptions, About, License, onboarding. Each window reports in through
/// this ONE place instead of toggling `NSApp.activationPolicy` itself — a
/// per-window toggle would race (closing window B could send the app back to
/// `.accessory` while window A is still open). The Dock icon appears on the
/// FIRST window opened and disappears only once the LAST one closes.
final class DockIconController {
    static let shared = DockIconController()
    private var policy = DockIconPolicy()

    private init() {}

    func windowOpened() {
        if policy.windowOpened() {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func windowClosed() {
        if policy.windowClosed() {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
