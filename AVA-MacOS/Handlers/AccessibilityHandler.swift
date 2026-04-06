import Foundation
import AppKit
import os

/// Handles desktop_accessibility commands — read UI element trees, find elements, interact with any app.
/// Uses macOS Accessibility API (AXUIElement) for precise computer use.
/// Requires Accessibility TCC permission.
struct AccessibilityHandler {
    let logger = Logger(subsystem: Constants.bundleID, category: "Accessibility")

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
            return .permissionMissing(id: request.id, permission: "Accessibility")
        }

        let params = request.params ?? [:]

        switch request.action {
        case "tree":
            return getUITree(id: request.id, params: params)
        case "find":
            return findElement(id: request.id, params: params)
        case "click":
            return clickElement(id: request.id, params: params)
        case "type":
            return typeIntoElement(id: request.id, params: params)
        case "read":
            return readElement(id: request.id, params: params)
        case "get_focused":
            return getFocusedElement(id: request.id)
        case "list_actions":
            return listActions(id: request.id, params: params)
        case "perform_action":
            return performAction(id: request.id, params: params)
        // Indexed element actions (see AccessibilityHandler+Indexed.swift)
        case "indexed_tree":
            return getIndexedTree(id: request.id, params: params)
        case "click_index":
            return clickByIndex(id: request.id, params: params)
        case "type_index":
            return typeByIndex(id: request.id, params: params)
        case "clear_cache":
            return clearElementCache(id: request.id)
        // Path-based actions (see AccessibilityHandler+Paths.swift)
        case "find_by_path":
            return findByPath(id: request.id, params: params)
        case "click_path":
            return clickByPath(id: request.id, params: params)
        case "type_path":
            return typeByPath(id: request.id, params: params)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown accessibility action: \(request.action)")
        }
    }

    // MARK: - UI Tree

    private func getUITree(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let appElement = resolveAppElement(params: params) else {
            return .failure(id: id, code: "NO_APP", message: "App not found")
        }

        let maxDepth = params["depth"]?.intValue ?? 3
        let maxChildren = params["maxChildren"]?.intValue ?? 50
        let maxElements = params["maxElements"]?.intValue ?? 500
        let compact = params["compact"]?.boolValue ?? false
        var elementCount = 0
        let tree = buildTree(
            element: appElement,
            depth: 0,
            maxDepth: maxDepth,
            maxChildren: maxChildren,
            maxElements: maxElements,
            compact: compact,
            parentPath: "",
            elementCount: &elementCount
        )
        return .success(id: id, payload: ["tree": tree, "elementCount": .int(elementCount)])
    }

    /// Configurable tree builder with limits, compact mode, and path tracking.
    func buildTree(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        maxChildren: Int = 50,
        maxElements: Int = 500,
        compact: Bool = false,
        parentPath: String = "",
        elementCount: inout Int
    ) -> JSONValue {
        guard elementCount < maxElements else {
            return .object(["truncated": .bool(true)])
        }
        elementCount += 1

        var info: [String: JSONValue] = [:]

        let role = getStringAttribute(element, kAXRoleAttribute) ?? "unknown"
        let title = getStringAttribute(element, kAXTitleAttribute) ?? ""
        info["role"] = .string(role)
        if !title.isEmpty {
            info["title"] = .string(title)
        }

        // Build path segment
        let segment = title.isEmpty ? role : "\(role)[\(title)]"
        let currentPath = parentPath.isEmpty ? segment : "\(parentPath)>\(segment)"
        info["path"] = .string(currentPath)

        if !compact {
            if let value = getStringAttribute(element, kAXValueAttribute), !value.isEmpty {
                info["value"] = .string(String(value.prefix(200)))
            }
            if let desc = getStringAttribute(element, kAXDescriptionAttribute), !desc.isEmpty {
                info["description"] = .string(desc)
            }
            if let label = getStringAttribute(element, kAXLabelValueAttribute), !label.isEmpty {
                info["label"] = .string(label)
            }
            if let pos = getPointAttribute(element, kAXPositionAttribute),
               let size = getSizeAttribute(element, kAXSizeAttribute) {
                info["x"] = .int(Int(pos.x))
                info["y"] = .int(Int(pos.y))
                info["width"] = .int(Int(size.width))
                info["height"] = .int(Int(size.height))
            }
        }

        // Children (recurse)
        if depth < maxDepth && elementCount < maxElements {
            var childrenRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
            if result == .success, let children = childrenRef as? [AXUIElement] {
                let cappedChildren = children.prefix(maxChildren)
                let childTrees = cappedChildren.map { child in
                    buildTree(
                        element: child,
                        depth: depth + 1,
                        maxDepth: maxDepth,
                        maxChildren: maxChildren,
                        maxElements: maxElements,
                        compact: compact,
                        parentPath: currentPath,
                        elementCount: &elementCount
                    )
                }
                if !childTrees.isEmpty {
                    info["children"] = .array(childTrees)
                }
                if cappedChildren.count < children.count {
                    info["truncated"] = .bool(true)
                }
            }
        }

        return .object(info)
    }

    // MARK: - Find Element

    private func findElement(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let role = params["role"]?.stringValue ?? params["type"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "role is required")
        }

        guard let appElement = resolveAppElement(params: params) else {
            return .failure(id: id, code: "NO_APP", message: "App not found")
        }

        let title = params["title"]?.stringValue
        var results: [[String: JSONValue]] = []
        findElements(in: appElement, role: role, title: title, depth: 0, maxDepth: 6, results: &results)

        return .success(id: id, payload: [
            "elements": .array(results.prefix(20).map { .object($0) }),
            "count": .int(results.count),
        ])
    }

    func findElements(in element: AXUIElement, role: String, title: String?, depth: Int, maxDepth: Int, results: inout [[String: JSONValue]]) {
        guard depth < maxDepth else { return }

        let elementRole = getStringAttribute(element, kAXRoleAttribute) ?? ""
        let elementTitle = getStringAttribute(element, kAXTitleAttribute) ?? ""
        let elementDesc = getStringAttribute(element, kAXDescriptionAttribute) ?? ""

        let roleMatch = elementRole.localizedCaseInsensitiveContains(role)
        let titleMatch = title == nil || elementTitle.localizedCaseInsensitiveContains(title!) || elementDesc.localizedCaseInsensitiveContains(title!)

        if roleMatch && titleMatch {
            var info: [String: JSONValue] = [
                "role": .string(elementRole),
                "title": .string(elementTitle),
            ]
            if let pos = getPointAttribute(element, kAXPositionAttribute),
               let size = getSizeAttribute(element, kAXSizeAttribute) {
                info["x"] = .int(Int(pos.x))
                info["y"] = .int(Int(pos.y))
                info["width"] = .int(Int(size.width))
                info["height"] = .int(Int(size.height))
                info["centerX"] = .int(Int(pos.x + size.width / 2))
                info["centerY"] = .int(Int(pos.y + size.height / 2))
            }
            results.append(info)
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                findElements(in: child, role: role, title: title, depth: depth + 1, maxDepth: maxDepth, results: &results)
            }
        }
    }

    // MARK: - Click Element

    private func clickElement(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let role = params["role"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "role is required")
        }
        let title = params["title"]?.stringValue

        guard let appElement = resolveAppElement(params: params) else {
            return .failure(id: id, code: "NO_APP", message: "App not found")
        }

        var results: [[String: JSONValue]] = []
        findElements(in: appElement, role: role, title: title, depth: 0, maxDepth: 6, results: &results)

        guard let first = results.first else {
            return .failure(id: id, code: "NOT_FOUND", message: "Element not found: \(role) \(title ?? "")")
        }

        // Try AXPress first (for buttons), fallback to mouse click, then AppleScript
        if let foundElement = findAXElement(in: appElement, role: role, title: title, depth: 0, maxDepth: 6) {
            let pressResult = AXUIElementPerformAction(foundElement, kAXPressAction as CFString)
            if pressResult == .success {
                return .success(id: id, payload: ["clicked": .string("\(role): \(title ?? "")"), "method": .string("AXPress")])
            }
        }

        // Fallback 2: mouse click at center
        if let cx = first["centerX"]?.intValue, let cy = first["centerY"]?.intValue {
            let point = CGPoint(x: cx, y: cy)
            if performMouseClick(at: point) {
                return .success(id: id, payload: ["clicked": .string("\(role): \(title ?? "")"), "method": .string("mouseClick"), "x": .int(cx), "y": .int(cy)])
            }
        }

        // Fallback 3: AppleScript click
        if let appName = NSWorkspace.shared.frontmostApplication?.localizedName,
           let elementTitle = title, !elementTitle.isEmpty {
            let script = "tell application \"\(appName)\" to click button \"\(elementTitle)\" of front window"
            let (success, _) = runAppleScript(script)
            if success {
                return .success(id: id, payload: ["clicked": .string("\(role): \(title ?? "")"), "method": .string("appleScript")])
            }
        }

        return .failure(id: id, code: "CLICK_FAILED", message: "Could not click element")
    }

    // MARK: - Type Into Element

    private func typeIntoElement(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let text = params["text"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "text is required")
        }

        let role = params["role"]?.stringValue
        let title = params["title"]?.stringValue

        guard let appElement = resolveAppElement(params: params) else {
            return .failure(id: id, code: "NO_APP", message: "App not found")
        }

        // Find the element and set its value directly via AX
        if let searchRole = role,
           let element = findAXElement(in: appElement, role: searchRole, title: title, depth: 0, maxDepth: 6) {
            let setResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
            if setResult == .success {
                return .success(id: id, payload: ["typed": .string(text), "method": .string("AXSetValue")])
            }

            // Try focusing then typing via keyboard events
            AXUIElementPerformAction(element, "AXFocus" as CFString)
        }

        // Fallback 2: type via keyboard events
        typeViaKeyboard(text)

        // Fallback 3: AppleScript set value
        if let appName = NSWorkspace.shared.frontmostApplication?.localizedName,
           let fieldTitle = title, !fieldTitle.isEmpty {
            let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
            let script = "tell application \"\(appName)\" to set value of text field \"\(fieldTitle)\" of front window to \"\(escaped)\""
            let (success, _) = runAppleScript(script)
            if success {
                return .success(id: id, payload: ["typed": .string(text), "method": .string("appleScript")])
            }
        }

        return .success(id: id, payload: ["typed": .string(text), "method": .string("keyboard")])
    }

    // MARK: - Read Element

    private func readElement(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let appElement = resolveAppElement(params: params) else {
            return .failure(id: id, code: "NO_APP", message: "App not found")
        }

        let role = params["role"]?.stringValue ?? "AXStaticText"
        var results: [[String: JSONValue]] = []
        findElements(in: appElement, role: role, title: nil, depth: 0, maxDepth: 6, results: &results)

        let texts = results.compactMap { $0["title"]?.stringValue }.filter { !$0.isEmpty }
        return .success(id: id, payload: [
            "texts": .array(texts.prefix(50).map { .string($0) }),
            "count": .int(texts.count),
        ])
    }

    // MARK: - Focused Element

    private func getFocusedElement(id: String) -> CommandResponse {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)

        guard result == .success, let focused = focusedRef else {
            return .failure(id: id, code: "NO_FOCUS", message: "No focused element")
        }

        let element = focused as! AXUIElement
        var info: [String: JSONValue] = [
            "role": .string(getStringAttribute(element, kAXRoleAttribute) ?? ""),
            "title": .string(getStringAttribute(element, kAXTitleAttribute) ?? ""),
            "value": .string(String((getStringAttribute(element, kAXValueAttribute) ?? "").prefix(500))),
        ]

        if let pos = getPointAttribute(element, kAXPositionAttribute),
           let size = getSizeAttribute(element, kAXSizeAttribute) {
            info["x"] = .int(Int(pos.x))
            info["y"] = .int(Int(pos.y))
            info["width"] = .int(Int(size.width))
            info["height"] = .int(Int(size.height))
        }

        return .success(id: id, payload: info)
    }

    // MARK: - List Actions

    private func listActions(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let role = params["role"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "role is required")
        }

        guard let appElement = resolveAppElement(params: params) else {
            return .failure(id: id, code: "NO_APP", message: "App not found")
        }

        guard let element = findAXElement(in: appElement, role: role, title: params["title"]?.stringValue, depth: 0, maxDepth: 6) else {
            return .failure(id: id, code: "NOT_FOUND", message: "Element not found")
        }

        var actionsRef: CFArray?
        AXUIElementCopyActionNames(element, &actionsRef)
        let actions = (actionsRef as? [String]) ?? []

        return .success(id: id, payload: [
            "actions": .array(actions.map { .string($0) }),
        ])
    }

    // MARK: - Perform Action

    private func performAction(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let role = params["role"]?.stringValue,
              let actionName = params["action_name"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "role and action_name are required")
        }

        guard let appElement = resolveAppElement(params: params) else {
            return .failure(id: id, code: "NO_APP", message: "App not found")
        }

        guard let element = findAXElement(in: appElement, role: role, title: params["title"]?.stringValue, depth: 0, maxDepth: 6) else {
            return .failure(id: id, code: "NOT_FOUND", message: "Element not found")
        }

        let result = AXUIElementPerformAction(element, actionName as CFString)
        if result == .success {
            return .success(id: id, payload: ["performed": .string(actionName)])
        }
        return .failure(id: id, code: "ACTION_FAILED", message: "Failed to perform \(actionName): error \(result.rawValue)")
    }

    // MARK: - Shared Helpers (internal for extensions + AutomationHandler)

    /// Resolve an AXUIElement for the target app from params (pid, app name, or frontmost).
    func resolveAppElement(params: [String: JSONValue]) -> AXUIElement? {
        if let pid = params["pid"]?.intValue {
            return AXUIElementCreateApplication(pid_t(pid))
        } else if let appName = params["app"]?.stringValue {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
            }) else { return nil }
            return AXUIElementCreateApplication(app.processIdentifier)
        } else {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return AXUIElementCreateApplication(app.processIdentifier)
        }
    }

    func findAXElement(in element: AXUIElement, role: String, title: String?, depth: Int, maxDepth: Int) -> AXUIElement? {
        guard depth < maxDepth else { return nil }
        let r = getStringAttribute(element, kAXRoleAttribute) ?? ""
        let t = getStringAttribute(element, kAXTitleAttribute) ?? ""
        let d = getStringAttribute(element, kAXDescriptionAttribute) ?? ""
        if r.localizedCaseInsensitiveContains(role) && (title == nil || t.localizedCaseInsensitiveContains(title!) || d.localizedCaseInsensitiveContains(title!)) {
            return element
        }
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                if let found = findAXElement(in: child, role: role, title: title, depth: depth + 1, maxDepth: maxDepth) {
                    return found
                }
            }
        }
        return nil
    }

    /// Get AX action names for an element.
    func getActionNames(_ element: AXUIElement) -> [String] {
        var actionsRef: CFArray?
        AXUIElementCopyActionNames(element, &actionsRef)
        return (actionsRef as? [String]) ?? []
    }

    /// Perform a CGEvent mouse click at the given point.
    @discardableResult
    func performMouseClick(at point: CGPoint) -> Bool {
        CGWarpMouseCursorPosition(point)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Type text via keyboard events (character by character).
    func typeViaKeyboard(_ text: String) {
        for char in text {
            let str = String(char)
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { continue }
            let utf16 = Array(str.utf16)
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            event.post(tap: .cghidEventTap)
            guard let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            up.post(tap: .cghidEventTap)
            usleep(10_000)
        }
    }

    /// Run an AppleScript string and return success + optional result.
    func runAppleScript(_ script: String) -> (success: Bool, result: String?) {
        var error: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        let output = appleScript?.executeAndReturnError(&error)
        if let error {
            logger.debug("AppleScript failed: \(error)")
            return (false, nil)
        }
        return (true, output?.stringValue)
    }

    // MARK: - AX Attribute Helpers

    func getStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    func getPointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(ref as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    func getSizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(ref as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    func getChildren(_ element: AXUIElement) -> [AXUIElement] {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return []
        }
        return children
    }
}
