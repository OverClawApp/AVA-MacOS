import Foundation
import os

/// Handles desktop_cli_gen commands — auto-generate CLI wrappers for any desktop app.
/// Uses CLI-Anything's HARNESS.md methodology. The agent IS the AI coding agent.
struct CLIGenHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "CLIGen")
    private let service = CLIAnythingService.shared

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        let params = request.params ?? [:]

        switch request.action {
        case "setup":
            return try await setup(id: request.id)
        case "harness":
            return try getHarness(id: request.id)
        case "generate":
            return try await generate(id: request.id, params: params)
        case "install_cli":
            return try await installCLI(id: request.id, params: params)
        case "list":
            return listCLIs(id: request.id)
        case "check":
            return checkApp(id: request.id, params: params)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown cli_gen action: \(request.action)")
        }
    }

    // MARK: - Setup (auto-install CLI-Anything repo)

    private func setup(id: String) async throws -> CommandResponse {
        if service.isInstalled {
            return .success(id: id, payload: [
                "installed": .bool(true),
                "path": .string(service.repoDir),
            ])
        }

        try await service.install()
        return .success(id: id, payload: [
            "installed": .bool(true),
            "path": .string(service.repoDir),
            "message": .string("CLI-Anything installed. Use 'harness' to get the generation guide."),
        ])
    }

    // MARK: - Get HARNESS.md (the generation methodology)

    private func getHarness(id: String) throws -> CommandResponse {
        if !service.isInstalled {
            try runSync {
                try await service.install()
            }
        }

        let harness = try service.readHarness()

        // Truncate if very long but keep enough for the agent to follow
        let maxLen = 30_000
        let truncated = harness.count > maxLen

        return .success(id: id, payload: [
            "harness": .string(truncated ? String(harness.prefix(maxLen)) : harness),
            "truncated": .bool(truncated),
            "instructions": .string("Follow HARNESS.md step by step. Use desktop_terminal to execute each step. Generated CLIs go in \(service.clisDir)/{app-name}/"),
        ])
    }

    // MARK: - Generate (scaffold a new CLI wrapper project)

    private func generate(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard let appName = params["app"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "app name is required")
        }

        let sanitized = appName.lowercased().replacingOccurrences(of: " ", with: "-")
        let projectDir = "\(service.clisDir)/\(sanitized)-cli"

        // Create project directory
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

        // Find the app's actual path
        let appPaths = [
            "/Applications/\(appName).app",
            "/System/Applications/\(appName).app",
            "/Applications/Utilities/\(appName).app",
        ]
        let foundPath = appPaths.first { FileManager.default.fileExists(atPath: $0) }

        // Read HARNESS.md for the agent to follow
        let harness: String
        if service.isInstalled {
            harness = (try? service.readHarness()) ?? ""
        } else {
            try await service.install()
            harness = (try? service.readHarness()) ?? ""
        }

        return .success(id: id, payload: [
            "projectDir": .string(projectDir),
            "appName": .string(appName),
            "cliName": .string("\(sanitized)-cli"),
            "appPath": .string(foundPath ?? "not found — search with `mdfind 'kMDItemKind == Application' | grep -i \(appName)`"),
            "harness": .string(String(harness.prefix(20_000))),
            "nextSteps": .string("""
                Follow HARNESS.md to generate the CLI. Use desktop_terminal to:
                1. Analyze \(appName)'s scripting capabilities (AppleScript dictionary, CLI flags, Python bindings)
                2. Design the command structure in \(projectDir)/
                3. Generate the Python Click CLI package
                4. Install with: cd \(projectDir) && pip install -e .
                5. Test with: \(sanitized)-cli --help
                """),
        ])
    }

    // MARK: - Install a generated CLI via pip

    private func installCLI(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard let cliName = params["name"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "CLI name is required")
        }

        let projectDir = "\(service.clisDir)/\(cliName)"
        guard FileManager.default.fileExists(atPath: projectDir) else {
            return .failure(id: id, code: "NOT_FOUND", message: "CLI project not found: \(cliName)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["pip", "install", "-e", projectDir]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if process.terminationStatus == 0 {
            return .success(id: id, payload: [
                "installed": .string(cliName),
                "output": .string(String(output.prefix(1000))),
            ])
        }

        return .failure(id: id, code: "INSTALL_FAILED", message: String(output.prefix(500)))
    }

    // MARK: - List generated CLIs

    private func listCLIs(id: String) -> CommandResponse {
        let clis = service.listGeneratedCLIs()
        let items = clis.map { cli -> JSONValue in
            .object([
                "name": .string(cli.name),
                "path": .string(cli.path),
                "hasSetup": .bool(cli.hasSetup),
                "installed": .bool(cli.installed),
            ])
        }

        return .success(id: id, payload: [
            "clis": .array(items),
            "count": .int(items.count),
        ])
    }

    // MARK: - Check if an app has scripting support

    private func checkApp(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let appName = params["app"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "app name is required")
        }

        // Check for AppleScript dictionary
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"\(appName)\" to count windows"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let hasAppleScript = process.terminationStatus == 0

        // Check for CLI
        let cliProcess = Process()
        cliProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        cliProcess.arguments = ["which", appName.lowercased().replacingOccurrences(of: " ", with: "-") + "-cli"]
        let cliPipe = Pipe()
        cliProcess.standardOutput = cliPipe
        try? cliProcess.run()
        cliProcess.waitUntilExit()
        let hasCLI = cliProcess.terminationStatus == 0

        return .success(id: id, payload: [
            "app": .string(appName),
            "hasAppleScript": .bool(hasAppleScript),
            "hasGeneratedCLI": .bool(hasCLI),
            "recommendation": .string(
                hasCLI ? "CLI wrapper available — use \(appName.lowercased())-cli" :
                hasAppleScript ? "AppleScript supported — generate a CLI with action 'generate'" :
                "No scripting support detected — try generating anyway, may have Python bindings"
            ),
        ])
    }

    // MARK: - Helper

    private func runSync(_ block: @escaping () async throws -> Void) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var error: Error?
        Task {
            do { try await block() }
            catch { let _ = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let error { throw error }
    }
}
