import SwiftUI

final class MainViewModel: ObservableObject {
    private let statsService: StatisticsService
    private let prefsService: PreferencesService
    private let inputSourceManager: InputSourceManager
    private let perAppLayoutService: PerAppLayoutService
    private let keyboardMonitor: KeyboardMonitor
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
    @Published var isSingleShiftEnabled: Bool {
        didSet { prefsService.isSingleShiftEnabled = isSingleShiftEnabled }
    }
    @Published var isDoubleShiftEnabled: Bool {
        didSet { prefsService.isDoubleShiftEnabled = isDoubleShiftEnabled }
    }
    @Published var isCapsLockSwitchEnabled: Bool {
        didSet { prefsService.isCapsLockSwitchEnabled = isCapsLockSwitchEnabled }
    }
    @Published var isPerAppLayoutEnabled: Bool {
        didSet { perAppLayoutService.isEnabled = isPerAppLayoutEnabled }
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

    init(statsService: StatisticsService, prefsService: PreferencesService,
         inputSourceManager: InputSourceManager,
         perAppLayoutService: PerAppLayoutService,
         keyboardMonitor: KeyboardMonitor) {
        self.statsService = statsService
        self.prefsService = prefsService
        self.inputSourceManager = inputSourceManager
        self.perAppLayoutService = perAppLayoutService
        self.keyboardMonitor = keyboardMonitor

        self.isAutoSwitchEnabled = prefsService.isAutoSwitchEnabled
        self.isSplitShiftEnabled = prefsService.isSplitShiftEnabled
        self.isPasteNoFormatEnabled = prefsService.isPasteNoFormatEnabled
        self.isYoficatorEnabled = prefsService.isYoficatorEnabled
        self.isSoundEnabled = prefsService.isSoundEnabled
        self.isSingleShiftEnabled = prefsService.isSingleShiftEnabled
        self.isDoubleShiftEnabled = prefsService.isDoubleShiftEnabled
        self.isCapsLockSwitchEnabled = prefsService.isCapsLockSwitchEnabled
        self.isPerAppLayoutEnabled = perAppLayoutService.isEnabled
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
