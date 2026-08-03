import Foundation
import ServiceManagement

final class AutoStartService {
    var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    func toggle() {
        if #available(macOS 13.0, *) {
            do {
                try setEnabled(!isEnabled)
            } catch {
                NSLog("[AutoStart] Error: \(error)")
            }
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *), enabled != isEnabled else { return }
        if enabled {
            try SMAppService.mainApp.register()
            NSLog("[AutoStart] Enabled")
        } else {
            try SMAppService.mainApp.unregister()
            NSLog("[AutoStart] Disabled")
        }
    }
}
