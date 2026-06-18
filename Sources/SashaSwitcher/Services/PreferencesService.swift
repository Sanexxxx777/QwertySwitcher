import Foundation

final class PreferencesService {
    private let defaults = UserDefaults.standard
    private let keyPrefix = "tech.sasha.switcher."

    var isAutoSwitchEnabled: Bool {
        get { defaults.object(forKey: keyPrefix + "autoEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: keyPrefix + "autoEnabled") }
    }

    var isSoundEnabled: Bool {
        get { defaults.object(forKey: keyPrefix + "soundEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: keyPrefix + "soundEnabled") }
    }

    var isYoficatorEnabled: Bool {
        get { defaults.object(forKey: keyPrefix + "yoficator") as? Bool ?? false }
        set { defaults.set(newValue, forKey: keyPrefix + "yoficator") }
    }

    var isSplitShiftEnabled: Bool {
        get { defaults.object(forKey: keyPrefix + "splitShift") as? Bool ?? true }
        set { defaults.set(newValue, forKey: keyPrefix + "splitShift") }
    }

    var isPasteNoFormatEnabled: Bool {
        get { defaults.object(forKey: keyPrefix + "pasteNoFormat") as? Bool ?? true }
        set { defaults.set(newValue, forKey: keyPrefix + "pasteNoFormat") }
    }

    /// Single Shift → switch layout (and CapsLock as alt trigger)
    var isSingleShiftEnabled: Bool {
        get { defaults.object(forKey: keyPrefix + "singleShift") as? Bool ?? true }
        set { defaults.set(newValue, forKey: keyPrefix + "singleShift") }
    }

    /// Double Shift / Option — convert last word or selection
    var isDoubleShiftEnabled: Bool {
        get { defaults.object(forKey: keyPrefix + "doubleShift") as? Bool ?? true }
        set { defaults.set(newValue, forKey: keyPrefix + "doubleShift") }
    }

    /// Typo correction (reserved toggle — currently bundled with autoSwitch)
    var isTypoFixEnabled: Bool {
        get { defaults.object(forKey: keyPrefix + "typoFix") as? Bool ?? true }
        set { defaults.set(newValue, forKey: keyPrefix + "typoFix") }
    }
}
