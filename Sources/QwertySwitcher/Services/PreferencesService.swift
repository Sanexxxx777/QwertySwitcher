import Foundation

final class PreferencesService {
    private let defaults: UserDefaults
    private let keyPrefix = AppIdentity.keyPrefix

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isAutoSwitchEnabled: Bool {
        get { defaults.object(forKey: keyPrefix + "autoEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: keyPrefix + "autoEnabled") }
    }

    var isSoundEnabled: Bool {
        get { defaults.object(forKey: keyPrefix + "soundEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: keyPrefix + "soundEnabled") }
    }

    /// Separate from `isSoundEnabled`, which stays the master gate (off → silent
    /// everywhere). This one only toggles the layout-switch/auto-correction cue.
    var isLayoutSoundEnabled: Bool {
        get { defaults.object(forKey: keyPrefix + "layoutSoundEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: keyPrefix + "layoutSoundEnabled") }
    }

    /// Which system sound (see `SoundService.systemSoundNames`, or
    /// `SoundService.noSoundName` for "Без звука") plays on layout switch and
    /// auto-correction. Default "Pop" — short and neutral, doesn't read as an
    /// error/alert the way Basso/Sosumi do, and isn't a notification chime
    /// like Glass/Hero — picked so a first-run user isn't startled either way.
    var layoutSoundName: String {
        get { defaults.string(forKey: keyPrefix + "layoutSoundName") ?? "Pop" }
        set { defaults.set(newValue, forKey: keyPrefix + "layoutSoundName") }
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

    /// Correct a confidently-mistyped word mid-word (before space/punctuation),
    /// like Caramba Switcher. When off, only the boundary path corrects words.
    var isInstantCorrectionEnabled: Bool {
        get { defaults.object(forKey: keyPrefix + "instantCorrection") as? Bool ?? true }
        set { defaults.set(newValue, forKey: keyPrefix + "instantCorrection") }
    }

    /// Expands user-authored short triggers into local text snippets when a
    /// word boundary is typed. The snippet content never leaves the Mac.
    var isSnippetExpansionEnabled: Bool {
        get { defaults.object(forKey: keyPrefix + "snippetExpansion") as? Bool ?? true }
        set { defaults.set(newValue, forKey: keyPrefix + "snippetExpansion") }
    }

    /// Normalizes an accidentally held Shift in the first two letters and
    /// capitalizes the next plain word after `.?!`. Off by default.
    var isSmartCaseEnabled: Bool {
        get { defaults.object(forKey: keyPrefix + "smartCase") as? Bool ?? false }
        set { defaults.set(newValue, forKey: keyPrefix + "smartCase") }
    }

    /// Adds per-word telemetry (`detect: noSwitch`, `word too short`) to the
    /// debug log — off by default, since it made up 72% of a real user's log
    /// and drowned out the events worth reading. Key shared with `DebugLog`.
    var isVerboseLogEnabled: Bool {
        get { defaults.object(forKey: keyPrefix + "verboseLog") as? Bool ?? false }
        set { defaults.set(newValue, forKey: keyPrefix + "verboseLog") }
    }

    /// Exactly two supported layouts take part in detection and manual switching.
    var activeLayoutIDs: [String] {
        get { defaults.stringArray(forKey: keyPrefix + "activeLayoutIDs") ?? [] }
        set { defaults.set(Array(newValue.prefix(2)), forKey: keyPrefix + "activeLayoutIDs") }
    }

    /// Mechanism A/B/C (learning_spec.md — обучение на паттернах поведения):
    /// gates recording AND application in all three learning modules
    /// (`LearnedWordsStore`, `PersonalFrequencyStore`,
    /// `CorrectionFeedbackTracker`). Default true, same "on unless it gets
    /// in the way" posture as `isAutoSwitchEnabled`.
    var isLearningEnabled: Bool {
        get { defaults.object(forKey: keyPrefix + "learningEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: keyPrefix + "learningEnabled") }
    }

    /// Light / Dark / System — default follows the OS.
    var themePreference: ThemePreference {
        get { ThemePreference(rawValue: defaults.string(forKey: keyPrefix + "themePreference") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: keyPrefix + "themePreference") }
    }

}
