import Foundation
import os

/// Handles desktop_file commands: read, write, list, info, delete, search.
struct FileSystemHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "FileSystem")
    private let fm = FileManager.default

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        let params = request.params ?? [:]

        switch request.action {
        case "read":
            return try readFile(id: request.id, params: params)
        case "write":
            return try writeFile(id: request.id, params: params)
        case "list":
            return try listDirectory(id: request.id, params: params)
        case "info":
            return try fileInfo(id: request.id, params: params)
        case "delete":
            return try deleteFile(id: request.id, params: params)
        case "search":
            return try searchFiles(id: request.id, params: params)
        case "upload":
            return try await uploadFile(id: request.id, params: params)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown file action: \(request.action)")
        }
    }

    // MARK: - Actions

    private func readFile(id: String, params: [String: JSONValue]) throws -> CommandResponse {
        guard let path = params["path"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "path is required")
        }

        let expandedPath = NSString(string: path).expandingTildeInPath
        guard fm.fileExists(atPath: expandedPath) else {
            return .failure(id: id, code: "NOT_FOUND", message: "File not found: \(path)")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: expandedPath))

        // Check if binary
        if let content = String(data: data, encoding: .utf8) {
            // Truncate large files
            let maxLen = params["maxLength"]?.intValue ?? 100_000
            let truncated = content.count > maxLen
            let result = truncated ? String(content.prefix(maxLen)) : content

            return .success(id: id, payload: [
                "content": .string(result),
                "truncated": .bool(truncated),
                "size": .int(data.count),
            ])
        } else {
            // Binary file — return base64
            let base64 = data.base64EncodedString()
            return .success(id: id, payload: [
                "content": .string(base64),
                "encoding": .string("base64"),
                "size": .int(data.count),
            ])
        }
    }

    private func writeFile(id: String, params: [String: JSONValue]) throws -> CommandResponse {
        guard let path = params["path"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "path is required")
        }
        guard let content = params["content"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "content is required")
        }

        let expandedPath = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)

        // Create parent directories if needed
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        try content.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Wrote file: \(expandedPath)")

        return .success(id: id, payload: [
            "path": .string(expandedPath),
            "size": .int(content.utf8.count),
        ])
    }

    private func listDirectory(id: String, params: [String: JSONValue]) throws -> CommandResponse {
        guard let path = params["path"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "path is required")
        }

        let expandedPath = NSString(string: path).expandingTildeInPath
        let contents = try fm.contentsOfDirectory(atPath: expandedPath)

        let entries: [JSONValue] = try contents.prefix(200).map { name in
            let fullPath = (expandedPath as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &isDir)

            let attrs = try? fm.attributesOfItem(atPath: fullPath)
            let size = attrs?[.size] as? Int ?? 0

            return .object([
                "name": .string(name),
                "isDirectory": .bool(isDir.boolValue),
                "size": .int(size),
            ])
        }

        return .success(id: id, payload: [
            "entries": .array(entries),
            "count": .int(contents.count),
            "truncated": .bool(contents.count > 200),
        ])
    }

    private func fileInfo(id: String, params: [String: JSONValue]) throws -> CommandResponse {
        guard let path = params["path"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "path is required")
        }

        let expandedPath = NSString(string: path).expandingTildeInPath
        guard fm.fileExists(atPath: expandedPath) else {
            return .failure(id: id, code: "NOT_FOUND", message: "File not found: \(path)")
        }

        let attrs = try fm.attributesOfItem(atPath: expandedPath)
        var isDir: ObjCBool = false
        fm.fileExists(atPath: expandedPath, isDirectory: &isDir)

        return .success(id: id, payload: [
            "path": .string(expandedPath),
            "isDirectory": .bool(isDir.boolValue),
            "size": .int(attrs[.size] as? Int ?? 0),
            "modified": .string((attrs[.modificationDate] as? Date)?.ISO8601Format() ?? ""),
            "created": .string((attrs[.creationDate] as? Date)?.ISO8601Format() ?? ""),
        ])
    }

    private func deleteFile(id: String, params: [String: JSONValue]) throws -> CommandResponse {
        guard let path = params["path"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "path is required")
        }

        let expandedPath = NSString(string: path).expandingTildeInPath
        guard fm.fileExists(atPath: expandedPath) else {
            return .failure(id: id, code: "NOT_FOUND", message: "File not found: \(path)")
        }

        try fm.removeItem(atPath: expandedPath)
        logger.info("Deleted: \(expandedPath)")

        return .success(id: id, payload: ["deleted": .string(expandedPath)])
    }

    private func searchFiles(id: String, params: [String: JSONValue]) throws -> CommandResponse {
        guard let query = params["query"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "query is required")
        }
        let basePath = params["path"]?.stringValue ?? "~"
        let expandedPath = NSString(string: basePath).expandingTildeInPath
        let maxResults = params["maxResults"]?.intValue ?? 20

        // Use NSMetadataQuery for spotlight search
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", expandedPath, "-name", query]

        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let results = output.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .prefix(maxResults)
            .map { JSONValue.string($0) }

        return .success(id: id, payload: [
            "results": .array(Array(results)),
            "count": .int(results.count),
        ])
    }

    // MARK: - Upload (file → S3 → download link)

    private func uploadFile(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard let path = params["path"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "path is required")
        }

        let expandedPath = NSString(string: path).expandingTildeInPath
        guard fm.fileExists(atPath: expandedPath) else {
            return .failure(id: id, code: "NOT_FOUND", message: "File not found: \(path)")
        }

        let fileData = try Data(contentsOf: URL(fileURLWithPath: expandedPath))
        let filename = (expandedPath as NSString).lastPathComponent

        // 50MB limit
        guard fileData.count < 50_000_000 else {
            return .failure(id: id, code: "TOO_LARGE", message: "File too large (max 50MB)")
        }

        let base64 = fileData.base64EncodedString()

        // Upload to backend → S3
        guard let token = KeychainHelper.load(key: Constants.keychainAccessTokenKey) else {
            return .failure(id: id, code: "UNAUTHORIZED", message: "Not authenticated")
        }

        guard let url = URL(string: "\(Constants.apiBaseURL)/desktop/upload") else {
            return .failure(id: id, code: "INVALID_URL", message: "Invalid API URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "filename": filename,
            "data": base64,
            "contentType": mimeType(for: filename),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            return .failure(id: id, code: "UPLOAD_FAILED", message: "Upload failed (\(statusCode))")
        }

        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let downloadURL = result?["url"] as? String ?? ""

        logger.info("Uploaded \(filename) → \(downloadURL)")

        return .success(id: id, payload: [
            "url": .string(downloadURL),
            "filename": .string(filename),
            "size": .int(fileData.count),
        ])
    }

    private func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        let types: [String: String] = [
            "pdf": "application/pdf", "doc": "application/msword",
            "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "xls": "application/vnd.ms-excel",
            "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "ppt": "application/vnd.ms-powerpoint",
            "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
            "gif": "image/gif", "svg": "image/svg+xml", "webp": "image/webp",
            "mp4": "video/mp4", "mov": "video/quicktime",
            "mp3": "audio/mpeg", "wav": "audio/wav",
            "zip": "application/zip", "txt": "text/plain",
            "csv": "text/csv", "json": "application/json",
            "html": "text/html", "css": "text/css", "js": "application/javascript",
        ]
        return types[ext] ?? "application/octet-stream"
    }
}
