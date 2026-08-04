import AppKit
import SwiftUI

/// Owns the onboarding window for the whole app lifetime.
///
/// The window used to "disappear" after the user clicked "Открыть": the app is
/// `.accessory` (no Dock icon, no Cmd+Tab entry), the window sat at the normal
/// level, and it was raised exactly once — at creation. Activating System
/// Settings put a full-height window on top of it and there was no way back.
/// Nothing was ever destroyed; it was simply unreachable.
///
/// Fixes applied here, all mirroring patterns already used by SwitchPopup /
/// StatusIndicator in this repo:
///   * `.floating` level + `[.canJoinAllSpaces, .stationary]` — stays above
///     System Settings and follows the Space they opened on;
///   * `.regular` activation policy while onboarding is on screen — gives a
///     real Dock icon / Cmd+Tab entry, i.e. a way back that isn't z-order;
///   * `orderFrontRegardless()` on every app activation, not once at creation;
///   * a status-bar menu item can re-present it after it was closed.
///
/// The `.regular`/`.accessory` toggle itself goes through `DockIconController`
/// (shared with the Settings/Exceptions/About/License windows in
/// `StatusBarController`) instead of setting `activationPolicy` directly —
/// a local toggle here would race: closing onboarding while Settings is
/// still open would incorrectly drop the Dock icon out from under it.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let watcher: PermissionsWatcher
    private let permissions = PermissionsService()
    private var isDockIconRegistered = false
    private var onFinished: (() -> Void)?

    init(interceptionRunning: @escaping () -> Bool, onFinished: (() -> Void)? = nil) {
        self.watcher = PermissionsWatcher(interceptionRunning: interceptionRunning)
        self.onFinished = onFinished
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Presentation

    func present() {
        if let existing = window {
            watcher.startPolling()
            elevate(existing)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = AppIdentity.displayName
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.center()

        let view = OnboardingView(
            watcher: watcher,
            onContinue: { [weak self] in self?.finish(confirmed: true) },
            onGrantAccessibility: { [weak self] in self?.grantAccessibility() },
            onGrantInputMonitoring: { [weak self] in self?.grantInputMonitoring() },
            onCheckAgain: { [weak self] in self?.watcher.refresh() },
            onRestart: { [weak self] in self?.relaunch() }
        )
        window.contentView = NSHostingView(rootView: view.gammaThemedRoot())
        self.window = window

        watcher.startPolling()
        elevate(window)
    }

    /// Raise without stealing the window out from under a modal system prompt.
    private func elevate(_ window: NSWindow) {
        if !isDockIconRegistered {
            isDockIconRegistered = true
            DockIconController.shared.windowOpened()
        }
        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Pull our window back after a foreign surface (TCC alert, System
    /// Settings) took the front.
    func bringToFront() {
        guard let window, window.isVisible else { return }
        window.orderFrontRegardless()
    }

    @objc private func appDidBecomeActive() {
        bringToFront()
    }

    // MARK: - Actions

    private func grantAccessibility() {
        permissions.requestAccessibilityThenSettings { [weak self] in
            self?.watcher.refresh()
            self?.bringToFront()
        }
    }

    private func grantInputMonitoring() {
        permissions.requestInputMonitoringThenSettings { [weak self] in
            self?.watcher.refresh()
            self?.bringToFront()
        }
    }

    /// Only reachable from the `.stalled` step — see OnboardingStateMachine.
    private func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        DebugLog.shared.log("APP", "relaunch requested from onboarding")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// `confirmed: true` = the user pressed "Далее" with every grant in place.
    /// `confirmed: false` = the user closed the window themselves.
    private func finish(confirmed: Bool) {
        if confirmed {
            UserDefaults.standard.set(true, forKey: AppIdentity.keyPrefix + "onboardingSeen")
        }
        watcher.stopPolling()
        if isDockIconRegistered {
            isDockIconRegistered = false
            DockIconController.shared.windowClosed()
        }
        if let window {
            window.level = .normal
            if window.isVisible { window.close() }
        }
        onFinished?()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Red-cross dismissal: give the permission state back to the app and
        // drop back to accessory, but keep the window object so the status-bar
        // item can bring onboarding back without a restart.
        guard isDockIconRegistered else { return }
        finish(confirmed: false)
    }
}
