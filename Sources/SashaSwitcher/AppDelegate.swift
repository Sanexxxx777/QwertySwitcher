import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private var keyboardMonitor: KeyboardMonitor!
    private var hotkeyManager: HotkeyManager!
    private var languageDetector: LanguageDetector!
    private var textReplacer: TextReplacer!
    private var inputSourceManager: InputSourceManager!
    private var statsService: StatisticsService!
    private var prefsService: PreferencesService!
    private var exceptionsService: ExceptionsService!
    private var yoficatorService: YoficatorService!
    private var perAppLayoutService: PerAppLayoutService!
    private var switchUndoManager: SwitchUndoManager!
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Privacy audit on launch
        PrivacyService.auditStorage()

        prefsService = PreferencesService()
        SoundService.prefs = prefsService
        statsService = StatisticsService()
        exceptionsService = ExceptionsService()
        yoficatorService = YoficatorService()
        inputSourceManager = InputSourceManager()
        switchUndoManager = SwitchUndoManager()
        perAppLayoutService = PerAppLayoutService(inputSourceManager: inputSourceManager)

        let dictionary = WordDictionary()
        languageDetector = LanguageDetector(
            dictionary: dictionary,
            inputSourceManager: inputSourceManager
        )

        textReplacer = TextReplacer(inputSourceManager: inputSourceManager)

        keyboardMonitor = KeyboardMonitor(
            languageDetector: languageDetector,
            textReplacer: textReplacer,
            statsService: statsService,
            prefsService: prefsService,
            exceptionsService: exceptionsService,
            yoficatorService: yoficatorService,
            switchUndoManager: switchUndoManager,
            perAppLayoutService: perAppLayoutService
        )

        hotkeyManager = HotkeyManager(
            inputSourceManager: inputSourceManager,
            languageDetector: languageDetector,
            textReplacer: textReplacer,
            statsService: statsService,
            prefsService: prefsService
        )
        hotkeyManager.switchUndoManager = switchUndoManager
        hotkeyManager.keyboardMonitor = keyboardMonitor
        keyboardMonitor.hotkeyManager = hotkeyManager

        statusBar = StatusBarController(
            statsService: statsService,
            prefsService: prefsService,
            exceptionsService: exceptionsService,
            keyboardMonitor: keyboardMonitor,
            inputSourceManager: inputSourceManager
        )

        let perms = PermissionsService()
        let onboardingSeenKey = "tech.sasha.switcher.onboardingSeen"
        let seen = UserDefaults.standard.bool(forKey: onboardingSeenKey)
        let needsOnboarding = !seen || !perms.hasAccessibility || !perms.hasInputMonitoring
        if needsOnboarding {
            NSLog("[SashaSwitcher] Showing onboarding (seen=\(seen) ax=\(perms.hasAccessibility) im=\(perms.hasInputMonitoring))")
            showOnboardingWindow()
        }

        keyboardMonitor.start()

        NSLog("[SashaSwitcher] v0.2.0 Started. Dictionary: \(dictionary.stats)")
        NSLog("[SashaSwitcher] Layouts: \(inputSourceManager.availableLayouts.map(\.name))")
        NSLog("[SashaSwitcher] Privacy: all processing local, no telemetry")

        let layoutsStr = inputSourceManager.availableLayouts
            .map { "\($0.languageCode):\($0.name)" }.joined(separator: ",")
        DebugLog.shared.log("APP", "v0.2.0 started | layouts=[\(layoutsStr)] | dict=\(dictionary.stats)")
        DebugLog.shared.log("APP", "perms accessibility=\(perms.hasAccessibility) input_mon=\(perms.hasInputMonitoring)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLog.shared.log("APP", "shutting down")
        keyboardMonitor?.stop()
        statsService?.save()
    }

    // MARK: - Onboarding

    private func showOnboardingWindow() {
        DispatchQueue.main.async { [weak self] in
            self?.presentOnboarding()
        }
    }

    private func presentOnboarding() {
        if onboardingWindow != nil { onboardingWindow?.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Sasha Switcher"
        window.center()
        window.isReleasedWhenClosed = false

        let view = OnboardingView(onContinue: { [weak self] in
            UserDefaults.standard.set(true, forKey: "tech.sasha.switcher.onboardingSeen")
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        })
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }
}
