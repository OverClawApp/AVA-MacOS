import Foundation
import os

/// Handles desktop_code_review commands: review_pr, diff.
/// Clones/pulls repo, runs git diff, returns the diff for LLM analysis.
struct CodeReviewHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "CodeReview")
    private let fm = FileManager.default
    private let projectsDir: String = {
        let dir = NSHomeDirectory() + "/AVA-Projects"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        let params = request.params ?? [:]

        switch request.action {
        case "review_pr":
            return try await reviewPR(id: request.id, params: params)
        case "diff":
            return try await getDiff(id: request.id, params: params)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown code_review action: \(request.action)")
        }
    }

    // MARK: - Review PR

    private func reviewPR(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard let repo = params["repo"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "repo is required (owner/repo)")
        }
        guard let prNumber = params["prNumber"]?.intValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "prNumber is required")
        }

        let baseBranch = params["baseBranch"]?.stringValue ?? "main"
        let headBranch = params["headBranch"]?.stringValue

        let repoName = repo.components(separatedBy: "/").last ?? repo
        let localPath = "\(projectsDir)/\(repoName)"

        // Clone or pull
        if fm.fileExists(atPath: localPath) {
            _ = try await runGit(["fetch", "--all"], cwd: localPath)
        } else {
            _ = try await runGit(["clone", "https://github.com/\(repo).git", localPath], cwd: projectsDir)
        }

        // Checkout head branch if specified
        if let head = headBranch {
            _ = try await runGit(["checkout", head], cwd: localPath)
            _ = try await runGit(["pull", "origin", head], cwd: localPath)
        }

        // Get diff
        let diffArgs: [String]
        if let head = headBranch {
            diffArgs = ["diff", "origin/\(baseBranch)...origin/\(head)", "--stat", "--patch"]
        } else {
            diffArgs = ["diff", "origin/\(baseBranch)...HEAD", "--stat", "--patch"]
        }

        let diff = try await runGit(diffArgs, cwd: localPath)

        // Truncate if too long
        let maxLen = 50_000
        let truncated = diff.count > maxLen
        let result = truncated ? String(diff.prefix(maxLen)) : diff

        return .success(id: id, payload: [
            "repo": .string(repo),
            "prNumber": .int(prNumber),
            "baseBranch": .string(baseBranch),
            "diff": .string(result),
            "truncated": .bool(truncated),
            "diffLength": .int(diff.count),
        ])
    }

    // MARK: - Get Diff (local changes)

    private func getDiff(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard let path = params["path"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "path is required")
        }

        let expandedPath = NSString(string: path).expandingTildeInPath
        let baseBranch = params["baseBranch"]?.stringValue ?? "main"

        let diff = try await runGit(["diff", baseBranch, "--stat", "--patch"], cwd: expandedPath)

        let maxLen = 50_000
        let truncated = diff.count > maxLen

        return .success(id: id, payload: [
            "diff": .string(truncated ? String(diff.prefix(maxLen)) : diff),
            "truncated": .bool(truncated),
        ])
    }

    // MARK: - Git Helper

    private func runGit(_ args: [String], cwd: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
