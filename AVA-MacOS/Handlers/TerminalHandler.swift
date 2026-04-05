import Foundation
import os

/// Handles desktop_terminal commands: execute, shell_start, shell_send, shell_read, shell_end.
/// Supports both one-shot execution and persistent interactive shell sessions.
struct TerminalHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "Terminal")

    // Persistent shell sessions
    private static var sessions: [String: ShellSession] = [:]

    struct ShellSession {
        let id: String
        let process: Process
        let stdin: Pipe
        let stdout: Pipe
        let stderr: Pipe
        let startedAt: Date
        var output: String = ""
    }

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        let params = request.params ?? [:]

        switch request.action {
        case "execute":
            guard let command = params["command"]?.stringValue else {
                return .failure(id: request.id, code: "MISSING_PARAM", message: "command is required")
            }
            let cwd = params["cwd"]?.stringValue
            let timeout = params["timeout"]?.intValue.map(Double.init) ?? Constants.terminalDefaultTimeout
            return try await executeCommand(id: request.id, command: command, cwd: cwd, timeout: timeout)

        case "shell_start":
            return try startShell(id: request.id, params: params)
        case "shell_send":
            return sendToShell(id: request.id, params: params)
        case "shell_read":
            return readShell(id: request.id, params: params)
        case "shell_end":
            return endShell(id: request.id, params: params)
        case "shell_list":
            return listShells(id: request.id)

        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown terminal action: \(request.action)")
        }
    }

    // MARK: - One-shot Execution

    private func executeCommand(id: String, command: String, cwd: String?, timeout: TimeInterval) async throws -> CommandResponse {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: NSString(string: cwd).expandingTildeInPath)
        }

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        logger.info("Executing: \(command)")

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeout))
                if process.isRunning { process.terminate() }
            }

            do {
                try process.run()
                process.waitUntilExit()
                timeoutTask.cancel()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                var stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                var stderr = String(data: stderrData, encoding: .utf8) ?? ""

                let maxLen = Constants.terminalOutputMaxLength
                let truncated = stdout.count > maxLen || stderr.count > maxLen
                if stdout.count > maxLen { stdout = String(stdout.prefix(maxLen)) }
                if stderr.count > maxLen { stderr = String(stderr.prefix(maxLen)) }

                let exitCode = Int(process.terminationStatus)
                let timedOut = process.terminationReason == .uncaughtSignal && exitCode == 15

                var payload: [String: JSONValue] = [
                    "exitCode": .int(exitCode),
                    "stdout": .string(stdout),
                    "stderr": .string(stderr),
                    "success": .bool(exitCode == 0),
                    "truncated": .bool(truncated),
                ]
                if timedOut { payload["timedOut"] = .bool(true) }

                continuation.resume(returning: CommandResponse(
                    id: id, ok: exitCode == 0, payload: payload,
                    error: exitCode != 0 ? CommandError(code: "EXIT_\(exitCode)", message: String(stderr.prefix(500))) : nil
                ))
            } catch {
                timeoutTask.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Persistent Shell Sessions

    private func startShell(id: String, params: [String: JSONValue]) throws -> CommandResponse {
        let sessionId = UUID().uuidString.prefix(8).lowercased()
        let cwd = params["cwd"]?.stringValue
        let shell = params["shell"]?.stringValue ?? "/bin/zsh"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-i"] // Interactive

        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: NSString(string: cwd).expandingTildeInPath)
        }

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var session = ShellSession(
            id: String(sessionId),
            process: process,
            stdin: stdinPipe,
            stdout: stdoutPipe,
            stderr: stderrPipe,
            startedAt: Date()
        )

        // Capture output async
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8) {
                Self.sessions[String(sessionId)]?.output += str
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8) {
                Self.sessions[String(sessionId)]?.output += str
            }
        }

        try process.run()
        Self.sessions[String(sessionId)] = session

        logger.info("Shell session started: \(sessionId)")
        return .success(id: id, payload: [
            "sessionId": .string(String(sessionId)),
            "shell": .string(shell),
            "pid": .int(Int(process.processIdentifier)),
        ])
    }

    private func sendToShell(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let sessionId = params["sessionId"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "sessionId is required")
        }
        guard let input = params["input"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "input is required")
        }
        guard let session = Self.sessions[sessionId], session.process.isRunning else {
            return .failure(id: id, code: "NOT_FOUND", message: "Shell session not found or ended")
        }

        if let data = (input + "\n").data(using: .utf8) {
            session.stdin.fileHandleForWriting.write(data)
        }

        return .success(id: id, payload: ["sent": .string(input)])
    }

    private func readShell(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let sessionId = params["sessionId"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "sessionId is required")
        }
        guard let session = Self.sessions[sessionId] else {
            return .failure(id: id, code: "NOT_FOUND", message: "Shell session not found")
        }

        let output = session.output
        // Clear read output
        Self.sessions[sessionId]?.output = ""

        let maxLen = Constants.terminalOutputMaxLength
        return .success(id: id, payload: [
            "output": .string(String(output.suffix(maxLen))),
            "running": .bool(session.process.isRunning),
            "truncated": .bool(output.count > maxLen),
        ])
    }

    private func endShell(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let sessionId = params["sessionId"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "sessionId is required")
        }
        guard let session = Self.sessions[sessionId] else {
            return .failure(id: id, code: "NOT_FOUND", message: "Shell session not found")
        }

        session.process.terminate()
        Self.sessions.removeValue(forKey: sessionId)

        return .success(id: id, payload: ["ended": .string(sessionId)])
    }

    private func listShells(id: String) -> CommandResponse {
        let list = Self.sessions.values.map { session -> JSONValue in
            .object([
                "sessionId": .string(session.id),
                "running": .bool(session.process.isRunning),
                "pid": .int(Int(session.process.processIdentifier)),
                "uptime": .double(Date().timeIntervalSince(session.startedAt)),
            ])
        }

        return .success(id: id, payload: [
            "sessions": .array(list),
            "count": .int(list.count),
        ])
    }
}
