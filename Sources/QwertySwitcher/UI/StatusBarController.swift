import AppKit
import SwiftUI
import Carbon

final class StatusBarController {
    private var statusItem: NSStatusItem!
    private let statsService: StatisticsService
    private let prefsService: PreferencesService
    private let exceptionsService: ExceptionsService
    private let keyboardMonitor: KeyboardMonitor
    private let inputSourceManager: InputSourceManager
    private let perAppLayoutService: PerAppLayoutService
    private let timedPauseService: TimedPauseService
    private let snippetService: SnippetService
    private let autoStartService = AutoStartService()
    private var mainWindow: NSWindow?
    private var exceptionsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var licenseWindow: NSWindow?
    /// Set by AppDelegate. The one guaranteed way back to onboarding after the
    /// window was closed — without it a dismissed onboarding is lost until the
    /// app is restarted (the app is `.accessory`, so there is no Dock/Cmd+Tab
    /// entry to click).
    var onOpenPermissions: (() -> Void)?

    init(statsService: StatisticsService, prefsService: PreferencesService,
         exceptionsService: ExceptionsService, keyboardMonitor: KeyboardMonitor,
         inputSourceManager: InputSourceManager,
         perAppLayoutService: PerAppLayoutService,
         timedPauseService: TimedPauseService,
         snippetService: SnippetService) {
        self.statsService = statsService
        self.prefsService = prefsService
        self.exceptionsService = exceptionsService
        self.keyboardMonitor = keyboardMonitor
        self.inputSourceManager = inputSourceManager
        self.perAppLayoutService = perAppLayoutService
        self.timedPauseService = timedPauseService
        self.snippetService = snippetService
        setupStatusItem()

        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshMenu),
            name: .autoSwitchToggled, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshMenu),
            name: .eventTapHealthChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshMenu),
            name: .activeLayoutsChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshMenu),
            name: .licenseStatusChanged, object: nil
        )
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        rebuildMenu()

        // Update icon when layout changes
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(layoutChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(autoSwitchStateChanged),
            name: .autoSwitchToggled, object: nil
        )
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let languageCode = (inputSourceManager.currentLayout?.languageCode ?? "?").uppercased()
        let code = keyboardMonitor.health == .running ? languageCode : "!"
        let reason = currentBlockReason()
        button.image = Self.makeStatusImage(label: code, reason: reason)
        button.imagePosition = .imageOnly
        button.title = ""
        if let title = reason.title {
            button.toolTip = "\(AppIdentity.displayName) · \(title)"
        } else {
            button.toolTip = "\(AppIdentity.displayName) · \(languageCode) · автопереключение включено"
        }
    }

    /// Single source of truth (see `SwitchBlockReason`) for the badge color,
    /// the menu's diagnostic line and the tooltip. The app-name refinement
    /// for secure input is only looked up when actually needed — this runs
    /// on notification-driven refreshes (≤ every ~500ms via the health
    /// timer), never from the keystroke hot path. Same budget covers the
    /// per-app profile check below: without it, an app with `blockAutoSwitch`
    /// or `blockInstantCorrection` set left this badge on `.none` — silence
    /// that reads as "broken" rather than "configured off for this app".
    private func currentBlockReason() -> SwitchBlockReason {
        SwitchBlockReason.resolve(
            health: keyboardMonitor.health,
            isAutoSwitchEnabled: prefsService.isAutoSwitchEnabled,
            isEntitled: LicenseService.shared.isEntitled,
            secureInputAppName: keyboardMonitor.health == .secureInput ? secureInputAppName() : nil,
            appProfileBlock: appProfileBlock()
        )
    }

    private func appProfileBlock() -> (kind: SwitchBlockReason.AppProfileBlockKind, appName: String?)? {
        if exceptionsService.isCurrentAppExcepted() {
            return (.autoSwitch, exceptionsService.currentAppName())
        }
        if exceptionsService.isInstantCorrectionBlockedForCurrentApp() {
            return (.instantCorrectionOnly, exceptionsService.currentAppName())
        }
        return nil
    }

    /// Best-effort label for whichever app is holding secure input —
    /// approximated as the frontmost app, since `IsSecureEventInputEnabled()`
    /// is a session-wide WindowServer flag that in practice is only ever set
    /// by the app owning the currently focused secure field. Never guessed
    /// beyond that: if there's no frontmost app, the menu line falls back to
    /// the generic "Ввод пароля" wording (`SwitchBlockReason.title`, nil case).
    private func secureInputAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    /// Composite (non-template) image: a "keycap" chip with the language
    /// code punched out as negative space, plus a fixed-color status dot in
    /// the bottom-right corner. NOT a template image on purpose — template
    /// rendering strips color and keeps only alpha, which would make the
    /// green/red dot invisible (it would be recolored to match the menu bar
    /// like everything else). Instead the keycap itself is filled with
    /// `NSColor.labelColor` — a dynamic system color that AppKit re-resolves
    /// every time this drawing handler runs, so it still tracks light/dark
    /// menu bar without `isTemplate`.
    private static func makeStatusImage(label: String, reason: SwitchBlockReason) -> NSImage {
        let size = NSSize(width: 26, height: 18)
        return NSImage(size: size, flipped: false) { rect in
            let inset: CGFloat = 1
            let bodyRect = NSRect(x: inset, y: inset,
                                  width: rect.width - 2 * inset,
                                  height: rect.height - 2 * inset)
            let badge = NSBezierPath(roundedRect: bodyRect, xRadius: 5, yRadius: 5)
            NSColor.labelColor.setFill()
            badge.fill()

            let fontSize: CGFloat = label.count <= 2 ? 10.5 : 9
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: NSColor.labelColor,
                .kern: 0.3,
            ]
            let attr = NSAttributedString(string: label, attributes: attrs)
            let textSize = attr.size()
            let origin = NSPoint(x: (rect.width - textSize.width) / 2,
                                 y: (rect.height - textSize.height) / 2 - 0.5)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            attr.draw(at: origin)
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            // Status dot, bottom-right. A slightly larger "halo" is punched
            // out first (destinationOut, same technique as the letter cutout
            // above) so the dot always separates from the keycap by exposing
            // the real menu bar behind it — that works in light/dark/
            // highlighted menu bar alike, unlike hard-coding a background color.
            let dotDiameter: CGFloat = 6
            let haloDiameter: CGFloat = dotDiameter + 1.5
            let center = NSPoint(x: rect.width - dotDiameter / 2 - 1, y: dotDiameter / 2 + 1)
            let haloRect = NSRect(x: center.x - haloDiameter / 2, y: center.y - haloDiameter / 2,
                                  width: haloDiameter, height: haloDiameter)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: haloRect).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            let dotRect = NSRect(x: center.x - dotDiameter / 2, y: center.y - dotDiameter / 2,
                                 width: dotDiameter, height: dotDiameter)
            (reason.blocksSwitching ? NSColor.systemRed : NSColor.systemGreen).setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            return true
        }
    }

    @objc private func layoutChanged() {
        updateStatusIcon()
        rebuildMenu()
    }

    @objc private func autoSwitchStateChanged() {
        updateStatusIcon()
        rebuildMenu()
    }

    /// Deliberately minimal (03.08.2026 → panel-ification): everything that
    /// used to be a menu item (permissions repair, per-app layout, license,
    /// exceptions, autostart, logs) now lives inside the settings window
    /// itself — see MainView. The menu keeps only what you need without
    /// opening that window: jump to it, pause/resume, quit.
    private func rebuildMenu() {
        let menu = NSMenu()

        // Grey, non-clickable diagnostic line — only present while switching
        // is actually blocked (SwitchBlockReason.title is nil otherwise, see
        // п.2). `isEnabled = false` is what gives NSMenuItem its greyed-out,
        // unclickable rendering for free.
        if let reason = currentBlockReason().title {
            let reasonItem = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
            reasonItem.isEnabled = false
            menu.addItem(reasonItem)
            menu.addItem(NSMenuItem.separator())
        }

        let settingsItem = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Owner's request 19.08: the item names the FEATURE and its state,
        // not the action ("Пауза"/"Возобновить" read as player controls and
        // hid what was actually being toggled). The checkmark carries the
        // state for a glance; the title spells it out for certainty.
        let autoSwitchOn = prefsService.isAutoSwitchEnabled
        let autoSwitchItem = NSMenuItem(
            title: autoSwitchOn ? "Автопереключение: включено" : "Автопереключение: выключено",
            action: #selector(toggleAutoSwitch(_:)), keyEquivalent: ""
        )
        autoSwitchItem.state = autoSwitchOn ? .on : .off
        autoSwitchItem.target = self
        menu.addItem(autoSwitchItem)

        if timedPauseService.isActive {
            let resumeItem = NSMenuItem(
                title: "Возобновить сейчас", action: #selector(resumeTimedPause), keyEquivalent: ""
            )
            resumeItem.target = self
            menu.addItem(resumeItem)
        } else if autoSwitchOn {
            let pauseItem = NSMenuItem(title: "Пауза на…", action: nil, keyEquivalent: "")
            let pauseMenu = NSMenu(title: "Пауза на…")
            for (title, seconds) in [("15 минут", 15 * 60.0), ("1 час", 60 * 60.0), ("2 часа", 2 * 60 * 60.0)] {
                let item = NSMenuItem(title: title, action: #selector(startTimedPause(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = seconds
                pauseMenu.addItem(item)
            }
            pauseItem.submenu = pauseMenu
            menu.addItem(pauseItem)
        }

        let permissionsItem = NSMenuItem(title: "Настройка разрешений…",
                                         action: #selector(openPermissions), keyEquivalent: "")
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Выйти", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func refreshMenu() {
        updateStatusIcon()
        rebuildMenu()
    }

    @objc private func openSettings() {
        if let w = mainWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let vm = MainViewModel(
            statsService: statsService,
            prefsService: prefsService,
            inputSourceManager: inputSourceManager,
            perAppLayoutService: perAppLayoutService,
            keyboardMonitor: keyboardMonitor,
            autoStartService: autoStartService,
            timedPauseService: timedPauseService,
            settingsBackupService: SettingsBackupService(
                prefsService: prefsService,
                exceptionsService: exceptionsService,
                perAppLayoutService: perAppLayoutService,
                snippetService: snippetService
            )
        )
        vm.onOpenAbout = { [weak self] in self?.openAbout() }
        vm.onOpenExceptions = { [weak self] in self?.openExceptions() }
        vm.onOpenLicense = { [weak self] in self?.openLicense() }

        // Sizes itself to its content, so switching tabs changes the window's
        // own height — see SmoothResizeWindow for why that has to be animated
        // here rather than in the view.
        let window = SmoothResizeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = AppIdentity.displayName
        window.contentView = NSHostingView(rootView: MainView(viewModel: vm).gammaThemedRoot())
        window.center()
        window.isReleasedWhenClosed = false
        trackWindowForDockIcon(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow = window
    }

    @objc private func openExceptions() {
        if let w = exceptionsWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let vm = ExceptionsViewModel(
            exceptionsService: exceptionsService, snippetService: snippetService
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Исключения"
        window.contentView = NSHostingView(rootView: ExceptionsView(viewModel: vm).gammaThemedRoot())
        window.center()
        window.isReleasedWhenClosed = false
        trackWindowForDockIcon(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        exceptionsWindow = window
    }

    @objc private func openAbout() {
        if let w = aboutWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "О программе"
        window.contentView = NSHostingView(
            rootView: AboutView { [weak self] in self?.confirmDeleteLocalData() }
                .gammaThemedRoot()
        )
        window.center()
        window.isReleasedWhenClosed = false
        trackWindowForDockIcon(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow = window
    }

    @objc private func openLicense() {
        if let w = licenseWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Лицензия"
        window.contentView = NSHostingView(rootView: LicenseView().gammaThemedRoot())
        window.center()
        window.isReleasedWhenClosed = false
        trackWindowForDockIcon(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        licenseWindow = window
    }

    /// Registers a freshly-created window with `DockIconController` (Dock
    /// icon appears while ≥1 tracked window is open) and self-removes the
    /// close observer the moment the window actually closes — these windows
    /// (`isReleasedWhenClosed = false`, but re-created from scratch on every
    /// reopen after a close, see the `openXxx` guards above) would otherwise
    /// leave one dead observer behind per open/close cycle over a long
    /// session. Shared by every window this controller creates so the
    /// Dock-icon bookkeeping lives in exactly one place.
    private func trackWindowForDockIcon(_ window: NSWindow) {
        DockIconController.shared.windowOpened()
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            DockIconController.shared.windowClosed()
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    private func confirmDeleteLocalData() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Удалить все локальные данные Qwerty Switcher?"
        alert.informativeText = "Будут удалены настройки, статистика, исключения, обученные слова, кэш и логи. Отменить это действие нельзя."
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try autoStartService.setEnabled(false)
            try PrivacyService.deleteAllLocalData()
            NSApp.terminate(nil)
        } catch {
            let failure = NSAlert(error: error)
            failure.messageText = "Не удалось удалить все локальные данные"
            failure.runModal()
        }
    }

    @objc private func toggleAutoSwitch(_ sender: NSMenuItem) {
        prefsService.isAutoSwitchEnabled.toggle()
        let enabled = prefsService.isAutoSwitchEnabled
        DebugLog.shared.log("UI", "auto-switch → \(enabled ? "ON" : "OFF") (menu)")
        // Title/state ("Автопереключение: …") is recomputed by rebuildMenu(), which
        // the .autoSwitchToggled observer already triggers via refreshMenu().
        NotificationCenter.default.post(name: .autoSwitchToggled, object: nil)
    }

    @objc private func startTimedPause(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        timedPauseService.pause(for: seconds)
    }

    @objc private func resumeTimedPause() {
        timedPauseService.resumeNow()
    }

    @objc private func openPermissions() {
        onOpenPermissions?()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
