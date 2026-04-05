import Foundation
import os

/// Handles desktop_browser commands — controls Chrome via DevTools Protocol (CDP).
/// Also supports Safari via AppleScript fallback.
struct BrowserHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "Browser")

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        let params = request.params ?? [:]

        switch request.action {
        case "navigate":
            return try await navigate(id: request.id, params: params)
        case "get_page":
            return try await getPageContent(id: request.id, params: params)
        case "click":
            return try await clickElement(id: request.id, params: params)
        case "type":
            return try await typeText(id: request.id, params: params)
        case "evaluate":
            return try await evaluate(id: request.id, params: params)
        case "screenshot":
            return try await pageScreenshot(id: request.id, params: params)
        case "tabs":
            return try await listTabs(id: request.id, params: params)
        case "back":
            return try await goBack(id: request.id, params: params)
        case "forward":
            return try await goForward(id: request.id, params: params)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown browser action: \(request.action)")
        }
    }

    // MARK: - CDP Connection

    /// Send a CDP command to Chrome's remote debugging port
    private func sendCDP(_ method: String, params: [String: Any] = [:], targetId: String? = nil) async throws -> [String: Any] {
        // First get the WebSocket debug URL
        let debugPort = 9222
        guard let listURL = URL(string: "http://127.0.0.1:\(debugPort)/json") else {
            throw BrowserError.notRunning
        }

        let (data, _) = try await URLSession.shared.data(from: listURL)
        guard let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw BrowserError.noTargets
        }

        // Find the target
        let target: [String: Any]
        if let targetId {
            target = targets.first { ($0["id"] as? String) == targetId } ?? targets[0]
        } else {
            target = targets.first { ($0["type"] as? String) == "page" } ?? targets[0]
        }

        guard let wsURL = target["webSocketDebuggerUrl"] as? String,
              let url = URL(string: wsURL) else {
            throw BrowserError.noDebugURL
        }

        // Send command via WebSocket
        let requestId = Int.random(in: 1...999999)
        let message: [String: Any] = [
            "id": requestId,
            "method": method,
            "params": params,
        ]

        let messageData = try JSONSerialization.data(withJSONObject: message)

        return try await withCheckedThrowingContinuation { continuation in
            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: url)
            task.resume()

            task.send(.data(messageData)) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                task.receive { result in
                    switch result {
                    case .success(let msg):
                        switch msg {
                        case .data(let d):
                            let response = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
                            continuation.resume(returning: response)
                        case .string(let s):
                            let response = (try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) ?? [:]
                            continuation.resume(returning: response)
                        @unknown default:
                            continuation.resume(returning: [:])
                        }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                    task.cancel(with: .normalClosure, reason: nil)
                }
            }
        }
    }

    /// Check if Chrome is running with remote debugging enabled
    private func ensureChromeDebugMode() async throws {
        // Check if Chrome debug port is accessible
        guard let url = URL(string: "http://127.0.0.1:9222/json/version") else { throw BrowserError.notRunning }
        do {
            let _ = try await URLSession.shared.data(from: url)
        } catch {
            // Try launching Chrome with debug flag
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Google Chrome", "--args", "--remote-debugging-port=9222"]
            try process.run()
            // Wait for it to start
            try await Task.sleep(for: .seconds(2))

            // Verify
            do {
                let _ = try await URLSession.shared.data(from: url)
            } catch {
                throw BrowserError.notRunning
            }
        }
    }

    // MARK: - Actions

    private func navigate(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard let url = params["url"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "url is required")
        }

        // Try CDP first
        do {
            try await ensureChromeDebugMode()
            let result = try await sendCDP("Page.navigate", params: ["url": url])
            return .success(id: id, payload: [
                "navigated": .string(url),
                "method": .string("cdp"),
                "frameId": .string(result["result"].flatMap { ($0 as? [String: Any])?["frameId"] as? String } ?? ""),
            ])
        } catch {
            // Fallback: AppleScript to open in default browser
            let script = "open location \"\(url)\""
            var appleError: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&appleError)
            return .success(id: id, payload: [
                "navigated": .string(url),
                "method": .string("applescript"),
            ])
        }
    }

    private func getPageContent(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        try await ensureChromeDebugMode()

        let js = params["selector"]?.stringValue.map {
            "document.querySelector('\($0)')?.textContent || ''"
        } ?? "document.body.innerText.slice(0, 50000)"

        let result = try await sendCDP("Runtime.evaluate", params: ["expression": js, "returnByValue": true])

        let value = (result["result"] as? [String: Any])?["result"] as? [String: Any]
        let text = value?["value"] as? String ?? ""

        // Also get URL and title
        let titleResult = try await sendCDP("Runtime.evaluate", params: ["expression": "document.title", "returnByValue": true])
        let urlResult = try await sendCDP("Runtime.evaluate", params: ["expression": "window.location.href", "returnByValue": true])

        let title = ((titleResult["result"] as? [String: Any])?["result"] as? [String: Any])?["value"] as? String ?? ""
        let pageUrl = ((urlResult["result"] as? [String: Any])?["result"] as? [String: Any])?["value"] as? String ?? ""

        return .success(id: id, payload: [
            "content": .string(String(text.prefix(50_000))),
            "title": .string(title),
            "url": .string(pageUrl),
            "truncated": .bool(text.count > 50_000),
        ])
    }

    private func clickElement(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard let selector = params["selector"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "selector is required")
        }

        try await ensureChromeDebugMode()
        let js = "(() => { const el = document.querySelector('\(selector)'); if (el) { el.click(); return 'clicked'; } return 'not found'; })()"
        let result = try await sendCDP("Runtime.evaluate", params: ["expression": js, "returnByValue": true])
        let value = ((result["result"] as? [String: Any])?["result"] as? [String: Any])?["value"] as? String ?? "error"

        return .success(id: id, payload: ["result": .string(value), "selector": .string(selector)])
    }

    private func typeText(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard let selector = params["selector"]?.stringValue,
              let text = params["text"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "selector and text are required")
        }

        try await ensureChromeDebugMode()

        // Focus the element
        let focusJs = "document.querySelector('\(selector)')?.focus()"
        _ = try await sendCDP("Runtime.evaluate", params: ["expression": focusJs])

        // Type each character via CDP Input.dispatchKeyEvent
        for char in text {
            _ = try await sendCDP("Input.dispatchKeyEvent", params: [
                "type": "keyDown",
                "text": String(char),
            ])
            _ = try await sendCDP("Input.dispatchKeyEvent", params: [
                "type": "keyUp",
                "text": String(char),
            ])
        }

        return .success(id: id, payload: ["typed": .string(text), "selector": .string(selector)])
    }

    private func evaluate(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard let expression = params["expression"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "expression is required")
        }

        try await ensureChromeDebugMode()
        let result = try await sendCDP("Runtime.evaluate", params: ["expression": expression, "returnByValue": true])
        let value = (result["result"] as? [String: Any])?["result"] as? [String: Any]
        let returnValue = value?["value"]

        let stringResult: String
        if let str = returnValue as? String { stringResult = str }
        else if let data = try? JSONSerialization.data(withJSONObject: returnValue as Any),
                let str = String(data: data, encoding: .utf8) { stringResult = str }
        else { stringResult = String(describing: returnValue ?? "undefined") }

        return .success(id: id, payload: ["result": .string(String(stringResult.prefix(50_000)))])
    }

    private func pageScreenshot(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        try await ensureChromeDebugMode()
        let format = params["format"]?.stringValue ?? "png"
        let result = try await sendCDP("Page.captureScreenshot", params: ["format": format])
        let base64 = ((result["result"] as? [String: Any])?["data"]) as? String ?? ""

        return .success(id: id, payload: [
            "image": .string(base64),
            "encoding": .string("base64"),
            "format": .string(format),
        ])
    }

    private func listTabs(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        try await ensureChromeDebugMode()
        guard let url = URL(string: "http://127.0.0.1:9222/json") else {
            throw BrowserError.notRunning
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw BrowserError.noTargets
        }

        let tabs = targets.filter { ($0["type"] as? String) == "page" }.map { target -> JSONValue in
            .object([
                "id": .string(target["id"] as? String ?? ""),
                "title": .string(target["title"] as? String ?? ""),
                "url": .string(target["url"] as? String ?? ""),
            ])
        }

        return .success(id: id, payload: ["tabs": .array(tabs), "count": .int(tabs.count)])
    }

    private func goBack(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        try await ensureChromeDebugMode()
        let result = try await sendCDP("Runtime.evaluate", params: ["expression": "history.back()", "returnByValue": true])
        return .success(id: id, payload: ["navigated": .string("back")])
    }

    private func goForward(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        try await ensureChromeDebugMode()
        let result = try await sendCDP("Runtime.evaluate", params: ["expression": "history.forward()", "returnByValue": true])
        return .success(id: id, payload: ["navigated": .string("forward")])
    }

    // MARK: - Errors

    enum BrowserError: LocalizedError {
        case notRunning, noTargets, noDebugURL
        var errorDescription: String? {
            switch self {
            case .notRunning: return "Chrome not running with --remote-debugging-port=9222. Launch Chrome with: open -a 'Google Chrome' --args --remote-debugging-port=9222"
            case .noTargets: return "No browser tabs found"
            case .noDebugURL: return "No debug WebSocket URL"
            }
        }
    }
}
