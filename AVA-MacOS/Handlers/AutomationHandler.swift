import Foundation
import AppKit
import os

/// Handles desktop_automation commands — autonomous computer use loop.
/// Agent-S pattern: screenshot → analyze → act → observe → repeat until done.
/// The agent enters a self-directed loop, taking actions and checking results.
struct AutomationHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "Automation")

    // Active automation sessions
    private static var activeSessions: [String: AutomationSession] = [:]

    struct AutomationSession {
        let id: String
        let task: String
        var steps: [AutomationStep] = []
        var status: String = "running" // running, paused, completed, failed
        let startedAt: Date
        var maxSteps: Int
    }

    struct AutomationStep {
        let screenshot: Data?
        let observation: String
        let action: String
        let result: String
        let timestamp: Date
    }

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        let params = request.params ?? [:]

        switch request.action {
        case "start":
            return startSession(id: request.id, params: params)
        case "step":
            return try await executeStep(id: request.id, params: params)
        case "observe":
            return try await observe(id: request.id, params: params)
        case "status":
            return sessionStatus(id: request.id, params: params)
        case "complete":
            return completeSession(id: request.id, params: params)
        case "fail":
            return failSession(id: request.id, params: params)
        case "history":
            return sessionHistory(id: request.id, params: params)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown automation action: \(request.action)")
        }
    }

    // MARK: - Start Session

    private func startSession(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let task = params["task"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "task description is required")
        }

        let sessionId = UUID().uuidString.prefix(8).lowercased()
        let maxSteps = params["maxSteps"]?.intValue ?? 15

        let session = AutomationSession(
            id: String(sessionId),
            task: task,
            startedAt: Date(),
            maxSteps: maxSteps
        )

        Self.activeSessions[String(sessionId)] = session
        logger.info("Automation session started: \(sessionId) — \(task)")

        return .success(id: id, payload: [
            "sessionId": .string(String(sessionId)),
            "task": .string(task),
            "maxSteps": .int(maxSteps),
            "instructions": .string("""
                Autonomous loop: Use 'observe' to take a screenshot and analyze the current state, \
                then use other desktop_* tools to act. After each action, 'observe' again to verify the result. \
                Call 'complete' when the task is done, or 'fail' if you can't proceed.
                """),
        ])
    }

    // MARK: - Observe (screenshot + return for analysis)

    private func observe(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        let sessionId = params["sessionId"]?.stringValue

        // Take screenshot
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return .permissionMissing(id: id, permission: "Screen Recording")
        }

        let tempFile = NSTemporaryDirectory() + "ava_auto_\(UUID().uuidString).png"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-C", tempFile]
        try process.run()
        process.waitUntilExit()

        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        guard process.terminationStatus == 0,
              let imageData = try? Data(contentsOf: URL(fileURLWithPath: tempFile)) else {
            return .failure(id: id, code: "CAPTURE_FAILED", message: "Screenshot failed")
        }

        let base64 = imageData.base64EncodedString()

        // Get frontmost app info
        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? "Unknown"

        // Get mouse position
        let mousePos = NSEvent.mouseLocation

        // Record step if in a session
        if let sessionId, var session = Self.activeSessions[sessionId] {
            let step = AutomationStep(
                screenshot: nil, // Don't store full images in memory
                observation: "Screenshot taken — \(appName) active",
                action: "observe",
                result: "Ready for analysis",
                timestamp: Date()
            )
            session.steps.append(step)

            // Check step limit
            if session.steps.count >= session.maxSteps {
                session.status = "max_steps_reached"
                Self.activeSessions[sessionId] = session
                return .success(id: id, payload: [
                    "screenshot": .string(base64),
                    "encoding": .string("base64"),
                    "frontApp": .string(appName),
                    "mouseX": .int(Int(mousePos.x)),
                    "mouseY": .int(Int(mousePos.y)),
                    "stepNumber": .int(session.steps.count),
                    "maxSteps": .int(session.maxSteps),
                    "warning": .string("Maximum steps reached. Call 'complete' or 'fail'."),
                ])
            }

            Self.activeSessions[sessionId] = session
        }

        return .success(id: id, payload: [
            "screenshot": .string(base64),
            "encoding": .string("base64"),
            "format": .string("png"),
            "frontApp": .string(appName),
            "mouseX": .int(Int(mousePos.x)),
            "mouseY": .int(Int(NSScreen.main!.frame.height - mousePos.y)), // Convert to top-left origin
            "size": .int(imageData.count),
        ])
    }

    // MARK: - Execute Step (record an action taken)

    private func executeStep(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard let sessionId = params["sessionId"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "sessionId is required")
        }
        guard var session = Self.activeSessions[sessionId] else {
            return .failure(id: id, code: "NOT_FOUND", message: "Session not found")
        }

        let action = params["action_taken"]?.stringValue ?? "unknown"
        let result = params["result"]?.stringValue ?? ""

        let step = AutomationStep(
            screenshot: nil,
            observation: "",
            action: action,
            result: result,
            timestamp: Date()
        )
        session.steps.append(step)
        Self.activeSessions[sessionId] = session

        return .success(id: id, payload: [
            "recorded": .bool(true),
            "stepNumber": .int(session.steps.count),
            "stepsRemaining": .int(session.maxSteps - session.steps.count),
        ])
    }

    // MARK: - Session Management

    private func sessionStatus(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let sessionId = params["sessionId"]?.stringValue,
              let session = Self.activeSessions[sessionId] else {
            return .failure(id: id, code: "NOT_FOUND", message: "Session not found")
        }

        return .success(id: id, payload: [
            "sessionId": .string(session.id),
            "task": .string(session.task),
            "status": .string(session.status),
            "steps": .int(session.steps.count),
            "maxSteps": .int(session.maxSteps),
            "elapsed": .double(Date().timeIntervalSince(session.startedAt)),
        ])
    }

    private func completeSession(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let sessionId = params["sessionId"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "sessionId is required")
        }

        var session = Self.activeSessions[sessionId]
        session?.status = "completed"
        if let s = session { Self.activeSessions[sessionId] = s }

        let summary = params["summary"]?.stringValue ?? "Task completed"

        logger.info("Automation completed: \(sessionId) in \(session?.steps.count ?? 0) steps")

        return .success(id: id, payload: [
            "completed": .bool(true),
            "steps": .int(session?.steps.count ?? 0),
            "summary": .string(summary),
        ])
    }

    private func failSession(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let sessionId = params["sessionId"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "sessionId is required")
        }

        var session = Self.activeSessions[sessionId]
        session?.status = "failed"
        if let s = session { Self.activeSessions[sessionId] = s }

        let reason = params["reason"]?.stringValue ?? "Unknown"

        return .success(id: id, payload: [
            "failed": .bool(true),
            "reason": .string(reason),
            "steps": .int(session?.steps.count ?? 0),
        ])
    }

    private func sessionHistory(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let sessionId = params["sessionId"]?.stringValue,
              let session = Self.activeSessions[sessionId] else {
            return .failure(id: id, code: "NOT_FOUND", message: "Session not found")
        }

        let steps = session.steps.map { step -> JSONValue in
            .object([
                "action": .string(step.action),
                "result": .string(step.result),
                "timestamp": .string(step.timestamp.ISO8601Format()),
            ])
        }

        return .success(id: id, payload: [
            "task": .string(session.task),
            "status": .string(session.status),
            "steps": .array(steps),
        ])
    }
}
