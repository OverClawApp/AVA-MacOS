import Foundation
import AppKit

// MARK: - Path-Based Element Targeting

extension AccessibilityHandler {

    /// Build an accessibility path string for an element: "AXWindow>AXGroup>AXButton[Save]"
    func buildPath(element: AXUIElement, segments: [String] = []) -> String {
        let role = getStringAttribute(element, kAXRoleAttribute) ?? "unknown"
        let title = getStringAttribute(element, kAXTitleAttribute) ?? ""
        let segment = title.isEmpty ? role : "\(role)[\(title)]"
        // We build paths top-down during tree walks, not bottom-up, so this is mainly
        // a utility for standalone element path computation via AX parent chain.
        var allSegments = [segment]

        var parentRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
           let parent = parentRef {
            let parentElement = parent as! AXUIElement
            let parentPath = buildPath(element: parentElement)
            if !parentPath.isEmpty {
                return "\(parentPath)>\(segment)"
            }
        }

        return allSegments.joined(separator: ">")
    }

    // MARK: - Find by Path

    /// Walk the AX tree following path segments to locate an exact element.
    /// Path format: "AXWindow[MyApp]>AXGroup>AXButton[Save]"
    func findByPath(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let path = params["path"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "path is required")
        }

        guard let appElement = resolveAppElement(params: params) else {
            return .failure(id: id, code: "NO_APP", message: "App not found")
        }

        guard let element = resolveElementByPath(path, root: appElement) else {
            return .failure(id: id, code: "NOT_FOUND", message: "No element at path: \(path)")
        }

        // Return full info about the found element
        let role = getStringAttribute(element, kAXRoleAttribute) ?? ""
        let title = getStringAttribute(element, kAXTitleAttribute) ?? ""
        var info: [String: JSONValue] = [
            "role": .string(role),
            "title": .string(title),
            "path": .string(path),
            "actions": .array(getActionNames(element).map { .string($0) }),
        ]
        if let pos = getPointAttribute(element, kAXPositionAttribute),
           let size = getSizeAttribute(element, kAXSizeAttribute) {
            info["x"] = .int(Int(pos.x))
            info["y"] = .int(Int(pos.y))
            info["width"] = .int(Int(size.width))
            info["height"] = .int(Int(size.height))
        }
        if let value = getStringAttribute(element, kAXValueAttribute), !value.isEmpty {
            info["value"] = .string(String(value.prefix(200)))
        }

