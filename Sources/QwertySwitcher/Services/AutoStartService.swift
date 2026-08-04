import Foundation
import ServiceManagement

final class AutoStartService {
    var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
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
