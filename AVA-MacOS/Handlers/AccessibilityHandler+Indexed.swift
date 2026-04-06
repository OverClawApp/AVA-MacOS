import Foundation
import AppKit

/// Indexed interactive element for LLM-friendly "click element 7" targeting.
struct IndexedElement {
    let index: Int
    let element: AXUIElement
    let role: String
    let title: String
    let position: CGPoint
    let size: CGSize
    let actions: [String]
    let path: String
}

/// Static element cache shared across AccessibilityHandler invocations.
enum IndexedElementCache {
    static var elements: [Int: IndexedElement] = [:]
    static var timestamp: Date = .distantPast
    static var appPid: pid_t = 0

    /// Cache is valid for 5 seconds and only for the same frontmost app.
    static var isValid: Bool {
        let age = Date().timeIntervalSince(timestamp)
        let currentPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        return age < 5.0 && currentPid == appPid && !elements.isEmpty
    }

    static func clear() {
        elements.removeAll()
        timestamp = .distantPast
        appPid = 0
    }
}

// MARK: - Indexed Tree Actions

extension AccessibilityHandler {

    /// Build an indexed tree of interactive elements. Non-interactive elements become context.
    func getIndexedTree(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let appElement = resolveAppElement(params: params) else {
            return .failure(id: id, code: "NO_APP", message: "App not found")
        }

        let maxDepth = params["depth"]?.intValue ?? 5
        let compact = params["compact"]?.boolValue ?? false

        let result = buildIndexedTree(element: appElement, maxDepth: maxDepth, compact: compact)

        // Populate cache
        IndexedElementCache.clear()
        for elem in result.interactive {
            IndexedElementCache.elements[elem.index] = elem
        }
        IndexedElementCache.timestamp = Date()
        IndexedElementCache.appPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0

        // Build response arrays
        let interactiveJSON: [JSONValue] = result.interactive.map { elem in
            var obj: [String: JSONValue] = [
                "index": .int(elem.index),
                "role": .string(elem.role),
                "title": .string(elem.title),
                "x": .int(Int(elem.position.x)),
                "y": .int(Int(elem.position.y)),
                "width": .int(Int(elem.size.width)),
                "height": .int(Int(elem.size.height)),
                "actions": .array(elem.actions.map { .string($0) }),
                "path": .string(elem.path),
            ]
            if compact {
                obj.removeValue(forKey: "x")
                obj.removeValue(forKey: "y")
                obj.removeValue(forKey: "width")
                obj.removeValue(forKey: "height")
            }
            return .object(obj)
        }

        let contextJSON: [JSONValue] = result.context.map { elem in
            .object([
                "role": .string(elem.role),
                "title": .string(elem.title),
            ])
        }

        return .success(id: id, payload: [
            "interactiveElements": .array(interactiveJSON),
            "contextElements": .array(contextJSON),
            "elementCount": .int(result.interactive.count + result.context.count),
        ])
    }

    struct ContextElement {
        let role: String
        let title: String
    }

    struct IndexedTreeResult {
        var interactive: [IndexedElement]
        var context: [ContextElement]
    }

    /// Walk the AX tree and separate interactive vs context elements.
    func buildIndexedTree(
        element: AXUIElement,
        maxDepth: Int,
        compact: Bool = false
    ) -> IndexedTreeResult {
        var interactive: [IndexedElement] = []
        var context: [ContextElement] = []
        var nextIndex = 0

        func walk(_ el: AXUIElement, depth: Int, parentPath: String) {
            guard depth <= maxDepth else { return }

            let role = getStringAttribute(el, kAXRoleAttribute) ?? "unknown"
            let title = getStringAttribute(el, kAXTitleAttribute) ?? ""
            let desc = getStringAttribute(el, kAXDescriptionAttribute) ?? ""
            let displayTitle = title.isEmpty ? desc : title

            // Build path
            let segment = displayTitle.isEmpty ? role : "\(role)[\(displayTitle)]"
            let currentPath = parentPath.isEmpty ? segment : "\(parentPath)>\(segment)"

            // Check if interactive (has meaningful AX actions)
            let actions = getActionNames(el)
            let interactiveActions = actions.filter {
                ["AXPress", "AXShowMenu", "AXPick", "AXIncrement", "AXDecrement", "AXConfirm", "AXCancel"].contains($0)
            }

            // Also check if it's a text field (supports AXSetValue)
            let isTextField = role.contains("TextField") || role.contains("TextArea") || role.contains("ComboBox")
            let isInteractive = !interactiveActions.isEmpty || isTextField

            if isInteractive {
                let pos = getPointAttribute(el, kAXPositionAttribute) ?? .zero
                let size = getSizeAttribute(el, kAXSizeAttribute) ?? .zero
                let indexed = IndexedElement(
                    index: nextIndex,
                    element: el,
                    role: role,
                    title: displayTitle,
                    position: pos,
                    size: size,
                    actions: actions,
                    path: currentPath
                )
                interactive.append(indexed)
                nextIndex += 1
            } else if !displayTitle.isEmpty {
                // Non-interactive with visible text — context element
                context.append(ContextElement(role: role, title: displayTitle))
            }

            // Recurse into children
            let children = getChildren(el)
            for child in children.prefix(50) {
                walk(child, depth: depth + 1, parentPath: currentPath)
            }
        }

        walk(element, depth: 0, parentPath: "")
        return IndexedTreeResult(interactive: interactive, context: context)
    }

