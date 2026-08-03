import Foundation
import AppKit

/// Per-app keyboard layout memory (like Input Source Pro / Keyboard Pilot)
/// Remembers which layout was last used in each app and auto-switches on app activation
final class PerAppLayoutService {
    private let defaults = UserDefaults.standard
    private let key = AppIdentity.keyPrefix + "perAppLayouts"
    private let inputSourceManager: InputSourceManager
    private let prefsService: PreferencesService

    // Manual overrides: bundleID -> layoutID (user-configured)
    var manualOverrides: [String: String] {
        get { defaults.dictionary(forKey: key + ".overrides") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: key + ".overrides") }
    }

    // Auto-remembered: bundleID -> last used layoutID
    private var remembered: [String: String] {
        get { defaults.dictionary(forKey: key + ".remembered") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: key + ".remembered") }
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: key + ".enabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: key + ".enabled") }
    }

    init(inputSourceManager: InputSourceManager, prefsService: PreferencesService) {
        self.inputSourceManager = inputSourceManager
        self.prefsService = prefsService
        startObserving()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Public

    func setOverride(bundleID: String, layoutID: String) {
        var overrides = manualOverrides
        overrides[bundleID] = layoutID
        manualOverrides = overrides
    }

    func removeOverride(bundleID: String) {
        var overrides = manualOverrides
        overrides.removeValue(forKey: bundleID)
        manualOverrides = overrides
    }

    private var lastRememberedApp: String?
    private var lastRememberedLayout: String?

    /// Called when user types — remember current layout (deduplicated)
    func rememberCurrentLayout() {
        guard isEnabled else { return }
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let layoutID = inputSourceManager.currentLayout?.id else { return }
        let activeIDs = Set(
            inputSourceManager.resolvedActiveLayouts(preferredIDs: prefsService.activeLayoutIDs)
                .map(\.id)
        )
        guard activeIDs.contains(layoutID) else { return }
        // Only write if changed
        if bundleID == lastRememberedApp && layoutID == lastRememberedLayout { return }
        lastRememberedApp = bundleID
        lastRememberedLayout = layoutID
        var mem = remembered
        mem[bundleID] = layoutID
        remembered = mem
    }

    // MARK: - Private

    private func startObserving() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
    }

    @objc private func appActivated(_ notification: Notification) {
        guard isEnabled else { return }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier else { return }
        let activeLayouts = inputSourceManager.resolvedActiveLayouts(
            preferredIDs: prefsService.activeLayoutIDs
        )

        // Priority 1: Manual override
        if let layoutID = manualOverrides[bundleID],
           let layout = activeLayouts.first(where: { $0.id == layoutID }) {
            inputSourceManager.switchTo(layout)
            return
        }

        // Priority 2: Remembered layout
        if let layoutID = remembered[bundleID],
           let layout = activeLayouts.first(where: { $0.id == layoutID }) {
            inputSourceManager.switchTo(layout)
        }
    }
}
