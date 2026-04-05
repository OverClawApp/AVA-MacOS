import Foundation
import AppKit
import os

/// Handles desktop_clipboard commands: get, set.
struct ClipboardHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "Clipboard")

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        let params = request.params ?? [:]

        switch request.action {
        case "get":
            return getClipboard(id: request.id)
        case "set":
            return setClipboard(id: request.id, params: params)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown clipboard action: \(request.action)")
        }
    }

    // MARK: - Actions

    private func getClipboard(id: String) -> CommandResponse {
        let pasteboard = NSPasteboard.general

        // Try text first
        if let text = pasteboard.string(forType: .string) {
            return .success(id: id, payload: [
                "content": .string(text),
                "type": .string("text"),
            ])
        }

        // Try image
        if let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            let base64 = imageData.base64EncodedString()
            return .success(id: id, payload: [
                "content": .string(base64),
                "type": .string("image"),
                "encoding": .string("base64"),
            ])
        }

        // Try file URLs
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let paths = urls.map { JSONValue.string($0.path) }
            return .success(id: id, payload: [
                "content": .array(paths),
                "type": .string("files"),
            ])
        }

        return .success(id: id, payload: [
            "content": .null,
            "type": .string("empty"),
        ])
    }

    private func setClipboard(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let content = params["content"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "content is required")
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let contentType = params["type"]?.stringValue ?? "text"

        switch contentType {
        case "text":
            pasteboard.setString(content, forType: .string)
        case "html":
            pasteboard.setString(content, forType: .html)
        default:
            pasteboard.setString(content, forType: .string)
        }

        logger.info("Clipboard set (\(contentType), \(content.count) chars)")
        return .success(id: id, payload: ["set": .bool(true)])
    }
}
