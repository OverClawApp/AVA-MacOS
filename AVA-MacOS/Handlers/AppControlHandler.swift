import Foundation
import AppKit
import os

/// Handles desktop_app commands: open, list, activate, quit.
struct AppControlHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "AppControl")

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        let params = request.params ?? [:]

        switch request.action {
        case "open":
            return try await openApp(id: request.id, params: params)
        case "list":
            return listRunningApps(id: request.id)
        case "activate":
            return activateApp(id: request.id, params: params)
        case "quit":
            return quitApp(id: request.id, params: params)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown app action: \(request.action)")
        }
    }

    // MARK: - Actions

    private func openApp(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard let name = params["name"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "name is required")
        }

        // Try opening by bundle identifier first
        if let bundleId = params["bundleId"]?.stringValue {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
                return .failure(id: id, code: "NOT_FOUND", message: "App not found: \(bundleId)")
            }
            try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
            return .success(id: id, payload: ["opened": .string(bundleId)])
        }

        // Find by name
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "")
        let searchPaths = [
            "/Applications/\(name).app",
            "/System/Applications/\(name).app",
            "/Applications/Utilities/\(name).app",
            NSString(string: "~/Applications/\(name).app").expandingTildeInPath,
        ]

        for path in searchPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
                logger.info("Opened app: \(name)")
                return .success(id: id, payload: ["opened": .string(name), "path": .string(path)])
            }
        }

        // Fallback: use open command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", name]
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            return .success(id: id, payload: ["opened": .string(name)])
        }

        return .failure(id: id, code: "NOT_FOUND", message: "Could not open app: \(name)")
    }

    private func listRunningApps(id: String) -> CommandResponse {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> JSONValue? in
                guard let name = app.localizedName else { return nil }
                return .object([
                    "name": .string(name),
                    "bundleId": .string(app.bundleIdentifier ?? ""),
                    "pid": .int(Int(app.processIdentifier)),
                    "isActive": .bool(app.isActive),
                    "isHidden": .bool(app.isHidden),
                ])
            }

        return .success(id: id, payload: [
            "apps": .array(apps),
            "count": .int(apps.count),
        ])
    }

    private func activateApp(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let name = params["name"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "name is required")
        }

        let app = NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.localizedCaseInsensitiveContains(name) == true
        }

        guard let app else {
            return .failure(id: id, code: "NOT_FOUND", message: "App not running: \(name)")
        }

        app.activate()
        return .success(id: id, payload: ["activated": .string(app.localizedName ?? name)])
    }

    private func quitApp(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let name = params["name"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "name is required")
        }

        let app = NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.localizedCaseInsensitiveContains(name) == true
        }

        guard let app else {
            return .failure(id: id, code: "NOT_FOUND", message: "App not running: \(name)")
        }

        let force = params["force"]?.boolValue ?? false
        let result = force ? app.forceTerminate() : app.terminate()

        if result {
            return .success(id: id, payload: ["quit": .string(app.localizedName ?? name)])
        }
        return .failure(id: id, code: "QUIT_FAILED", message: "Could not quit: \(name)")
    }
}
