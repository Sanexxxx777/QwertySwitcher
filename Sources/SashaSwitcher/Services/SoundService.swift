import Foundation
import AppKit

final class SoundService {
    static let shared = SoundService()

    /// Global preference reference set by AppDelegate so UI code can check silently.
    static weak var prefs: PreferencesService?

    private let switchSound: NSSound?
    private let toggleOnSound: NSSound?
    private let toggleOffSound: NSSound?
    private let uiTickSound: NSSound?

    private init() {
        switchSound = NSSound(named: "Tink")
        toggleOnSound = NSSound(named: "Pop")
        toggleOffSound = NSSound(named: "Basso")
        uiTickSound = NSSound(named: "Tink")
    }

    func playSwitch(prefsService: PreferencesService) {
        guard prefsService.isSoundEnabled else { return }
        switchSound?.play()
    }

    func playToggle(enabled: Bool, prefsService: PreferencesService) {
        guard prefsService.isSoundEnabled else { return }
        (enabled ? toggleOnSound : toggleOffSound)?.play()
    }

    /// Subtle UI-interaction tick (button presses in Settings window).
    /// Silent when sound is disabled in preferences.
    func playUITick() {
        guard SoundService.prefs?.isSoundEnabled ?? true else { return }
        uiTickSound?.play()
    }
}
