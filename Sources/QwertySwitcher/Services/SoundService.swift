import Foundation
import AppKit

final class SoundService {
    static let shared = SoundService()

    /// Global preference reference set by AppDelegate so UI code can check silently.
    static weak var prefs: PreferencesService?

    /// Curated system alert sounds (`/System/Library/Sounds/*.aiff`), offered
    /// as picker choices in Settings. Loaded by name via `NSSound(named:)` —
    /// nothing is copied into the bundle, so there's no licensing question
    /// and no bundle weight (owner rejected two prior bundled sound sets —
    /// this hands the choice to him instead of guessing again).
    static let systemSoundNames = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    /// Sentinel stored in `PreferencesService.layoutSoundName` for "play
    /// nothing" — distinct from an unresolved/corrupted name, which falls
    /// back to `fallbackSoundName` instead of going silently unexplained.
    static let noSoundName = "None"

    private static let fallbackSoundName = "Pop"

    private let uiTickSound = NSSound(named: "Tink")

    private init() {}

    /// Resolves a stored preference name to the system sound name that
    /// should actually play. Pure and directly testable — no NSSound touched
    /// here, so it's cheap to exercise every branch in the test suite.
    /// `noSoundName` -> nil (explicit silence). Anything not in
    /// `systemSoundNames` (stale default, macOS renamed/removed an asset) ->
    /// `fallbackSoundName`, never a crash and never an unexplained silence.
    static func effectiveSoundName(for storedName: String) -> String? {
        guard storedName != noSoundName else { return nil }
        return systemSoundNames.contains(storedName) ? storedName : fallbackSoundName
    }

    /// Combines both sound gates (`isSoundEnabled` master switch,
    /// `isLayoutSoundEnabled`) with the name-resolution rule above in one
    /// pure, directly testable place. `nil` means "don't play anything".
    static func layoutCueName(isSoundEnabled: Bool, isLayoutSoundEnabled: Bool, storedName: String) -> String? {
        guard isSoundEnabled, isLayoutSoundEnabled else { return nil }
        return effectiveSoundName(for: storedName)
    }

    /// Auto-switch on/off toggle cue. Deliberately reuses whichever system
    /// sound the owner already picked for layout switching (`layoutSoundName`)
    /// instead of a separate, unrelated pair of alert sounds — the old
    /// "Basso" for OFF read as an actual macOS error beep, which is what
    /// prompted this fix. ON plays the chosen sound at full volume; OFF plays
    /// the SAME sound quieter, so "off" reads as a softer echo of "on" rather
    /// than a jarring alert. Pure name+volume resolver, gated only by the
    /// master `isSoundEnabled` switch (mirrors the previous `playToggle`
    /// gating — `isLayoutSoundEnabled` is specifically about the layout-
    /// switch cue, a separate toggle). `nil` means stay silent.
    static func toggleCue(enabled: Bool, isSoundEnabled: Bool, storedName: String) -> (name: String, volume: Float)? {
        guard isSoundEnabled, let name = effectiveSoundName(for: storedName) else { return nil }
        return (name, enabled ? 1.0 : 0.45)
    }

    /// Real layout switch (Single Shift, Double Shift, Undo). System sounds
    /// can't be pitched apart without resampling, so the one chosen cue
    /// plays for both directions — `targetLanguageCode` no longer selects a
    /// different file (that was only meaningful for the old bundled pair).
    func playSwitch(targetLanguageCode: String, prefsService: PreferencesService) {
        guard let name = Self.layoutCueName(
            isSoundEnabled: prefsService.isSoundEnabled,
            isLayoutSoundEnabled: prefsService.isLayoutSoundEnabled,
            storedName: prefsService.layoutSoundName
        ) else { return }
        NSSound(named: name)?.play()
    }

    /// Quieter cue for automatic correction (instant mid-word or boundary) —
    /// same chosen sound as the layout switch, lower volume so frequent
    /// triggers don't get grating.
    func playCorrection(prefsService: PreferencesService) {
        guard let name = Self.layoutCueName(
            isSoundEnabled: prefsService.isSoundEnabled,
            isLayoutSoundEnabled: prefsService.isLayoutSoundEnabled,
            storedName: prefsService.layoutSoundName
        ) else { return }
        let sound = NSSound(named: name)
        sound?.volume = 0.35
        sound?.play()
    }

    /// Auditions a sound immediately from Settings — bypasses the sound
    /// gates above on purpose, so the owner can hear a choice even while
    /// sounds are toggled off in preferences.
    func previewLayoutSound(named storedName: String) {
        guard let name = Self.effectiveSoundName(for: storedName) else { return }
        NSSound(named: name)?.play()
    }

    func playToggle(enabled: Bool, prefsService: PreferencesService) {
        guard let cue = Self.toggleCue(
            enabled: enabled, isSoundEnabled: prefsService.isSoundEnabled, storedName: prefsService.layoutSoundName
        ) else { return }
        // A fresh NSSound instance per play — `NSSound(named:)` returns a
        // shared object by name, so setting `.volume` on it would leak into
        // every other place that plays the same named sound (see class doc).
        let sound = NSSound(named: cue.name)
        sound?.volume = cue.volume
        sound?.play()
    }

    /// Subtle UI-interaction tick (button presses in Settings window).
    /// Silent when sound is disabled in preferences.
    func playUITick() {
        guard SoundService.prefs?.isSoundEnabled ?? true else { return }
        uiTickSound?.play()
    }
}
