import Foundation
import UserNotifications
import os

/// Handles desktop_notify commands: show, clear.
/// Shows native macOS notifications from AI agents.
struct NotificationHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "Notification")

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        switch request.action {
        case "show":
            return await showNotification(id: request.id, params: request.params ?? [:])
        case "clear":
            return clearNotifications(id: request.id)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown notify action: \(request.action)")
        }
    }

    // MARK: - Show Notification

    private func showNotification(id: String, params: [String: JSONValue]) async -> CommandResponse {
        guard let title = params["title"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "title is required")
        }
        let body = params["body"]?.stringValue ?? ""
        let subtitle = params["subtitle"]?.stringValue

        let center = UNUserNotificationCenter.current()

        // Request permission if needed
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do {
                try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                return .permissionMissing(id: id, permission: "Notifications")
            }
        }

        guard settings.authorizationStatus != .denied else {
            return .permissionMissing(id: id, permission: "Notifications")
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let subtitle { content.subtitle = subtitle }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "ava-\(id)",
            content: content,
            trigger: nil // Deliver immediately
        )

        do {
            try await center.add(request)
            logger.info("Notification shown: \(title)")
            return .success(id: id, payload: ["shown": .bool(true)])
        } catch {
            return .failure(id: id, code: "NOTIFY_FAILED", message: error.localizedDescription)
        }
    }

    // MARK: - Clear

    private func clearNotifications(id: String) -> CommandResponse {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        return .success(id: id, payload: ["cleared": .bool(true)])
    }
}
