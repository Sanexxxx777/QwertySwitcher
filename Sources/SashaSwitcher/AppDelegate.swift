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
    private var healthTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        StorageMigrationService.migrateIfNeeded()
        _ = PrivacyService.auditStorage()

        prefsService = PreferencesService()
        SoundService.prefs = prefsService
        statsService = StatisticsService()
        exceptionsService = ExceptionsService()
        yoficatorService = YoficatorService()
        inputSourceManager = InputSourceManager()
        switchUndoManager = SwitchUndoManager()
        perAppLayoutService = PerAppLayoutService(
            inputSourceManager: inputSourceManager,
            prefsService: prefsService
        )

        let dictionary = WordDictionary()
        languageDetector = LanguageDetector(
            dictionary: dictionary,
            inputSourceManager: inputSourceManager,
            prefsService: prefsService
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
            inputSourceManager: inputSourceManager,
            perAppLayoutService: perAppLayoutService
        )

        let perms = PermissionsService()
        let onboardingSeenKey = AppIdentity.keyPrefix + "onboardingSeen"
        let seen = UserDefaults.standard.bool(forKey: onboardingSeenKey)
        let needsOnboarding = !seen || !perms.hasAccessibility || !perms.hasInputMonitoring
        if needsOnboarding {
            NSLog("[QwertySwitch] Showing onboarding (seen=\(seen) ax=\(perms.hasAccessibility) im=\(perms.hasInputMonitoring))")
            showOnboardingWindow()
        }

        keyboardMonitor.refreshHealth()
        startHealthPolling()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        NSLog("[QwertySwitch] v\(version) Started. Dictionary: \(dictionary.stats)")
        NSLog("[QwertySwitch] Layouts: \(inputSourceManager.availableLayouts.map(\.name))")
        NSLog("[QwertySwitch] Privacy: all processing local, no telemetry")

        let layoutsStr = inputSourceManager.availableLayouts
            .map { "\($0.languageCode):\($0.name)" }.joined(separator: ",")
        DebugLog.shared.log("APP", "v\(version) started | layouts=[\(layoutsStr)] | dict=\(dictionary.stats)")
        DebugLog.shared.log("APP", "perms accessibility=\(perms.hasAccessibility) input_mon=\(perms.hasInputMonitoring)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLog.shared.log("APP", "shutting down")
        healthTimer?.invalidate()
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
        window.title = AppIdentity.displayName
        window.center()
        window.isReleasedWhenClosed = false

        let view = OnboardingView(onContinue: { [weak self] in
            UserDefaults.standard.set(true, forKey: AppIdentity.keyPrefix + "onboardingSeen")
            self?.keyboardMonitor.refreshHealth()
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        })
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    private func startHealthPolling() {
        healthTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.keyboardMonitor?.refreshHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }
}
