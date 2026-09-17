import Foundation
import ServiceManagement

/// Launch-at-login, via the modern service API.
///
/// This only works for a real `.app` bundle; when the binary is run straight
/// out of `.build/` registration fails and we stay quiet about it rather than
/// showing an error the user cannot act on.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the resulting state, so callers can reflect reality rather than
    /// the switch position they hoped for.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            return isEnabled
        }
        return isEnabled
    }
}
