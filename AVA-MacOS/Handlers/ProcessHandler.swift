import Foundation
import os

/// Handles desktop_process commands — spawn, monitor, kill, and interact with background processes.
struct ProcessHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "Process")

    // Active background processes
    private static var processes: [String: ManagedProcess] = [:]

    struct ManagedProcess {
        let id: String
        let command: String
        let process: Process
        let stdout: Pipe
        let stderr: Pipe
        let startedAt: Date
        var output: String = ""
    }

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        let params = request.params ?? [:]

        switch request.action {
        case "spawn":
            return try spawn(id: request.id, params: params)
        case "list":
            return listProcesses(id: request.id)
        case "read_output":
            return readOutput(id: request.id, params: params)
        case "write_stdin":
            return writeStdin(id: request.id, params: params)
        case "kill":
            return killProcess(id: request.id, params: params)
        case "wait":
            return await waitForProcess(id: request.id, params: params)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown process action: \(request.action)")
        }
    }

    // MARK: - Spawn

    private func spawn(id: String, params: [String: JSONValue]) throws -> CommandResponse {
        guard let command = params["command"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "command is required")
        }

        let processId = UUID().uuidString.prefix(8).lowercased()
        let cwd = params["cwd"]?.stringValue

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
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        var managed = ManagedProcess(
            id: String(processId),
            command: command,
            process: process,
            stdout: stdoutPipe,
            stderr: stderrPipe,
            startedAt: Date()
        )

        // Capture output asynchronously
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8) {
                Self.processes[String(processId)]?.output += str
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8) {
                Self.processes[String(processId)]?.output += str
            }
        }

        try process.run()
        Self.processes[String(processId)] = managed

        logger.info("Spawned process \(processId): \(command)")
        return .success(id: id, payload: [
            "processId": .string(String(processId)),
            "pid": .int(Int(process.processIdentifier)),
            "command": .string(command),
        ])
    }

    // MARK: - List

    private func listProcesses(id: String) -> CommandResponse {
        let list = Self.processes.values.map { proc -> JSONValue in
            .object([
                "processId": .string(proc.id),
                "command": .string(proc.command),
                "running": .bool(proc.process.isRunning),
                "pid": .int(Int(proc.process.processIdentifier)),
                "uptime": .double(Date().timeIntervalSince(proc.startedAt)),
            ])
        }

        return .success(id: id, payload: [
            "processes": .array(list),
            "count": .int(list.count),
        ])
    }

    // MARK: - Read Output

    private func readOutput(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let processId = params["processId"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "processId is required")
        }

        guard let proc = Self.processes[processId] else {
            return .failure(id: id, code: "NOT_FOUND", message: "Process not found: \(processId)")
        }

        let output = proc.output
        let maxLen = Constants.terminalOutputMaxLength
        let truncated = output.count > maxLen

        return .success(id: id, payload: [
            "output": .string(truncated ? String(output.suffix(maxLen)) : output),
            "running": .bool(proc.process.isRunning),
            "truncated": .bool(truncated),
        ])
    }

    // MARK: - Write stdin

    private func writeStdin(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let processId = params["processId"]?.stringValue,
              let input = params["input"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "processId and input are required")
        }

        guard let proc = Self.processes[processId], proc.process.isRunning else {
            return .failure(id: id, code: "NOT_FOUND", message: "Process not running: \(processId)")
        }

        let stdinPipe = proc.process.standardInput as? Pipe
        if let data = (input + "\n").data(using: .utf8) {
            stdinPipe?.fileHandleForWriting.write(data)
        }

        return .success(id: id, payload: ["written": .string(input)])
    }

    // MARK: - Kill

    private func killProcess(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let processId = params["processId"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "processId is required")
        }

        guard let proc = Self.processes[processId] else {
            return .failure(id: id, code: "NOT_FOUND", message: "Process not found: \(processId)")
        }

        let force = params["force"]?.boolValue ?? false
        if force {
            kill(proc.process.processIdentifier, SIGKILL)
        } else {
            proc.process.terminate()
        }

        Self.processes.removeValue(forKey: processId)
        return .success(id: id, payload: ["killed": .string(processId)])
    }

    // MARK: - Wait

    private func waitForProcess(id: String, params: [String: JSONValue]) async -> CommandResponse {
        guard let processId = params["processId"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "processId is required")
        }

        guard let proc = Self.processes[processId] else {
            return .failure(id: id, code: "NOT_FOUND", message: "Process not found: \(processId)")
        }

        let timeout = params["timeout"]?.intValue ?? 30

        // Wait for process to finish or timeout
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while proc.process.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }

        let output = Self.processes[processId]?.output ?? ""
        let exitCode = proc.process.isRunning ? -1 : Int(proc.process.terminationStatus)

        if !proc.process.isRunning {
            Self.processes.removeValue(forKey: processId)
        }

        return .success(id: id, payload: [
            "exitCode": .int(exitCode),
            "running": .bool(proc.process.isRunning),
            "output": .string(String(output.suffix(Constants.terminalOutputMaxLength))),
        ])
    }
}
