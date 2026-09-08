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
    private var timedPauseService: TimedPauseService!
    private var snippetService: SnippetService!
    private var onboardingController: OnboardingWindowController?
    private var healthTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        StorageMigrationService.migrateIfNeeded()
        _ = PrivacyService.auditStorage()

        prefsService = PreferencesService()
        timedPauseService = TimedPauseService(prefsService: prefsService)
        SoundService.prefs = prefsService
        statsService = StatisticsService()
        exceptionsService = ExceptionsService()
        snippetService = SnippetService()
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
        let instantCorrectionAnalyzer = InstantCorrectionAnalyzer(dictionary: dictionary)

        keyboardMonitor = KeyboardMonitor(
            languageDetector: languageDetector,
            textReplacer: textReplacer,
            statsService: statsService,
            prefsService: prefsService,
            exceptionsService: exceptionsService,
            yoficatorService: yoficatorService,
            switchUndoManager: switchUndoManager,
            perAppLayoutService: perAppLayoutService,
            instantCorrectionAnalyzer: instantCorrectionAnalyzer,
            snippetService: snippetService
        )

        hotkeyManager = HotkeyManager(
            inputSourceManager: inputSourceManager,
            languageDetector: languageDetector,
            textReplacer: textReplacer,
            statsService: statsService,
            prefsService: prefsService,
            exceptionsService: exceptionsService
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
            perAppLayoutService: perAppLayoutService,
            timedPauseService: timedPauseService,
            snippetService: snippetService
        )

        // Status-bar escape hatch: onboarding can always be re-opened, so a
        // closed (or previously buried) window is never a dead end.
        statusBar.onOpenPermissions = { [weak self] in self?.showOnboardingWindow() }

        let perms = PermissionsService()
        let onboardingSeenKey = AppIdentity.keyPrefix + "onboardingSeen"
        let seen = UserDefaults.standard.bool(forKey: onboardingSeenKey)
        let needsOnboarding = !seen || !perms.hasAccessibility || !perms.hasInputMonitoring
        if needsOnboarding {
            NSLog("[QwertySwitcher] Showing onboarding (seen=\(seen) ax=\(perms.hasAccessibility) im=\(perms.hasInputMonitoring))")
            showOnboardingWindow()
        }

        keyboardMonitor.refreshHealth()
        startHealthPolling()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        NSLog("[QwertySwitcher] v\(version) Started. Dictionary: \(dictionary.stats)")
        NSLog("[QwertySwitcher] Layouts: \(inputSourceManager.availableLayouts.map(\.name))")
        NSLog("[QwertySwitcher] Privacy: all input processed locally, never leaves the Mac. "
            + "No network access.")

        let layoutsStr = inputSourceManager.availableLayouts
            .map { "\($0.languageCode):\($0.name)" }.joined(separator: ",")
        DebugLog.shared.log("APP", "v\(version) started | layouts=[\(layoutsStr)] | dict=\(dictionary.stats)")
        DebugLog.shared.log("APP", "perms accessibility=\(perms.hasAccessibility) input_mon=\(perms.hasInputMonitoring)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLog.shared.log("APP", "shutting down")
        healthTimer?.invalidate()
        // Mechanism A/C (learning_spec.md): flush pending in-memory
        // mutations before the process exits — the only other flush point
        // is the ~30s timer inside `KeyboardMonitor` itself.
        keyboardMonitor?.flushLearning()
        keyboardMonitor?.stop()
        statsService?.save()
    }

    // MARK: - Onboarding

    private func showOnboardingWindow() {
        DispatchQueue.main.async { [weak self] in
            self?.presentOnboarding()
        }
    }

    /// The controller is retained for the whole app lifetime — the window is
    /// only ever hidden, never dropped, so it can be re-presented from the
    /// status-bar menu without a restart.
    private func presentOnboarding() {
        if onboardingController == nil {
            onboardingController = OnboardingWindowController(
                interceptionRunning: { [weak self] in
                    guard let health = self?.keyboardMonitor?.health else { return false }
                    return health == .running || health == .secureInput
                },
                onFinished: { [weak self] in
                    self?.keyboardMonitor?.refreshHealth()
                }
            )
        }
        onboardingController?.present()
    }

    /// 0.5s (was 1.0s) so a secure-input transition (`KeyboardMonitor.health`
    /// flips `.running` <-> `.secureInput`) shows up in the status-bar
    /// badge/menu line within the ~500ms the owner asked for. Reuses this
    /// existing timer instead of adding a second poll: `refreshHealth()`
    /// already calls `secureInputDetector.isSecureInput` (fast, no-IPC tier —
    /// see SecureInputDetector), and `health`'s `didSet` already posts
    /// `.eventTapHealthChanged`, which `StatusBarController` is already
    /// subscribed to — no new notification needed either.
    private func startHealthPolling() {
        healthTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.keyboardMonitor?.refreshHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }
}
