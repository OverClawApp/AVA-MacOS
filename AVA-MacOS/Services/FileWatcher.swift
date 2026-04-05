import Foundation
import os

/// FSEvents-based file watcher — monitors directories and notifies the agent when files change.
/// Enables proactive actions: "your build just failed", "new file on Desktop", etc.
@Observable
final class FileWatcher {
    private let logger = Logger(subsystem: Constants.bundleID, category: "FileWatcher")

    private var streams: [String: FSEventStreamRef] = [:]
    private(set) var watchedPaths: [String] = []
    private(set) var recentEvents: [FileEvent] = []

    /// Called when a file event is detected — sends to backend for agent processing
    var onEvent: ((FileEvent) -> Void)?

    struct FileEvent: Identifiable {
        let id = UUID()
        let path: String
        let flags: FSEventStreamEventFlags
        let timestamp: Date

        var description: String {
            var parts: [String] = []
            if flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 { parts.append("created") }
            if flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 { parts.append("deleted") }
            if flags & UInt32(kFSEventStreamEventFlagItemModified) != 0 { parts.append("modified") }
            if flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 { parts.append("renamed") }
            if parts.isEmpty { parts.append("changed") }
            return parts.joined(separator: ", ")
        }
    }

    // MARK: - Watch / Unwatch

    func watch(path: String) {
        let expandedPath = NSString(string: path).expandingTildeInPath

        guard streams[expandedPath] == nil else {
            logger.info("Already watching: \(expandedPath)")
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathsToWatch = [expandedPath] as CFArray

        guard let stream = FSEventStreamCreate(
            nil,
            { (streamRef, info, numEvents, eventPaths, eventFlags, eventIds) in
                guard let info else { return }
                let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
                let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)

                for i in 0..<numEvents {
                    let event = FileEvent(
                        path: paths[i],
                        flags: flags[i],
                        timestamp: Date()
                    )
                    DispatchQueue.main.async {
                        watcher.recentEvents.insert(event, at: 0)
                        if watcher.recentEvents.count > 100 {
                            watcher.recentEvents = Array(watcher.recentEvents.prefix(100))
                        }
                        watcher.onEvent?(event)
                    }
                }
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // 1 second latency
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            logger.error("Failed to create FSEvent stream for \(expandedPath)")
            return
        }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)

        streams[expandedPath] = stream
        watchedPaths.append(expandedPath)
        logger.info("Watching: \(expandedPath)")
    }

    func unwatch(path: String) {
        let expandedPath = NSString(string: path).expandingTildeInPath

        guard let stream = streams[expandedPath] else { return }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)

        streams.removeValue(forKey: expandedPath)
        watchedPaths.removeAll { $0 == expandedPath }
        logger.info("Stopped watching: \(expandedPath)")
    }

    func unwatchAll() {
        for path in Array(streams.keys) {
            unwatch(path: path)
        }
    }

    deinit {
        unwatchAll()
    }
}