    // MARK: - Click by Index

    func clickByIndex(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let index = params["index"]?.intValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "index is required")
        }

        guard IndexedElementCache.isValid else {
            return .failure(id: id, code: "CACHE_EXPIRED", message: "Element cache expired. Call indexed_tree first.")
        }

        guard let cached = IndexedElementCache.elements[index] else {
            return .failure(id: id, code: "NOT_FOUND", message: "No element at index \(index). Valid: 0..\(IndexedElementCache.elements.count - 1)")
        }

        // Validate element still exists
        guard getStringAttribute(cached.element, kAXRoleAttribute) != nil else {
            IndexedElementCache.clear()
            return .failure(id: id, code: "STALE", message: "Element no longer exists. UI may have changed.")
        }

        // Fallback 1: AXPress
        let pressResult = AXUIElementPerformAction(cached.element, kAXPressAction as CFString)
        if pressResult == .success {
            IndexedElementCache.clear() // UI likely changed
            return .success(id: id, payload: [
                "clicked": .bool(true), "index": .int(index),
                "role": .string(cached.role), "title": .string(cached.title),
                "method": .string("AXPress"),
            ])
        }

        // Fallback 2: CGEvent mouse click at center
        let center = CGPoint(x: cached.position.x + cached.size.width / 2,
                             y: cached.position.y + cached.size.height / 2)
        if performMouseClick(at: center) {
            IndexedElementCache.clear()
            return .success(id: id, payload: [
                "clicked": .bool(true), "index": .int(index),
                "role": .string(cached.role), "title": .string(cached.title),
                "method": .string("mouseClick"),
            ])
        }

        // Fallback 3: AppleScript
        if let appName = NSWorkspace.shared.frontmostApplication?.localizedName, !cached.title.isEmpty {
            let script = "tell application \"\(appName)\" to click button \"\(cached.title)\" of front window"
            let (success, _) = runAppleScript(script)
            if success {
                IndexedElementCache.clear()
                return .success(id: id, payload: [
                    "clicked": .bool(true), "index": .int(index),
                    "role": .string(cached.role), "title": .string(cached.title),
                    "method": .string("appleScript"),
                ])
            }
        }

        return .failure(id: id, code: "CLICK_FAILED", message: "All click methods failed for index \(index)")
    }

    // MARK: - Type by Index

    func typeByIndex(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let index = params["index"]?.intValue,
              let text = params["text"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "index and text are required")
        }

        guard IndexedElementCache.isValid else {
            return .failure(id: id, code: "CACHE_EXPIRED", message: "Element cache expired. Call indexed_tree first.")
        }

        guard let cached = IndexedElementCache.elements[index] else {
            return .failure(id: id, code: "NOT_FOUND", message: "No element at index \(index)")
        }

        guard getStringAttribute(cached.element, kAXRoleAttribute) != nil else {
            IndexedElementCache.clear()
            return .failure(id: id, code: "STALE", message: "Element no longer exists. UI may have changed.")
        }

        // Fallback 1: AXSetValue
        let setResult = AXUIElementSetAttributeValue(cached.element, kAXValueAttribute as CFString, text as CFTypeRef)
        if setResult == .success {
            IndexedElementCache.clear()
            return .success(id: id, payload: [
                "typed": .bool(true), "index": .int(index), "text": .string(text),
                "role": .string(cached.role), "title": .string(cached.title),
                "method": .string("AXSetValue"),
            ])
        }

        // Fallback 2: Focus + keyboard events
        AXUIElementPerformAction(cached.element, "AXFocus" as CFString)
        typeViaKeyboard(text)
        IndexedElementCache.clear()

        // Fallback 3: AppleScript
        if let appName = NSWorkspace.shared.frontmostApplication?.localizedName, !cached.title.isEmpty {
            let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
            let script = "tell application \"\(appName)\" to set value of text field \"\(cached.title)\" of front window to \"\(escaped)\""
            let (success, _) = runAppleScript(script)
            if success {
                return .success(id: id, payload: [
                    "typed": .bool(true), "index": .int(index), "text": .string(text),
                    "role": .string(cached.role), "title": .string(cached.title),
                    "method": .string("appleScript"),
                ])
            }
        }

        return .success(id: id, payload: [
            "typed": .bool(true), "index": .int(index), "text": .string(text),
            "role": .string(cached.role), "title": .string(cached.title),
            "method": .string("keyboard"),
        ])
    }

    // MARK: - Clear Cache

    func clearElementCache(id: String) -> CommandResponse {
        IndexedElementCache.clear()
        return .success(id: id, payload: ["cleared": .bool(true)])
    }
}
