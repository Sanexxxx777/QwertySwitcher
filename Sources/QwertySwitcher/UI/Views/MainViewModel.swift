import SwiftUI
import AppKit

final class MainViewModel: ObservableObject {
    private let statsService: StatisticsService
    private let prefsService: PreferencesService
    private let inputSourceManager: InputSourceManager
    private let perAppLayoutService: PerAppLayoutService
    private let keyboardMonitor: KeyboardMonitor
    private let autoStartService: AutoStartService
    private let permissionsService = PermissionsService()
    var onOpenAbout: (() -> Void)?
    var onOpenExceptions: (() -> Void)?
    var onOpenLicense: (() -> Void)?

    @Published var autoSwitchCount: Int = 0
    @Published var shiftSwitchCount: Int = 0
    @Published var doubleShiftCount: Int = 0
    @Published var eventTapHealth: EventTapHealth

    @Published var isAutoSwitchEnabled: Bool {
        didSet {
            prefsService.isAutoSwitchEnabled = isAutoSwitchEnabled
            NotificationCenter.default.post(name: .autoSwitchToggled, object: nil)
        }
    }
    @Published var isSplitShiftEnabled: Bool {
        didSet { prefsService.isSplitShiftEnabled = isSplitShiftEnabled }
    }
    @Published var isPasteNoFormatEnabled: Bool {
        didSet { prefsService.isPasteNoFormatEnabled = isPasteNoFormatEnabled }
    }
    @Published var isYoficatorEnabled: Bool {
        didSet { prefsService.isYoficatorEnabled = isYoficatorEnabled }
    }
    @Published var isSoundEnabled: Bool {
        didSet { prefsService.isSoundEnabled = isSoundEnabled }
    }
    @Published var isLayoutSoundEnabled: Bool {
        didSet { prefsService.isLayoutSoundEnabled = isLayoutSoundEnabled }
    }
    @Published var layoutSoundName: String {
        didSet { prefsService.layoutSoundName = layoutSoundName }
    }
    @Published var isSingleShiftEnabled: Bool {
        didSet { prefsService.isSingleShiftEnabled = isSingleShiftEnabled }
    }
    @Published var isDoubleShiftEnabled: Bool {
        didSet { prefsService.isDoubleShiftEnabled = isDoubleShiftEnabled }
    }
    @Published var isCapsLockSwitchEnabled: Bool {
        didSet { prefsService.isCapsLockSwitchEnabled = isCapsLockSwitchEnabled }
    }
    @Published var isInstantCorrectionEnabled: Bool {
        didSet { prefsService.isInstantCorrectionEnabled = isInstantCorrectionEnabled }
    }
    @Published var isVerboseLogEnabled: Bool {
        didSet { prefsService.isVerboseLogEnabled = isVerboseLogEnabled }
    }
    @Published var isPerAppLayoutEnabled: Bool {
        didSet { perAppLayoutService.isEnabled = isPerAppLayoutEnabled }
    }
    @Published var isAutoStartEnabled: Bool {
        didSet {
            guard isAutoStartEnabled != autoStartService.isEnabled else { return }
            try? autoStartService.setEnabled(isAutoStartEnabled)
            isAutoStartEnabled = autoStartService.isEnabled
        }
    }
    @Published var themePreference: ThemePreference {
        didSet {
            prefsService.themePreference = themePreference
            NotificationCenter.default.post(name: .themePreferenceChanged, object: nil)
        }
    }
    @Published var selectedEnglishLayoutID: String {
        didSet { persistActiveLayouts() }
    }
    @Published var selectedRussianLayoutID: String {
        didSet { persistActiveLayouts() }
    }

    var englishLayouts: [KeyboardLayout] {
        inputSourceManager.supportedLayouts.filter { $0.isEnglish }
    }

    var russianLayouts: [KeyboardLayout] {
        inputSourceManager.supportedLayouts.filter { $0.isRussian }
    }

    /// True only when the event tap can't run because Accessibility or Input
    /// Monitoring was revoked after launch — the one case the in-window
    /// status can't self-heal without sending the user to System Settings.
    var needsPermissionRepair: Bool { eventTapHealth == .missingPermissions }

    /// Same sequencing as onboarding: prompt first, System Settings only as the
    /// fallback. Firing both at once put two foreign windows in front of ours.
    func openPermissionRepair() {
        switch OnboardingStateMachine.pendingPermission(for: permissionsStatus) {
        case .accessibility:
            permissionsService.requestAccessibilityThenSettings()
        case .inputMonitoring:
            permissionsService.requestInputMonitoringThenSettings()
        case nil:
            break
        }
    }

