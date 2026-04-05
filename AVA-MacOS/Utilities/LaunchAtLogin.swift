import Foundation
import ServiceManagement
import os

/// Auto-launch on login using SMAppService (macOS 13+).
enum LaunchAtLogin {
    private static let logger = Logger(subsystem: Constants.bundleID, category: "LaunchAtLogin")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                logger.info("Registered for launch at login")
            } else {
                try SMAppService.mainApp.unregister()
                logger.info("Unregistered from launch at login")
            }
        } catch {
            logger.error("Failed to \(enabled ? "enable" : "disable") launch at login: \(error)")
        }
    }
}
