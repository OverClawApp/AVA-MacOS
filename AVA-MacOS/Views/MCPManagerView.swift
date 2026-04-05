import SwiftUI

/// One-click MCP server installation and management.
struct MCPManagerView: View {
    @State private var servers: [MCPServer] = MCPServer.curated
    @State private var installingId: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP Servers")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.navy)
                    Text("Extend your agents with tools")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.navy.opacity(0.5))
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.navy.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(servers) { server in
                        serverRow(server)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 450, height: 500)
        .background(.white)
        .onAppear { loadInstalledState() }
    }

    private func serverRow(_ server: MCPServer) -> some View {
        HStack(spacing: 12) {
            Text(server.icon)
                .font(.system(size: 24))
                .frame(width: 40, height: 40)
                .background(Color.navy.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.navy)
                Text(server.description)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.navy.opacity(0.5))
                    .lineLimit(2)
            }

            Spacer()

            if server.isInstalled {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.avaGreen)
            } else if installingId == server.id {
                ProgressView().controlSize(.small)
            } else {
                Button("Install") {
                    installServer(server)
                }
                .buttonStyle(AVAPrimaryButtonStyle())
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.navy.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func installServer(_ server: MCPServer) {
        installingId = server.id
        Task {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = server.installCommand.components(separatedBy: " ")

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    // Update config
                    saveMCPConfig(server)
                    if let idx = servers.firstIndex(where: { $0.id == server.id }) {
                        servers[idx].isInstalled = true
                    }
                }
            } catch {
                // Install failed
            }
            installingId = nil
        }
    }

    private func saveMCPConfig(_ server: MCPServer) {
        let configDir = NSHomeDirectory() + "/Library/Application Support/AVA-Desktop"
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        let configPath = configDir + "/mcp-servers.json"

        var config: [[String: String]] = []
        if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            config = existing
        }

        config.append([
            "name": server.name,
            "command": server.installCommand,
            "slug": server.id,
        ])

        if let data = try? JSONSerialization.data(withJSONObject: config, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
    }

    private func loadInstalledState() {
        let configPath = NSHomeDirectory() + "/Library/Application Support/AVA-Desktop/mcp-servers.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let installed = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return }

        let installedSlugs = Set(installed.compactMap { $0["slug"] })
        for i in servers.indices {
            servers[i].isInstalled = installedSlugs.contains(servers[i].id)
        }
    }
}

// MARK: - MCP Server Model

struct MCPServer: Identifiable {
    let id: String
    let name: String
    let description: String
    let icon: String
    let installCommand: String
    var isInstalled: Bool = false

    static let curated: [MCPServer] = [
        MCPServer(id: "filesystem", name: "Filesystem", description: "Read, write, and manage local files", icon: "📁", installCommand: "npx -y @modelcontextprotocol/server-filesystem"),
        MCPServer(id: "github", name: "GitHub", description: "Repos, issues, PRs, and code search", icon: "🐙", installCommand: "npx -y @modelcontextprotocol/server-github"),
        MCPServer(id: "slack", name: "Slack", description: "Messages, channels, and workspace search", icon: "💬", installCommand: "npx -y @modelcontextprotocol/server-slack"),
        MCPServer(id: "google-drive", name: "Google Drive", description: "Docs, sheets, and file management", icon: "📄", installCommand: "npx -y @anthropic/server-google-drive"),
        MCPServer(id: "postgres", name: "PostgreSQL", description: "Query and manage databases", icon: "🐘", installCommand: "npx -y @modelcontextprotocol/server-postgres"),
        MCPServer(id: "playwright", name: "Browser", description: "Web automation with Playwright", icon: "🌐", installCommand: "npx -y @anthropic/server-playwright"),
        MCPServer(id: "memory", name: "Memory", description: "Persistent key-value storage", icon: "🧠", installCommand: "npx -y @modelcontextprotocol/server-memory"),
        MCPServer(id: "sqlite", name: "SQLite", description: "Local SQLite database access", icon: "💾", installCommand: "npx -y @modelcontextprotocol/server-sqlite"),
    ]
}