    private var permissionsStatus: OnboardingStatus {
        OnboardingStatus(
            hasAccessibility: permissionsService.hasAccessibility,
            hasInputMonitoring: permissionsService.hasInputMonitoring,
            isInterceptionRunning: eventTapHealth == .running || eventTapHealth == .secureInput
        )
    }

    /// Last ~20 lines of the debug log, for the in-window log preview.
    var logTail: String {
        let lines = DebugLog.shared.currentContents.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(20).joined(separator: "\n")
    }

    func openLogFile() {
        NSWorkspace.shared.open(DebugLog.shared.fileURL)
    }

    func revealLogFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([DebugLog.shared.fileURL])
    }

    init(statsService: StatisticsService, prefsService: PreferencesService,
         inputSourceManager: InputSourceManager,
         perAppLayoutService: PerAppLayoutService,
         keyboardMonitor: KeyboardMonitor,
         autoStartService: AutoStartService) {
        self.statsService = statsService
        self.prefsService = prefsService
        self.inputSourceManager = inputSourceManager
        self.perAppLayoutService = perAppLayoutService
        self.keyboardMonitor = keyboardMonitor
        self.autoStartService = autoStartService

        self.isAutoSwitchEnabled = prefsService.isAutoSwitchEnabled
        self.isSplitShiftEnabled = prefsService.isSplitShiftEnabled
        self.isPasteNoFormatEnabled = prefsService.isPasteNoFormatEnabled
        self.isYoficatorEnabled = prefsService.isYoficatorEnabled
        self.isSoundEnabled = prefsService.isSoundEnabled
        self.isLayoutSoundEnabled = prefsService.isLayoutSoundEnabled
        self.layoutSoundName = prefsService.layoutSoundName
        self.isSingleShiftEnabled = prefsService.isSingleShiftEnabled
        self.isDoubleShiftEnabled = prefsService.isDoubleShiftEnabled
        self.isCapsLockSwitchEnabled = prefsService.isCapsLockSwitchEnabled
        self.isInstantCorrectionEnabled = prefsService.isInstantCorrectionEnabled
        self.isVerboseLogEnabled = prefsService.isVerboseLogEnabled
        self.isPerAppLayoutEnabled = perAppLayoutService.isEnabled
        self.isAutoStartEnabled = autoStartService.isEnabled
        self.themePreference = prefsService.themePreference
        let activeLayouts = inputSourceManager.resolvedActiveLayouts(
            preferredIDs: prefsService.activeLayoutIDs
        )
        self.selectedEnglishLayoutID = activeLayouts.first(where: \.isEnglish)?.id
            ?? inputSourceManager.supportedLayouts.first(where: \.isEnglish)?.id
            ?? ""
        self.selectedRussianLayoutID = activeLayouts.first(where: \.isRussian)?.id
            ?? inputSourceManager.supportedLayouts.first(where: \.isRussian)?.id
            ?? ""
        self.eventTapHealth = keyboardMonitor.health
        refreshStats()

        NotificationCenter.default.addObserver(
            self, selector: #selector(onStatsUpdated),
            name: .statsUpdated, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(onAutoSwitchUpdated),
            name: .autoSwitchToggled, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(onHealthUpdated),
            name: .eventTapHealthChanged, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func onStatsUpdated() {
        DispatchQueue.main.async {
            self.refreshStats()
        }
    }

    @objc private func onAutoSwitchUpdated() {
        DispatchQueue.main.async {
            let value = self.prefsService.isAutoSwitchEnabled
            if self.isAutoSwitchEnabled != value { self.isAutoSwitchEnabled = value }
        }
    }

    @objc private func onHealthUpdated() {
        DispatchQueue.main.async {
            self.eventTapHealth = self.keyboardMonitor.health
        }
    }

    private func persistActiveLayouts() {
        let ids = [selectedEnglishLayoutID, selectedRussianLayoutID].filter { !$0.isEmpty }
        guard ids.count == 2 else { return }
        prefsService.activeLayoutIDs = ids
        NotificationCenter.default.post(name: .activeLayoutsChanged, object: nil)
    }

    /// Plays the currently selected layout sound so the owner can audition
    /// choices in Settings without needing to trigger a real layout switch.
    func previewLayoutSound() {
        SoundService.shared.previewLayoutSound(named: layoutSoundName)
    }

    func resetStats() {
        statsService.resetAll()
        refreshStats()
    }

    func refreshStats() {
        autoSwitchCount = statsService.autoSwitchCount
        shiftSwitchCount = statsService.shiftSwitchCount
        doubleShiftCount = statsService.optionSwitchCount
    }
}

extension Notification.Name {
    static let activeLayoutsChanged = Notification.Name(AppIdentity.keyPrefix + "activeLayoutsChanged")
}