        return .success(id: id, payload: info)
    }

    // MARK: - Click by Path

    func clickByPath(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let path = params["path"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "path is required")
        }

        guard let appElement = resolveAppElement(params: params) else {
            return .failure(id: id, code: "NO_APP", message: "App not found")
        }

        guard let element = resolveElementByPath(path, root: appElement) else {
            return .failure(id: id, code: "NOT_FOUND", message: "No element at path: \(path)")
        }

        let role = getStringAttribute(element, kAXRoleAttribute) ?? ""
        let title = getStringAttribute(element, kAXTitleAttribute) ?? ""

        // Fallback 1: AXPress
        let pressResult = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if pressResult == .success {
            return .success(id: id, payload: [
                "clicked": .bool(true), "path": .string(path),
                "role": .string(role), "title": .string(title),
                "method": .string("AXPress"),
            ])
        }

        // Fallback 2: CGEvent mouse click
        if let pos = getPointAttribute(element, kAXPositionAttribute),
           let size = getSizeAttribute(element, kAXSizeAttribute) {
            let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
            if performMouseClick(at: center) {
                return .success(id: id, payload: [
                    "clicked": .bool(true), "path": .string(path),
                    "role": .string(role), "title": .string(title),
                    "method": .string("mouseClick"),
                ])
            }
        }

        // Fallback 3: AppleScript
        if let appName = NSWorkspace.shared.frontmostApplication?.localizedName, !title.isEmpty {
            let script = "tell application \"\(appName)\" to click button \"\(title)\" of front window"
            let (success, _) = runAppleScript(script)
            if success {
                return .success(id: id, payload: [
                    "clicked": .bool(true), "path": .string(path),
                    "role": .string(role), "title": .string(title),
                    "method": .string("appleScript"),
                ])
            }
        }

        return .failure(id: id, code: "CLICK_FAILED", message: "All click methods failed for path: \(path)")
    }

    // MARK: - Type by Path

    func typeByPath(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let path = params["path"]?.stringValue,
              let text = params["text"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "path and text are required")
        }

        guard let appElement = resolveAppElement(params: params) else {
            return .failure(id: id, code: "NO_APP", message: "App not found")
        }

        guard let element = resolveElementByPath(path, root: appElement) else {
            return .failure(id: id, code: "NOT_FOUND", message: "No element at path: \(path)")
        }

        let role = getStringAttribute(element, kAXRoleAttribute) ?? ""
        let title = getStringAttribute(element, kAXTitleAttribute) ?? ""

        // Fallback 1: AXSetValue
        let setResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
        if setResult == .success {
            return .success(id: id, payload: [
                "typed": .bool(true), "path": .string(path), "text": .string(text),
                "role": .string(role), "title": .string(title),
                "method": .string("AXSetValue"),
            ])
        }

        // Fallback 2: Focus + keyboard
        AXUIElementPerformAction(element, "AXFocus" as CFString)
        typeViaKeyboard(text)

        // Fallback 3: AppleScript
        if let appName = NSWorkspace.shared.frontmostApplication?.localizedName, !title.isEmpty {
            let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
            let script = "tell application \"\(appName)\" to set value of text field \"\(title)\" of front window to \"\(escaped)\""
            let (success, _) = runAppleScript(script)
            if success {
                return .success(id: id, payload: [
                    "typed": .bool(true), "path": .string(path), "text": .string(text),
                    "role": .string(role), "title": .string(title),
                    "method": .string("appleScript"),
                ])
            }
        }

        return .success(id: id, payload: [
            "typed": .bool(true), "path": .string(path), "text": .string(text),
            "role": .string(role), "title": .string(title),
            "method": .string("keyboard"),
        ])
    }

    // MARK: - Path Resolution Helper

    /// Parse a path like "AXWindow[MyApp]>AXGroup>AXButton[Save]" and walk the AX tree to find the element.
    private func resolveElementByPath(_ path: String, root: AXUIElement) -> AXUIElement? {
        let segments = path.components(separatedBy: ">")
        guard !segments.isEmpty else { return nil }

        var current: AXUIElement = root

        for segment in segments {
            let (targetRole, targetTitle) = parsePathSegment(segment)

            // Search among children of current element
            guard let match = findChildMatching(role: targetRole, title: targetTitle, in: current) else {
                return nil
            }
            current = match
        }

        return current
    }

    /// Parse "AXButton[Save]" into ("AXButton", "Save") or "AXGroup" into ("AXGroup", nil).
    private func parsePathSegment(_ segment: String) -> (role: String, title: String?) {
        let trimmed = segment.trimmingCharacters(in: .whitespaces)
        if let bracketStart = trimmed.firstIndex(of: "["),
           let bracketEnd = trimmed.lastIndex(of: "]") {
            let role = String(trimmed[..<bracketStart])
            let title = String(trimmed[trimmed.index(after: bracketStart)..<bracketEnd])
            return (role, title.isEmpty ? nil : title)
        }
        return (trimmed, nil)
    }

    /// Find a direct or nested child matching role (and optionally title).
    private func findChildMatching(role: String, title: String?, in element: AXUIElement) -> AXUIElement? {
        // Check if current element matches (for root case)
        let currentRole = getStringAttribute(element, kAXRoleAttribute) ?? ""
        let currentTitle = getStringAttribute(element, kAXTitleAttribute) ?? ""
        if currentRole == role && (title == nil || currentTitle == title) {
            return element
        }

        // BFS through children
        let children = getChildren(element)
        for child in children {
            let childRole = getStringAttribute(child, kAXRoleAttribute) ?? ""
            let childTitle = getStringAttribute(child, kAXTitleAttribute) ?? ""
            if childRole == role && (title == nil || childTitle == title) {
                return child
            }
        }

        // If not found in direct children, recurse one level deeper
        for child in children {
            if let found = findChildMatching(role: role, title: title, in: child) {
                return found
            }
        }

        return nil
    }
}
