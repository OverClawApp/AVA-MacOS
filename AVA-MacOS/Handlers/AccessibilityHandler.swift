import Foundation
import AppKit
import os

/// Handles desktop_accessibility commands — read UI element trees, find elements, interact with any app.
/// Uses macOS Accessibility API (AXUIElement) for precise computer use.
/// Requires Accessibility TCC permission.
struct AccessibilityHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "Accessibility")

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
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown accessibility action: \(request.action)")
        }
    }

    // MARK: - UI Tree

    private func getUITree(id: String, params: [String: JSONValue]) -> CommandResponse {
        let appElement: AXUIElement
        if let pid = params["pid"]?.intValue {
            appElement = AXUIElementCreateApplication(pid_t(pid))
        } else if let appName = params["app"]?.stringValue {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
            }) else {
                return .failure(id: id, code: "NOT_FOUND", message: "App not found: \(appName)")
            }
            appElement = AXUIElementCreateApplication(app.processIdentifier)
        } else {
            // Use frontmost app
            guard let app = NSWorkspace.shared.frontmostApplication else {
                return .failure(id: id, code: "NO_APP", message: "No frontmost app")
            }
            appElement = AXUIElementCreateApplication(app.processIdentifier)
        }

        let maxDepth = params["depth"]?.intValue ?? 3
        let tree = buildTree(element: appElement, depth: 0, maxDepth: maxDepth)
        return .success(id: id, payload: ["tree": tree])
    }

    private func buildTree(element: AXUIElement, depth: Int, maxDepth: Int) -> JSONValue {
        var info: [String: JSONValue] = [:]

        info["role"] = .string(getStringAttribute(element, kAXRoleAttribute) ?? "unknown")
        if let title = getStringAttribute(element, kAXTitleAttribute), !title.isEmpty {
            info["title"] = .string(title)
        }
        if let value = getStringAttribute(element, kAXValueAttribute), !value.isEmpty {
            info["value"] = .string(String(value.prefix(200)))
        }
        if let desc = getStringAttribute(element, kAXDescriptionAttribute), !desc.isEmpty {
            info["description"] = .string(desc)
        }
        if let label = getStringAttribute(element, kAXLabelValueAttribute), !label.isEmpty {
            info["label"] = .string(label)
        }

        // Position and size
        if let pos = getPointAttribute(element, kAXPositionAttribute),
           let size = getSizeAttribute(element, kAXSizeAttribute) {
            info["x"] = .int(Int(pos.x))
            info["y"] = .int(Int(pos.y))
            info["width"] = .int(Int(size.width))
            info["height"] = .int(Int(size.height))
        }

        // Children (recurse)
        if depth < maxDepth {
            var childrenRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
            if result == .success, let children = childrenRef as? [AXUIElement] {
                let childTrees = children.prefix(50).map { child in
                    buildTree(element: child, depth: depth + 1, maxDepth: maxDepth)
                }
                if !childTrees.isEmpty {
                    info["children"] = .array(childTrees)
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

        let title = params["title"]?.stringValue
        let appName = params["app"]?.stringValue

        let appElement: AXUIElement
        if let appName {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
            }) else {
                return .failure(id: id, code: "NOT_FOUND", message: "App not found: \(appName)")
            }
            appElement = AXUIElementCreateApplication(app.processIdentifier)
        } else {
            guard let app = NSWorkspace.shared.frontmostApplication else {
                return .failure(id: id, code: "NO_APP", message: "No frontmost app")
            }
            appElement = AXUIElementCreateApplication(app.processIdentifier)
        }

        var results: [[String: JSONValue]] = []
        findElements(in: appElement, role: role, title: title, depth: 0, maxDepth: 6, results: &results)

        return .success(id: id, payload: [
            "elements": .array(results.prefix(20).map { .object($0) }),
            "count": .int(results.count),
        ])
    }

    private func findElements(in element: AXUIElement, role: String, title: String?, depth: Int, maxDepth: Int, results: inout [[String: JSONValue]]) {
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
        // Find by role+title, then click its center via AXPress or mouse click
        guard let role = params["role"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "role is required")
        }
        let title = params["title"]?.stringValue
        let appName = params["app"]?.stringValue

        let appElement: AXUIElement
        if let appName {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
            }) else {
                return .failure(id: id, code: "NOT_FOUND", message: "App not found: \(appName)")
            }
            appElement = AXUIElementCreateApplication(app.processIdentifier)
        } else {
            guard let app = NSWorkspace.shared.frontmostApplication else {
                return .failure(id: id, code: "NO_APP", message: "No frontmost app")
            }
            appElement = AXUIElementCreateApplication(app.processIdentifier)
        }

        var results: [[String: JSONValue]] = []
        findElements(in: appElement, role: role, title: title, depth: 0, maxDepth: 6, results: &results)

        guard let first = results.first else {
            return .failure(id: id, code: "NOT_FOUND", message: "Element not found: \(role) \(title ?? "")")
        }

        // Try AXPress first (for buttons), fallback to mouse click
        if let foundElement = findAXElement(in: appElement, role: role, title: title, depth: 0, maxDepth: 6) {
            let pressResult = AXUIElementPerformAction(foundElement, kAXPressAction as CFString)
            if pressResult == .success {
                return .success(id: id, payload: ["clicked": .string("\(role): \(title ?? "")"), "method": .string("AXPress")])
            }
        }

        // Fallback: mouse click at center
        if let cx = first["centerX"]?.intValue, let cy = first["centerY"]?.intValue {
            let point = CGPoint(x: cx, y: cy)
            CGWarpMouseCursorPosition(point)
            if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
               let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            return .success(id: id, payload: ["clicked": .string("\(role): \(title ?? "")"), "method": .string("mouseClick"), "x": .int(cx), "y": .int(cy)])
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
        let appName = params["app"]?.stringValue

        let appElement: AXUIElement
        if let appName {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
            }) else {
                return .failure(id: id, code: "NOT_FOUND", message: "App not found: \(appName)")
            }
            appElement = AXUIElementCreateApplication(app.processIdentifier)
        } else {
            guard let app = NSWorkspace.shared.frontmostApplication else {
                return .failure(id: id, code: "NO_APP", message: "No frontmost app")
            }
            appElement = AXUIElementCreateApplication(app.processIdentifier)
        }

        // Find the element and set its value directly via AX
        if let searchRole = role,
           let element = findAXElement(in: appElement, role: searchRole, title: title, depth: 0, maxDepth: 6) {
            // Try setting value directly
            let setResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
            if setResult == .success {
                return .success(id: id, payload: ["typed": .string(text), "method": .string("AXSetValue")])
            }

            // Try focusing then typing via keyboard events
            AXUIElementPerformAction(element, "AXFocus" as CFString)
        }

        // Fallback: type via keyboard events
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

        return .success(id: id, payload: ["typed": .string(text), "method": .string("keyboard")])
    }

    // MARK: - Read Element

    private func readElement(id: String, params: [String: JSONValue]) -> CommandResponse {
        let appElement: AXUIElement
        if let appName = params["app"]?.stringValue {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
            }) else {
                return .failure(id: id, code: "NOT_FOUND", message: "App not found: \(appName)")
            }
            appElement = AXUIElementCreateApplication(app.processIdentifier)
        } else {
            guard let app = NSWorkspace.shared.frontmostApplication else {
                return .failure(id: id, code: "NO_APP", message: "No frontmost app")
            }
            appElement = AXUIElementCreateApplication(app.processIdentifier)
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

        let appElement: AXUIElement
        if let appName = params["app"]?.stringValue {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
            }) else { return .failure(id: id, code: "NOT_FOUND", message: "App not found") }
            appElement = AXUIElementCreateApplication(app.processIdentifier)
        } else {
            guard let app = NSWorkspace.shared.frontmostApplication else {
                return .failure(id: id, code: "NO_APP", message: "No frontmost app")
            }
            appElement = AXUIElementCreateApplication(app.processIdentifier)
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

        let appElement: AXUIElement
        if let appName = params["app"]?.stringValue {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
            }) else { return .failure(id: id, code: "NOT_FOUND", message: "App not found") }
            appElement = AXUIElementCreateApplication(app.processIdentifier)
        } else {
            guard let app = NSWorkspace.shared.frontmostApplication else {
                return .failure(id: id, code: "NO_APP", message: "No frontmost app")
            }
            appElement = AXUIElementCreateApplication(app.processIdentifier)
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

    // MARK: - AX Helpers

    private func findAXElement(in element: AXUIElement, role: String, title: String?, depth: Int, maxDepth: Int) -> AXUIElement? {
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

    private func getStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private func getPointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(ref as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func getSizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(ref as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}
