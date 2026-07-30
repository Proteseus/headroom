import Foundation
import ServiceManagement

/// Menu-bar Open at Login, via `SMAppService.mainApp`.
///
/// No helper app and no entitlement: the main binary registers itself. Status
/// can sit at `.requiresApproval` until the user confirms in System Settings →
/// Login Items — register still succeeds, so the toggle must read status, not
/// whether we called `register()`.
enum LaunchAtLogin {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    /// On when registered or waiting on Login Items approval — both mean the
    /// user asked for Open at Login; only `.enabled` is actually launching.
    static var isRequested: Bool {
        switch status {
        case .enabled, .requiresApproval: return true
        case .notRegistered, .notFound: return false
        @unknown default: return false
        }
    }

    static var needsApproval: Bool {
        status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
