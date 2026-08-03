import Foundation

final class PreferencesService {
    private let defaults = UserDefaults.standard
    private let keyPrefix = AppIdentity.keyPrefix

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

    /// Double Shift — convert the current or last completed buffered word
    var isDoubleShiftEnabled: Bool {
        get { defaults.object(forKey: keyPrefix + "doubleShift") as? Bool ?? true }
        set { defaults.set(newValue, forKey: keyPrefix + "doubleShift") }
    }

    /// Caps Lock is deliberately independent from Single Shift.
    var isCapsLockSwitchEnabled: Bool {
        get { defaults.object(forKey: keyPrefix + "capsLockSwitch") as? Bool ?? false }
        set { defaults.set(newValue, forKey: keyPrefix + "capsLockSwitch") }
    }

    /// Exactly two supported layouts take part in detection and manual switching.
    var activeLayoutIDs: [String] {
        get { defaults.stringArray(forKey: keyPrefix + "activeLayoutIDs") ?? [] }
        set { defaults.set(Array(newValue.prefix(2)), forKey: keyPrefix + "activeLayoutIDs") }
    }

}
