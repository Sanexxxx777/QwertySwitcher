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
    private let autoStartService = AutoStartService()
    private var mainWindow: NSWindow?
    private var exceptionsWindow: NSWindow?
    private var aboutWindow: NSWindow?

    init(statsService: StatisticsService, prefsService: PreferencesService,
         exceptionsService: ExceptionsService, keyboardMonitor: KeyboardMonitor,
         inputSourceManager: InputSourceManager) {
        self.statsService = statsService
        self.prefsService = prefsService
        self.exceptionsService = exceptionsService
        self.keyboardMonitor = keyboardMonitor
        self.inputSourceManager = inputSourceManager
        setupStatusItem()

        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshMenu),
            name: .autoSwitchToggled, object: nil
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
        let code = (inputSourceManager.currentLayout?.languageCode ?? "en").uppercased()
        let paused = !prefsService.isAutoSwitchEnabled
        let label = paused ? "\u{2053}" : code  // swung dash when paused
        button.image = Self.makeStatusImage(label: label, paused: paused)
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = paused
            ? "Sasha Switcher · автопереключение отключено"
            : "Sasha Switcher · \(code) · автопереключение включено"
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

        let headerItem = NSMenuItem(title: "Sasha Switcher", action: nil, keyEquivalent: "")
        headerItem.attributedTitle = NSAttributedString(
            string: "Sasha Switcher",
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Настройки", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

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

    @objc private func refreshMenu() { rebuildMenu() }

    @objc private func openSettings() {
        if let w = mainWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let vm = MainViewModel(statsService: statsService, prefsService: prefsService)
        vm.onOpenAbout = { [weak self] in self?.openAbout() }
        vm.onOpenExceptions = { [weak self] in self?.openExceptions() }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Sasha Switcher"
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
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "О программе"
        window.contentView = NSHostingView(rootView: AboutView())
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow = window
    }

    @objc private func toggleAutoStart(_ sender: NSMenuItem) {
        autoStartService.toggle()
        sender.state = autoStartService.isEnabled ? .on : .off
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
