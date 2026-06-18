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
                if isEnabled {
                    try SMAppService.mainApp.unregister()
                    NSLog("[AutoStart] Disabled")
                } else {
                    try SMAppService.mainApp.register()
                    NSLog("[AutoStart] Enabled")
                }
            } catch {
                NSLog("[AutoStart] Error: \(error)")
            }
        }
    }
}
