import Foundation
import AppKit
import CoreGraphics
import os

/// Handles desktop_vision commands — vision-based UI grounding (Agent-S3 pattern).
/// Takes a screenshot, sends it to the backend LLM for coordinate extraction,
/// then executes the action at the identified location.
///
/// This combines screenshot + LLM vision + action into a single step,
/// reducing round-trips compared to separate screenshot → analyze → click calls.
struct VisionHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "Vision")

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        let params = request.params ?? [:]

        switch request.action {
        case "click":
            return try await visionClick(id: request.id, params: params)
        case "find":
            return try await visionFind(id: request.id, params: params)
        case "read_screen":
            return try await readScreen(id: request.id, params: params)
        case "describe":
            return try await describeScreen(id: request.id, params: params)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown vision action: \(request.action)")
        }
    }

    // MARK: - Vision Click (Agent-S3 pattern: screenshot → LLM grounding → click)

    private func visionClick(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard let target = params["target"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "target description is required (e.g. 'the blue Submit button')")
        }

        // Step 1: Capture screenshot
        guard let screenshot = captureScreen() else {
            return .failure(id: id, code: "CAPTURE_FAILED", message: "Failed to capture screen")
        }

        // Step 2: Send screenshot + target to backend for coordinate grounding
        let coordinates = try await groundElement(screenshot: screenshot, target: target)

        guard let x = coordinates["x"], let y = coordinates["y"] else {
            return .failure(id: id, code: "NOT_FOUND", message: "Could not find '\(target)' on screen")
        }

        // Step 3: Click at the identified coordinates
        let point = CGPoint(x: x, y: y)
        CGWarpMouseCursorPosition(point)

        let button = params["button"]?.stringValue ?? "left"
        let clicks = params["clicks"]?.intValue ?? 1
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

        logger.info("Vision click: '\(target)' at (\(x), \(y))")
        return .success(id: id, payload: [
            "clicked": .string(target),
            "x": .int(x),
            "y": .int(y),
            "method": .string("vision_grounding"),
        ])
    }

    // MARK: - Vision Find (locate element without clicking)

    private func visionFind(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard let target = params["target"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "target description is required")
        }

        guard let screenshot = captureScreen() else {
            return .failure(id: id, code: "CAPTURE_FAILED", message: "Failed to capture screen")
        }

        let coordinates = try await groundElement(screenshot: screenshot, target: target)

        guard let x = coordinates["x"], let y = coordinates["y"] else {
            return .failure(id: id, code: "NOT_FOUND", message: "Could not find '\(target)' on screen")
        }

        return .success(id: id, payload: [
            "found": .string(target),
            "x": .int(x),
            "y": .int(y),
            "confidence": .string(coordinates["confidence"].map { "\($0)" } ?? "unknown"),
        ])
    }

    // MARK: - Read Screen (OCR-like text extraction via vision)

    private func readScreen(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard let screenshot = captureScreen() else {
            return .failure(id: id, code: "CAPTURE_FAILED", message: "Failed to capture screen")
        }

        let region = params["region"]?.stringValue // e.g. "top-left", "center", "the dialog box"
        let prompt: String
        if let region {
            prompt = "Read all visible text in the \(region) area of this screenshot. Return the text exactly as displayed."
        } else {
            prompt = "Read all visible text on this screen. Return the text organized by visual sections, top to bottom."
        }

        let result = try await queryVision(screenshot: screenshot, prompt: prompt)
        return .success(id: id, payload: ["text": .string(result)])
    }

    // MARK: - Describe Screen (what's on screen right now)

    private func describeScreen(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard let screenshot = captureScreen() else {
            return .failure(id: id, code: "CAPTURE_FAILED", message: "Failed to capture screen")
        }

        let focus = params["focus"]?.stringValue
        let prompt: String
        if let focus {
            prompt = "Describe what you see on this screen, focusing on: \(focus). Include the positions of interactive elements (buttons, fields, links) and their approximate screen coordinates."
        } else {
            prompt = "Describe this screen in detail. What app is open? What content is visible? List all interactive elements (buttons, text fields, menus, links) with their approximate positions on screen."
        }

        let result = try await queryVision(screenshot: screenshot, prompt: prompt)
        return .success(id: id, payload: ["description": .string(result)])
    }

    // MARK: - Screenshot Helper

    private func captureScreen() -> Data? {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return nil
        }

        let tempFile = NSTemporaryDirectory() + "ava_vision_\(UUID().uuidString).png"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-C", tempFile]
        try? process.run()
        process.waitUntilExit()

        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        guard process.terminationStatus == 0 else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: tempFile))
    }

    // MARK: - Backend Vision API

    /// Send screenshot + target description to backend, get coordinates back.
    /// The backend uses the multimodal LLM to identify the element location.
    private func groundElement(screenshot: Data, target: String) async throws -> [String: Int] {
        let base64 = screenshot.base64EncodedString()

        let prompt = """
        Look at this screenshot and find the UI element matching this description: "\(target)"

        Return ONLY a JSON object with the x,y pixel coordinates of the CENTER of that element:
        {"x": 123, "y": 456}

        If you cannot find the element, return: {"x": null, "y": null}
        """

        let responseText = try await queryVision(screenshot: screenshot, prompt: prompt)

        // Parse coordinates from LLM response
        guard let jsonData = extractJSON(from: responseText),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return [:]
        }

        var result: [String: Int] = [:]
        if let x = dict["x"] as? Int { result["x"] = x }
        if let y = dict["y"] as? Int { result["y"] = y }
        if let x = dict["x"] as? Double { result["x"] = Int(x) }
        if let y = dict["y"] as? Double { result["y"] = Int(y) }
        return result
    }

    /// Generic vision query — sends screenshot + text prompt to backend.
    private func queryVision(screenshot: Data, prompt: String) async throws -> String {
        let base64 = screenshot.base64EncodedString()

        // Use the desktop relay to send a vision query to the backend
        // The backend will route this to the multimodal LLM
        guard let url = URL(string: "\(Constants.apiBaseURL)/desktop/vision") else {
            throw NSError(domain: "VisionHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid API URL"])
        }

        guard let token = KeychainHelper.load(key: Constants.keychainAccessTokenKey) else {
            throw NSError(domain: "VisionHandler", code: -2, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "image": base64,
            "prompt": prompt,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "VisionHandler", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Vision API error (\(statusCode))"])
        }

        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return result?["result"] as? String ?? ""
    }

    /// Extract JSON object from LLM text that may contain markdown/extra text
    private func extractJSON(from text: String) -> Data? {
        // Try direct parse first
        if let data = text.data(using: .utf8),
           let _ = try? JSONSerialization.jsonObject(with: data) {
            return data
        }

        // Find JSON in the text (between { and })
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }

        let jsonStr = String(text[start...end])
        return jsonStr.data(using: .utf8)
    }
}
