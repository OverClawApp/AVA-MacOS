import Foundation
import AppKit
import os

/// Handles desktop_url commands — open URLs in browsers, handle URL schemes.
struct URLHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "URL")

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        let params = request.params ?? [:]

        switch request.action {
        case "open":
            return openURL(id: request.id, params: params)
        case "open_with":
            return openURLWithApp(id: request.id, params: params)
        case "default_browser":
            return getDefaultBrowser(id: request.id)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown url action: \(request.action)")
        }
    }

    private func openURL(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let urlString = params["url"]?.stringValue,
              let url = URL(string: urlString) else {
            return .failure(id: id, code: "MISSING_PARAM", message: "valid url is required")
        }

        NSWorkspace.shared.open(url)
        return .success(id: id, payload: ["opened": .string(urlString)])
    }

    private func openURLWithApp(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let urlString = params["url"]?.stringValue,
              let url = URL(string: urlString) else {
            return .failure(id: id, code: "MISSING_PARAM", message: "url is required")
        }
        guard let appName = params["app"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "app is required")
        }

        let config = NSWorkspace.OpenConfiguration()
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appName) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
        } else {
            // Try by name
            let searchPaths = ["/Applications/\(appName).app", "/System/Applications/\(appName).app"]
            for path in searchPaths {
                if FileManager.default.fileExists(atPath: path) {
                    NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: path), configuration: config)
                    return .success(id: id, payload: ["opened": .string(urlString), "app": .string(appName)])
                }
            }
            // Fallback
            NSWorkspace.shared.open(url)
        }

        return .success(id: id, payload: ["opened": .string(urlString), "app": .string(appName)])
    }

    private func getDefaultBrowser(id: String) -> CommandResponse {
        let defaultBrowser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        let name = defaultBrowser?.deletingPathExtension().lastPathComponent ?? "Unknown"

        return .success(id: id, payload: [
            "browser": .string(name),
            "path": .string(defaultBrowser?.path ?? ""),
        ])
    }
}
