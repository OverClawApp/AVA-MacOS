import Foundation
import AppKit
import CoreGraphics
import os

/// Handles desktop_input commands: mouse_move, mouse_click, mouse_scroll, key_press, type_text.
/// Computer use capability — matches OpenClaw/Claude Code/Hermes Agent mouse+keyboard control.
/// Requires Accessibility TCC permission.
struct InputHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "Input")

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        let params = request.params ?? [:]

        // Check Accessibility permission (required for CGEvent posting)
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
            return .permissionMissing(id: request.id, permission: "Accessibility")
        }

        switch request.action {
        case "mouse_move":
            return mouseMove(id: request.id, params: params)
        case "mouse_click":
            return mouseClick(id: request.id, params: params)
        case "mouse_scroll":
            return mouseScroll(id: request.id, params: params)
        case "key_press":
            return keyPress(id: request.id, params: params)
        case "type_text":
            return typeText(id: request.id, params: params)
        case "mouse_drag":
            return mouseDrag(id: request.id, params: params)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown input action: \(request.action)")
        }
    }

    // MARK: - Mouse Actions

    private func mouseMove(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let x = params["x"]?.intValue, let y = params["y"]?.intValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "x and y are required")
        }

        let point = CGPoint(x: x, y: y)
        CGWarpMouseCursorPosition(point)

        return .success(id: id, payload: ["moved": .object(["x": .int(x), "y": .int(y)])])
    }

    private func mouseClick(id: String, params: [String: JSONValue]) -> CommandResponse {
        let x = params["x"]?.intValue
        let y = params["y"]?.intValue
        let button = params["button"]?.stringValue ?? "left"
        let clicks = params["clicks"]?.intValue ?? 1

        let point: CGPoint
        if let x, let y {
            point = CGPoint(x: x, y: y)
            CGWarpMouseCursorPosition(point)
        } else {
            point = NSEvent.mouseLocation
        }

        let mouseButton: CGMouseButton = button == "right" ? .right : .left
        let downType: CGEventType = button == "right" ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == "right" ? .rightMouseUp : .leftMouseUp

        guard let downEvent = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: mouseButton),
              let upEvent = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: mouseButton) else {
            return .failure(id: id, code: "EVENT_FAILED", message: "Failed to create mouse event")
        }

        downEvent.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        upEvent.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))

        downEvent.post(tap: .cghidEventTap)
        upEvent.post(tap: .cghidEventTap)

        logger.info("Mouse \(button) click at (\(Int(point.x)), \(Int(point.y)))")
        return .success(id: id, payload: ["clicked": .object(["x": .int(Int(point.x)), "y": .int(Int(point.y)), "button": .string(button)])])
    }

    private func mouseScroll(id: String, params: [String: JSONValue]) -> CommandResponse {
        let dx = params["dx"]?.intValue ?? 0
        let dy = params["dy"]?.intValue ?? 0

        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else {
            return .failure(id: id, code: "EVENT_FAILED", message: "Failed to create scroll event")
        }
        event.post(tap: .cgSessionEventTap)

        return .success(id: id, payload: ["scrolled": .object(["dx": .int(dx), "dy": .int(dy)])])
    }

    private func mouseDrag(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let fromX = params["fromX"]?.intValue, let fromY = params["fromY"]?.intValue,
              let toX = params["toX"]?.intValue, let toY = params["toY"]?.intValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "fromX, fromY, toX, toY are required")
        }

        let from = CGPoint(x: fromX, y: fromY)
        let to = CGPoint(x: toX, y: toY)

        guard let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left),
              let dragEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: to, mouseButton: .left),
              let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left) else {
            return .failure(id: id, code: "EVENT_FAILED", message: "Failed to create drag events")
        }

        downEvent.post(tap: .cghidEventTap)
        usleep(50_000) // 50ms delay for drag
        dragEvent.post(tap: .cghidEventTap)
        usleep(50_000)
        upEvent.post(tap: .cghidEventTap)

        return .success(id: id, payload: ["dragged": .object(["from": .object(["x": .int(fromX), "y": .int(fromY)]), "to": .object(["x": .int(toX), "y": .int(toY)])])])
    }

    // MARK: - Keyboard Actions

    private func keyPress(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let key = params["key"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "key is required")
        }

        let modifiers = params["modifiers"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        var flags: CGEventFlags = []
        for mod in modifiers {
            switch mod.lowercased() {
            case "command", "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            default: break
            }
        }

        guard let keyCode = keyCodeFor(key) else {
            return .failure(id: id, code: "UNKNOWN_KEY", message: "Unknown key: \(key)")
        }

        guard let downEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return .failure(id: id, code: "EVENT_FAILED", message: "Failed to create key event")
        }

        downEvent.flags = flags
        upEvent.flags = flags
        downEvent.post(tap: .cghidEventTap)
        upEvent.post(tap: .cghidEventTap)

        logger.info("Key press: \(key) modifiers=\(modifiers)")
        return .success(id: id, payload: ["pressed": .string(key)])
    }

    private func typeText(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let text = params["text"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "text is required")
        }

        // Use CGEvent to type each character
        for char in text {
            let str = String(char)
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { continue }
            let utf16 = Array(str.utf16)
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            event.post(tap: .cghidEventTap)

            guard let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            upEvent.post(tap: .cghidEventTap)

            usleep(10_000) // 10ms between chars
        }

        logger.info("Typed \(text.count) characters")
        return .success(id: id, payload: ["typed": .int(text.count)])
    }

    // MARK: - Key Code Mapping

    private func keyCodeFor(_ key: String) -> CGKeyCode? {
        let map: [String: CGKeyCode] = [
            "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31,
            "delete": 0x33, "backspace": 0x33, "escape": 0x35, "esc": 0x35,
            "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
            "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
            "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
            "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
            "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
            "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02,
            "e": 0x0E, "f": 0x03, "g": 0x05, "h": 0x04,
            "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
            "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23,
            "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11,
            "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
            "y": 0x10, "z": 0x06,
            "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14,
            "4": 0x15, "5": 0x17, "6": 0x16, "7": 0x1A,
            "8": 0x1C, "9": 0x19,
        ]
        return map[key.lowercased()]
    }
}
