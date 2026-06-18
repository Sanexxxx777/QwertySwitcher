import SwiftUI

final class MainViewModel: ObservableObject {
    private let statsService: StatisticsService
    private let prefsService: PreferencesService
    var onOpenAbout: (() -> Void)?
    var onOpenExceptions: (() -> Void)?

    @Published var autoSwitchHours: Int = 0
    @Published var typoFixHours: Int = 0
    @Published var shiftHours: Int = 0
    @Published var optionHours: Int = 0

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
    @Published var isTypoFixEnabled: Bool {
        didSet { prefsService.isTypoFixEnabled = isTypoFixEnabled }
    }

    init(statsService: StatisticsService, prefsService: PreferencesService) {
        self.statsService = statsService
        self.prefsService = prefsService

        self.isAutoSwitchEnabled = prefsService.isAutoSwitchEnabled
        self.isSplitShiftEnabled = prefsService.isSplitShiftEnabled
        self.isPasteNoFormatEnabled = prefsService.isPasteNoFormatEnabled
        self.isYoficatorEnabled = prefsService.isYoficatorEnabled
        self.isSoundEnabled = prefsService.isSoundEnabled
        self.isSingleShiftEnabled = prefsService.isSingleShiftEnabled
        self.isDoubleShiftEnabled = prefsService.isDoubleShiftEnabled
        self.isTypoFixEnabled = prefsService.isTypoFixEnabled

        refreshStats()

        NotificationCenter.default.addObserver(
            self, selector: #selector(onStatsUpdated),
            name: .statsUpdated, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func onStatsUpdated() {
        DispatchQueue.main.async {
            self.refreshStats()
        }
    }

    func resetStats() {
        statsService.resetAll()
        refreshStats()
    }

    func refreshStats() {
        autoSwitchHours = statsService.autoSwitchHours
        typoFixHours = statsService.typoFixHours
        shiftHours = statsService.shiftHours
        optionHours = statsService.optionHours
    }
}
