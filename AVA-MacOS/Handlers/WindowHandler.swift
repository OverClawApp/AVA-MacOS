import Foundation
import AppKit
import os

/// Handles desktop_window commands — move, resize, minimize, fullscreen, close windows.
/// Uses Accessibility API for window manipulation.
struct WindowHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "Window")

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
            return .permissionMissing(id: request.id, permission: "Accessibility")
        }

        let params = request.params ?? [:]

        switch request.action {
        case "move":
            return moveWindow(id: request.id, params: params)
        case "resize":
            return resizeWindow(id: request.id, params: params)
        case "minimize":
            return performWindowAction(id: request.id, params: params, action: "AXMinimized", value: true)
        case "fullscreen":
            return pressFullscreen(id: request.id, params: params)
        case "close":
            return closeWindow(id: request.id, params: params)
        case "raise":
            return raiseWindow(id: request.id, params: params)
        case "arrange":
            return arrangeWindows(id: request.id, params: params)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown window action: \(request.action)")
        }
    }

    // MARK: - Move

    private func moveWindow(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let x = params["x"]?.intValue, let y = params["y"]?.intValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "x and y are required")
        }

        guard let window = findWindow(params: params) else {
            return .failure(id: id, code: "NOT_FOUND", message: "Window not found")
        }

        var point = CGPoint(x: x, y: y)
        let value = AXValueCreate(.cgPoint, &point)!
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)

        return .success(id: id, payload: ["moved": .object(["x": .int(x), "y": .int(y)])])
    }

    // MARK: - Resize

    private func resizeWindow(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let width = params["width"]?.intValue, let height = params["height"]?.intValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "width and height are required")
        }

        guard let window = findWindow(params: params) else {
            return .failure(id: id, code: "NOT_FOUND", message: "Window not found")
        }

        var size = CGSize(width: width, height: height)
        let value = AXValueCreate(.cgSize, &size)!
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)

        return .success(id: id, payload: ["resized": .object(["width": .int(width), "height": .int(height)])])
    }

    // MARK: - Minimize / Fullscreen

    private func performWindowAction(id: String, params: [String: JSONValue], action: String, value: Bool) -> CommandResponse {
        guard let window = findWindow(params: params) else {
            return .failure(id: id, code: "NOT_FOUND", message: "Window not found")
        }

        AXUIElementSetAttributeValue(window, action as CFString, value as CFTypeRef)
        return .success(id: id, payload: ["done": .bool(true)])
    }

    private func pressFullscreen(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let window = findWindow(params: params) else {
            return .failure(id: id, code: "NOT_FOUND", message: "Window not found")
        }

        let result = AXUIElementPerformAction(window, "AXZoomWindow" as CFString)
        if result == .success {
            return .success(id: id, payload: ["fullscreen": .bool(true)])
        }

        // Fallback: press the green button
        var buttonRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreenButton" as CFString, &buttonRef) == .success {
            AXUIElementPerformAction(buttonRef as! AXUIElement, kAXPressAction as CFString)
            return .success(id: id, payload: ["fullscreen": .bool(true)])
        }

        return .failure(id: id, code: "FAILED", message: "Could not toggle fullscreen")
    }

    // MARK: - Close

    private func closeWindow(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let window = findWindow(params: params) else {
            return .failure(id: id, code: "NOT_FOUND", message: "Window not found")
        }

        // Find and press the close button
        var buttonRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXCloseButton" as CFString, &buttonRef) == .success {
            AXUIElementPerformAction(buttonRef as! AXUIElement, kAXPressAction as CFString)
            return .success(id: id, payload: ["closed": .bool(true)])
        }

        return .failure(id: id, code: "FAILED", message: "Could not close window")
    }

    // MARK: - Raise

    private func raiseWindow(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let window = findWindow(params: params) else {
            return .failure(id: id, code: "NOT_FOUND", message: "Window not found")
        }

        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        return .success(id: id, payload: ["raised": .bool(true)])
    }

    // MARK: - Arrange (tile left/right/center)

    private func arrangeWindows(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let layout = params["layout"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "layout is required (left_half, right_half, center, maximize)")
        }

        guard let window = findWindow(params: params) else {
            return .failure(id: id, code: "NOT_FOUND", message: "Window not found")
        }

        guard let screen = NSScreen.main else {
            return .failure(id: id, code: "NO_SCREEN", message: "No main screen")
        }

        let frame = screen.visibleFrame

        var point: CGPoint
        var size: CGSize

        switch layout {
        case "left_half":
            point = CGPoint(x: frame.origin.x, y: 0)
            size = CGSize(width: frame.width / 2, height: frame.height)
        case "right_half":
            point = CGPoint(x: frame.origin.x + frame.width / 2, y: 0)
            size = CGSize(width: frame.width / 2, height: frame.height)
        case "top_half":
            point = CGPoint(x: frame.origin.x, y: 0)
            size = CGSize(width: frame.width, height: frame.height / 2)
        case "bottom_half":
            point = CGPoint(x: frame.origin.x, y: frame.height / 2)
            size = CGSize(width: frame.width, height: frame.height / 2)
        case "center":
            let w = frame.width * 0.6
            let h = frame.height * 0.7
            point = CGPoint(x: frame.origin.x + (frame.width - w) / 2, y: (frame.height - h) / 2)
            size = CGSize(width: w, height: h)
        case "maximize":
            point = CGPoint(x: frame.origin.x, y: 0)
            size = CGSize(width: frame.width, height: frame.height)
        default:
            return .failure(id: id, code: "INVALID_LAYOUT", message: "Unknown layout: \(layout)")
        }

        let posValue = AXValueCreate(.cgPoint, &point)!
        let sizeValue = AXValueCreate(.cgSize, &size)!
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)

        return .success(id: id, payload: ["arranged": .string(layout)])
    }

    // MARK: - Find Window Helper

    private func findWindow(params: [String: JSONValue]) -> AXUIElement? {
        let appElement: AXUIElement
        if let appName = params["app"]?.stringValue {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
            }) else { return nil }
            app.activate()
            appElement = AXUIElementCreateApplication(app.processIdentifier)
        } else {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            appElement = AXUIElementCreateApplication(app.processIdentifier)
        }

        // Get windows
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let window = windows.first else { return nil }

        return window
    }
}
