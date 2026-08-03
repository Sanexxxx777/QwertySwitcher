import Foundation

final class StatisticsService {
    private let defaults = UserDefaults.standard
    private let keyPrefix = AppIdentity.keyPrefix + "stats."

    // Track time when feature was first enabled (for "hours" display like Caramba)
    var firstLaunchDate: Date {
        get {
            if let d = defaults.object(forKey: keyPrefix + "firstLaunch") as? Date { return d }
            let now = Date()
            defaults.set(now, forKey: keyPrefix + "firstLaunch")
            return now
        }
    }

    var autoSwitchCount: Int {
        get { defaults.integer(forKey: keyPrefix + "autoSwitch") }
        set { defaults.set(newValue, forKey: keyPrefix + "autoSwitch") }
    }

    var typoFixCount: Int {
        get { defaults.integer(forKey: keyPrefix + "typoFix") }
        set { defaults.set(newValue, forKey: keyPrefix + "typoFix") }
    }

    var shiftSwitchCount: Int {
        get { defaults.integer(forKey: keyPrefix + "shiftSwitch") }
        set { defaults.set(newValue, forKey: keyPrefix + "shiftSwitch") }
    }

    var optionSwitchCount: Int {
        get { defaults.integer(forKey: keyPrefix + "optionSwitch") }
        set { defaults.set(newValue, forKey: keyPrefix + "optionSwitch") }
    }

    // Time saved per event (in seconds). Calibrated by action cost:
    // auto-correction saves typing the word twice + switching layout.
    private let secondsPerAutoSwitch: Double = 4.0
    private let secondsPerTypoFix: Double = 2.0
    private let secondsPerShiftSwitch: Double = 1.0
    private let secondsPerOptionSwitch: Double = 4.0

    // Derived: estimated time saved (shown in "час." cards, like Caramba)
    var autoSwitchHours: Int {
        max(0, Int(Double(autoSwitchCount) * secondsPerAutoSwitch / 3600))
    }
    var typoFixHours: Int {
        max(0, Int(Double(typoFixCount) * secondsPerTypoFix / 3600))
    }
    var shiftHours: Int {
        max(0, Int(Double(shiftSwitchCount) * secondsPerShiftSwitch / 3600))
    }
    var optionHours: Int {
        max(0, Int(Double(optionSwitchCount) * secondsPerOptionSwitch / 3600))
    }

    func recordAutoSwitch() { autoSwitchCount += 1 }
    func recordTypoFix() { typoFixCount += 1 }
    func recordShiftSwitch() { shiftSwitchCount += 1 }
    func recordOptionSwitch() { optionSwitchCount += 1 }

    func save() {
        defaults.synchronize()
    }

    /// Reset all counters (for "Сбросить статистику" action)
    func resetAll() {
        autoSwitchCount = 0
        typoFixCount = 0
        shiftSwitchCount = 0
        optionSwitchCount = 0
        defaults.removeObject(forKey: keyPrefix + "firstLaunch")
        save()
    }
}
