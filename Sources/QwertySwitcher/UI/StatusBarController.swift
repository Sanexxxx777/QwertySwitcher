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
    private let autoStartService = AutoStartService()
    private let permissionsService = PermissionsService()
    private var mainWindow: NSWindow?
    private var exceptionsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var licenseWindow: NSWindow?

    init(statsService: StatisticsService, prefsService: PreferencesService,
         exceptionsService: ExceptionsService, keyboardMonitor: KeyboardMonitor,
         inputSourceManager: InputSourceManager,
         perAppLayoutService: PerAppLayoutService) {
        self.statsService = statsService
        self.prefsService = prefsService
        self.exceptionsService = exceptionsService
        self.keyboardMonitor = keyboardMonitor
        self.inputSourceManager = inputSourceManager
        self.perAppLayoutService = perAppLayoutService
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
        let licensed = LicenseService.shared.isEntitled
        let code = keyboardMonitor.health == .running ? languageCode : "!"
        let paused = !prefsService.isAutoSwitchEnabled || keyboardMonitor.health != .running || !licensed
        button.image = Self.makeStatusImage(label: code, paused: paused)
        button.imagePosition = .imageOnly
        button.title = ""
        if keyboardMonitor.health != .running {
            button.toolTip = "\(AppIdentity.displayName) · \(keyboardMonitor.health.title)"
        } else if !licensed {
            button.toolTip = "\(AppIdentity.displayName) · подписка истекла — активируйте ключ"
        } else {
            button.toolTip = paused
                ? "\(AppIdentity.displayName) · автопереключение отключено"
                : "\(AppIdentity.displayName) · \(languageCode) · автопереключение включено"
        }
    }

    /// Monochrome template image — rounded rect outline + language code inside.
    /// `isTemplate = true` tells AppKit to recolor it to match the menu bar
    /// (white on dark, black on light), matching native menu bar aesthetics.
    private static func makeStatusImage(label: String, paused: Bool) -> NSImage {
        let size = NSSize(width: 26, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        // For template images only the alpha channel matters — colors will be
        // replaced by the system at render time. We draw in opaque black.
        NSColor.black.setStroke()
        NSColor.black.setFill()

        let inset: CGFloat = paused ? 2.5 : 1.0
        let rect = NSRect(x: inset + 0.5, y: 1.5,
                          width: size.width - 2 * inset - 1,
                          height: size.height - 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        path.lineWidth = paused ? 1.0 : 1.3
        path.stroke()

        let fontSize: CGFloat = label.count <= 2 ? 10 : 9
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
            .foregroundColor: NSColor.black,
            .kern: 0.4,
        ]
        let attr = NSAttributedString(string: label, attributes: attrs)
        let textSize = attr.size()
        let origin = NSPoint(x: (size.width - textSize.width) / 2,
                             y: (size.height - textSize.height) / 2 - 0.5)
        attr.draw(at: origin)

        image.unlockFocus()
        image.isTemplate = true   // system adapts to menu bar color
        return image
    }

    @objc private func layoutChanged() {
        updateStatusIcon()
        rebuildMenu()
    }

    @objc private func autoSwitchStateChanged() {
        updateStatusIcon()
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let headerItem = NSMenuItem(title: AppIdentity.displayName, action: nil, keyEquivalent: "")
        headerItem.attributedTitle = NSAttributedString(
            string: AppIdentity.displayName,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        let healthItem = NSMenuItem(
            title: "Состояние: \(keyboardMonitor.health.title)",
            action: nil,
            keyEquivalent: ""
        )
        healthItem.isEnabled = false
        menu.addItem(healthItem)

        let permissionStatus = permissionsService.hasAccessibility && permissionsService.hasInputMonitoring
            ? "Разрешения: выданы"
            : "Разрешения: нужна настройка"
        let permissionItem = NSMenuItem(title: permissionStatus, action: nil, keyEquivalent: "")
        permissionItem.isEnabled = false
        menu.addItem(permissionItem)

        if !permissionsService.hasAccessibility || !permissionsService.hasInputMonitoring {
            let repairItem = NSMenuItem(
                title: "Настроить разрешения…",
                action: #selector(openPermissions),
                keyEquivalent: ""
            )
            repairItem.target = self
            menu.addItem(repairItem)
        }
        menu.addItem(NSMenuItem.separator())

        let autoSwitchItem = NSMenuItem(
            title: "Автопереключение",
            action: #selector(toggleAutoSwitch(_:)),
            keyEquivalent: ""
        )
        autoSwitchItem.target = self
        autoSwitchItem.state = prefsService.isAutoSwitchEnabled ? .on : .off
        menu.addItem(autoSwitchItem)

        let perAppItem = NSMenuItem(
            title: "Раскладка для каждого приложения",
            action: #selector(togglePerAppLayout(_:)),
            keyEquivalent: ""
        )
        perAppItem.target = self
        perAppItem.state = perAppLayoutService.isEnabled ? .on : .off
        menu.addItem(perAppItem)

        let settingsItem = NSMenuItem(title: "Настройки", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let licenseTitle = LicenseService.shared.isEntitled
            ? "Лицензия…"
            : "⚠ Подписка истекла — Активировать…"
        let licenseItem = NSMenuItem(title: licenseTitle, action: #selector(openLicense), keyEquivalent: "")
        licenseItem.target = self
        menu.addItem(licenseItem)

        let exceptionsItem = NSMenuItem(title: "Исключения", action: #selector(openExceptions), keyEquivalent: "")
        exceptionsItem.target = self
        menu.addItem(exceptionsItem)

        let autoStartItem = NSMenuItem(title: "Автозапуск", action: #selector(toggleAutoStart(_:)), keyEquivalent: "")
        autoStartItem.target = self
        autoStartItem.state = autoStartService.isEnabled ? .on : .off
        menu.addItem(autoStartItem)

        menu.addItem(NSMenuItem.separator())

        let showLogItem = NSMenuItem(title: "Показать логи", action: #selector(openLogs), keyEquivalent: "")
        showLogItem.target = self
        menu.addItem(showLogItem)

        let revealLogItem = NSMenuItem(title: "Открыть папку логов", action: #selector(revealLogsInFinder), keyEquivalent: "")
        revealLogItem.target = self
        menu.addItem(revealLogItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Выйти", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(DebugLog.shared.fileURL)
    }

    @objc private func revealLogsInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([DebugLog.shared.fileURL])
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
            keyboardMonitor: keyboardMonitor
        )
        vm.onOpenAbout = { [weak self] in self?.openAbout() }
        vm.onOpenExceptions = { [weak self] in self?.openExceptions() }
        vm.onOpenLicense = { [weak self] in self?.openLicense() }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = AppIdentity.displayName
        window.minSize = NSSize(width: 600, height: 620)
        window.contentView = NSHostingView(rootView: MainView(viewModel: vm))
        window.center()
        window.isReleasedWhenClosed = false
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

        let vm = ExceptionsViewModel(exceptionsService: exceptionsService)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Исключения"
        window.contentView = NSHostingView(rootView: ExceptionsView(viewModel: vm))
        window.center()
        window.isReleasedWhenClosed = false
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
        )
        window.center()
        window.isReleasedWhenClosed = false
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
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Лицензия"
        window.contentView = NSHostingView(rootView: LicenseView())
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        licenseWindow = window
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

    @objc private func toggleAutoStart(_ sender: NSMenuItem) {
        autoStartService.toggle()
        sender.state = autoStartService.isEnabled ? .on : .off
    }

    @objc private func toggleAutoSwitch(_ sender: NSMenuItem) {
        prefsService.isAutoSwitchEnabled.toggle()
        NotificationCenter.default.post(name: .autoSwitchToggled, object: nil)
        sender.state = prefsService.isAutoSwitchEnabled ? .on : .off
    }

    @objc private func togglePerAppLayout(_ sender: NSMenuItem) {
        perAppLayoutService.isEnabled.toggle()
        sender.state = perAppLayoutService.isEnabled ? .on : .off
    }

    @objc private func openPermissions() {
        if !permissionsService.hasAccessibility {
            permissionsService.requestAccessibility()
            permissionsService.openAccessibilitySettings()
        } else if !permissionsService.hasInputMonitoring {
            permissionsService.requestInputMonitoring()
            permissionsService.openInputMonitoringSettings()
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
