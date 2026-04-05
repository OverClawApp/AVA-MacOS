import Foundation
import os

/// Handles desktop_codebase commands: index, search, get_context, import_repo.
/// Provides deep repo understanding for AI agents.
struct CodebaseHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "Codebase")
    private let indexer = CodebaseIndexer.shared

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        let params = request.params ?? [:]

        switch request.action {
        case "index":
            return try await indexProject(id: request.id, params: params)
        case "search":
            return searchCode(id: request.id, params: params)
        case "get_context":
            return try getContext(id: request.id, params: params)
        case "import_repo":
            return try await importRepo(id: request.id, params: params)
        case "list_projects":
            return listProjects(id: request.id)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown codebase action: \(request.action)")
        }
    }

    // MARK: - Index

    private func indexProject(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard let path = params["path"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "path is required")
        }

        let expandedPath = NSString(string: path).expandingTildeInPath
        let index = try await indexer.indexProject(at: expandedPath)

        return .success(id: id, payload: [
            "path": .string(expandedPath),
            "fileCount": .int(index.files.count),
            "symbolCount": .int(index.files.reduce(0) { $0 + $1.symbols.count }),
            "languages": .array(Array(Set(index.files.compactMap { $0.language })).map { .string($0) }),
        ])
    }

    // MARK: - Search

    private func searchCode(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let query = params["query"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "query is required")
        }

        let projectPath = params["path"]?.stringValue
        let results = indexer.search(query: query, projectPath: projectPath)
        let maxResults = params["maxResults"]?.intValue ?? 20

        let matches: [JSONValue] = results.prefix(maxResults).map { result in
            .object([
                "file": .string(result.file),
                "symbol": .string(result.symbol),
                "type": .string(result.type),
                "line": .int(result.line),
                "score": .double(result.score),
            ])
        }

        return .success(id: id, payload: [
            "results": .array(matches),
            "count": .int(matches.count),
        ])
    }

    // MARK: - Get Context

    private func getContext(id: String, params: [String: JSONValue]) throws -> CommandResponse {
        guard let files = params["files"]?.arrayValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "files array is required")
        }

        var contexts: [JSONValue] = []
        for file in files {
            guard let path = file.stringValue else { continue }
            let expandedPath = NSString(string: path).expandingTildeInPath
            guard let content = try? String(contentsOfFile: expandedPath, encoding: .utf8) else { continue }

            let maxLen = 20_000
            let truncated = content.count > maxLen
            contexts.append(.object([
                "path": .string(path),
                "content": .string(truncated ? String(content.prefix(maxLen)) : content),
                "truncated": .bool(truncated),
            ]))
        }

        return .success(id: id, payload: [
            "files": .array(contexts),
            "count": .int(contexts.count),
        ])
    }

    // MARK: - Import Repo

    private func importRepo(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard let url = params["url"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "url is required")
        }

        let branch = params["branch"]?.stringValue ?? "main"
        let projectsDir = NSHomeDirectory() + "/AVA-Projects"
        try FileManager.default.createDirectory(atPath: projectsDir, withIntermediateDirectories: true)

        // Extract repo name
        let repoName = url.components(separatedBy: "/").last?.replacingOccurrences(of: ".git", with: "") ?? "project"
        let localPath = "\(projectsDir)/\(repoName)"

        // Clone
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")

        if FileManager.default.fileExists(atPath: localPath) {
            process.arguments = ["pull", "origin", branch]
            process.currentDirectoryURL = URL(fileURLWithPath: localPath)
        } else {
            process.arguments = ["clone", "--branch", branch, url, localPath]
            process.currentDirectoryURL = URL(fileURLWithPath: projectsDir)
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return .failure(id: id, code: "CLONE_FAILED", message: stderr.prefix(500).description)
        }

        // Auto-index
        let index = try await indexer.indexProject(at: localPath)

        return .success(id: id, payload: [
            "path": .string(localPath),
            "repo": .string(url),
            "branch": .string(branch),
            "fileCount": .int(index.files.count),
            "symbolCount": .int(index.files.reduce(0) { $0 + $1.symbols.count }),
        ])
    }

    // MARK: - List Projects

    private func listProjects(id: String) -> CommandResponse {
        let projects = indexer.listIndexedProjects().map { project -> JSONValue in
            .object([
                "path": .string(project.path),
                "fileCount": .int(project.fileCount),
                "lastIndexed": .string(project.lastIndexed.ISO8601Format()),
            ])
        }

        return .success(id: id, payload: [
            "projects": .array(projects),
            "count": .int(projects.count),
        ])
    }
}
