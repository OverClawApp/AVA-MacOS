import Foundation
import os

/// Handles desktop_watch commands — monitor directories for changes, trigger agent actions.
struct FileWatchHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "FileWatch")
    static let watcher = FileWatcher()

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        let params = request.params ?? [:]

        switch request.action {
        case "watch":
            return watchPath(id: request.id, params: params)
        case "unwatch":
            return unwatchPath(id: request.id, params: params)
        case "list":
            return listWatched(id: request.id)
        case "events":
            return recentEvents(id: request.id, params: params)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown watch action: \(request.action)")
        }
    }

    private func watchPath(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let path = params["path"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "path is required")
        }
        Self.watcher.watch(path: path)
        return .success(id: id, payload: [
            "watching": .string(NSString(string: path).expandingTildeInPath),
        ])
    }

    private func unwatchPath(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let path = params["path"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "path is required")
        }
        Self.watcher.unwatch(path: path)
        return .success(id: id, payload: ["unwatched": .string(path)])
    }

    private func listWatched(id: String) -> CommandResponse {
        let paths = Self.watcher.watchedPaths.map { JSONValue.string($0) }
        return .success(id: id, payload: [
            "watching": .array(paths),
            "count": .int(paths.count),
        ])
    }

    private func recentEvents(id: String, params: [String: JSONValue]) -> CommandResponse {
        let limit = params["limit"]?.intValue ?? 20
        let events = Self.watcher.recentEvents.prefix(limit).map { event -> JSONValue in
            .object([
                "path": .string(event.path),
                "event": .string(event.description),
                "timestamp": .string(event.timestamp.ISO8601Format()),
            ])
        }
        return .success(id: id, payload: [
            "events": .array(events),
            "count": .int(events.count),
        ])
    }
}
