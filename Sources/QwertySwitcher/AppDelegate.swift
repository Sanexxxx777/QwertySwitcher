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
    private var updateController: UpdateController!
    /// Separate from whatever `KeyboardMonitor` uses internally — Core is
    /// read-only for this wave, so the updater gets its own instance rather
    /// than reaching into the monitor's private state.
    private let updateSecureInputDetector = SecureInputDetector()

    func applicationDidFinishLaunching(_ notification: Notification) {
        StorageMigrationService.migrateIfNeeded()
        _ = PrivacyService.auditStorage()

        prefsService = PreferencesService()
        UpdateStartupGuard.onNormalLaunchStarted(prefs: prefsService)
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

        updateController = UpdateController(
            prefsService: prefsService,
            safetySnapshotProvider: { [weak self] in
                self?.keyboardMonitor?.updateSafetySnapshot ?? (idleSeconds: 0, gameModeActive: false, replacing: true)
            },
            secureInputProvider: { [weak self] in self?.updateSecureInputDetector.isSecureInput ?? true }
        )
        updateController.start()

        statusBar = StatusBarController(
            statsService: statsService,
            prefsService: prefsService,
            exceptionsService: exceptionsService,
            keyboardMonitor: keyboardMonitor,
            inputSourceManager: inputSourceManager,
            perAppLayoutService: perAppLayoutService,
            timedPauseService: timedPauseService,
            snippetService: snippetService,
            updateController: updateController
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

        // Fresh installs (onboardingSeen still false) see this at their NEXT
        // launch instead — a deliberate simplification, not a bug: piling a
        // second alert on top of the onboarding window on day one is worse
        // than asking a launch later.
        if seen && !prefsService.updatesPromptSeen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.presentUpdateCheckPrompt()
            }
        }

        keyboardMonitor.refreshHealth()
        startHealthPolling()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        NSLog("[QwertySwitcher] v\(version) Started. Dictionary: \(dictionary.stats)")
        NSLog("[QwertySwitcher] Layouts: \(inputSourceManager.availableLayouts.map(\.name))")
        NSLog("[QwertySwitcher] Privacy: all input processed locally, never leaves the Mac. "
            + "Network is used only if you enable update checks: once a day the app fetches "
            + "a single JSON from shulgin.is-a.dev and sends nothing about you.")

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

    // MARK: - Updates

    /// One-time alert (see `updatesPromptSeen`): the answer sets
    /// `updatesAutoCheck` and never asks again. Installation stays manual
    /// until the owner separately flips it on in Settings.
    private func presentUpdateCheckPrompt() {
        guard !prefsService.updatesPromptSeen else { return }
        let alert = NSAlert()
        alert.messageText = "Проверять обновления автоматически?"
        alert.informativeText = "Раз в сутки приложение запросит один файл с shulgin.is-a.dev. "
            + "Ничего о вас не отправляется. Установка обновлений останется ручной, "
            + "пока вы не включите её в настройках."
        alert.addButton(withTitle: "Проверять")
        alert.addButton(withTitle: "Не сейчас")
        let response = alert.runModal()
        prefsService.updatesAutoCheck = (response == .alertFirstButtonReturn)
        prefsService.updatesPromptSeen = true
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
