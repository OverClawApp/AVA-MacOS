import Foundation
import os

/// Handles desktop_mcp commands — list installed MCP servers, list their tools, call tools.
/// MCP servers run as local processes speaking JSON-RPC over stdin/stdout.
struct MCPHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "MCP")

    private let configPath: String = {
        let dir = NSHomeDirectory() + "/Library/Application Support/AVA-Desktop"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/mcp-servers.json"
    }()

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        let params = request.params ?? [:]

        switch request.action {
        case "list_servers":
            return listServers(id: request.id)
        case "list_tools":
            return try await listTools(id: request.id, params: params)
        case "call_tool":
            return try await callTool(id: request.id, params: params)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown mcp action: \(request.action)")
        }
    }

    // MARK: - List Servers

    private func listServers(id: String) -> CommandResponse {
        let servers = loadConfig()
        let items = servers.map { server -> JSONValue in
            .object([
                "name": .string(server.name),
                "command": .string(server.command),
                "slug": .string(server.slug),
            ])
        }
        return .success(id: id, payload: [
            "servers": .array(items),
            "count": .int(items.count),
        ])
    }

    // MARK: - List Tools (initialize server, call tools/list)

    private func listTools(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard let serverName = params["server"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "server name is required")
        }

        let servers = loadConfig()
        guard let server = servers.first(where: { $0.name.localizedCaseInsensitiveContains(serverName) || $0.slug == serverName }) else {
            return .failure(id: id, code: "NOT_FOUND", message: "MCP server not found: \(serverName)")
        }

        // Start the MCP server process and send initialize + tools/list
        let result = try await sendMCPRequest(command: server.command, method: "tools/list", params: [:])

        guard let tools = result["tools"] as? [[String: Any]] else {
            return .failure(id: id, code: "MCP_ERROR", message: "Failed to list tools from \(serverName)")
        }

        let toolList = tools.map { tool -> JSONValue in
            .object([
                "name": .string(tool["name"] as? String ?? ""),
                "description": .string(tool["description"] as? String ?? ""),
            ])
        }

        return .success(id: id, payload: [
            "server": .string(server.name),
            "tools": .array(toolList),
            "count": .int(toolList.count),
        ])
    }

    // MARK: - Call Tool

    private func callTool(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard let serverName = params["server"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "server name is required")
        }
        guard let toolName = params["tool"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "tool name is required")
        }

        let servers = loadConfig()
        guard let server = servers.first(where: { $0.name.localizedCaseInsensitiveContains(serverName) || $0.slug == serverName }) else {
            return .failure(id: id, code: "NOT_FOUND", message: "MCP server not found: \(serverName)")
        }

        // Convert args from JSONValue to [String: Any]
        var toolArgs: [String: Any] = [:]
        if let argsObj = params["args"]?.objectValue {
            for (key, value) in argsObj {
                switch value {
                case .string(let s): toolArgs[key] = s
                case .int(let i): toolArgs[key] = i
                case .double(let d): toolArgs[key] = d
                case .bool(let b): toolArgs[key] = b
                default: toolArgs[key] = "\(value)"
                }
            }
        }

        let result = try await sendMCPRequest(
            command: server.command,
            method: "tools/call",
            params: ["name": toolName, "arguments": toolArgs]
        )

        // Format result
        let content = result["content"] as? [[String: Any]]
        let textParts = content?.compactMap { $0["text"] as? String } ?? []
        let output = textParts.joined(separator: "\n")

        return .success(id: id, payload: [
            "server": .string(server.name),
            "tool": .string(toolName),
            "result": .string(String(output.prefix(50_000))),
        ])
    }

    // MARK: - MCP JSON-RPC over stdin/stdout

    private func sendMCPRequest(command: String, method: String, params: [String: Any]) async throws -> [String: Any] {
        let parts = command.components(separatedBy: " ")
        guard let executable = parts.first else {
            throw MCPError.invalidCommand
        }

        let process = Process()

        // Handle npx/uvx commands
        if executable == "npx" || executable == "uvx" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = parts
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = parts
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        process.environment = env

        try process.run()

        // Send initialize request
        let initRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "ava-desktop", "version": "1.0.0"],
            ] as [String: Any],
        ]

        let initData = try JSONSerialization.data(withJSONObject: initRequest)
        stdinPipe.fileHandleForWriting.write(initData)
        stdinPipe.fileHandleForWriting.write("\n".data(using: .utf8)!)

        // Wait briefly for init
        try await Task.sleep(for: .milliseconds(500))

        // Send initialized notification
        let initializedNotif: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ]
        let notifData = try JSONSerialization.data(withJSONObject: initializedNotif)
        stdinPipe.fileHandleForWriting.write(notifData)
        stdinPipe.fileHandleForWriting.write("\n".data(using: .utf8)!)

        // Send the actual request
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": method,
            "params": params,
        ]

        let requestData = try JSONSerialization.data(withJSONObject: request)
        stdinPipe.fileHandleForWriting.write(requestData)
        stdinPipe.fileHandleForWriting.write("\n".data(using: .utf8)!)

        // Read response (wait up to 10s)
        try await Task.sleep(for: .seconds(2))

        let outputData = stdoutPipe.fileHandleForReading.availableData
        process.terminate()

        // Parse the last JSON-RPC response
        let outputStr = String(data: outputData, encoding: .utf8) ?? ""
        let lines = outputStr.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Find the response to our request (id: 2)
        for line in lines.reversed() {
            if let lineData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               (json["id"] as? Int) == 2,
               let result = json["result"] as? [String: Any] {
                return result
            }
        }

        return [:]
    }

    // MARK: - Config

    struct MCPServerConfig: Codable {
        let name: String
        let command: String
        let slug: String
    }

    private func loadConfig() -> [MCPServerConfig] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let servers = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
            return []
        }
        return servers
    }

    enum MCPError: LocalizedError {
        case invalidCommand
        var errorDescription: String? { "Invalid MCP server command" }
    }
}
