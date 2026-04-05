import Foundation
import AppKit
import IOKit.ps
import os

/// Handles desktop_system commands: info, processes, battery, disk, displays, windows.
/// Matches system introspection capabilities found in Hermes Agent & OpenClaw.
struct SystemHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "System")

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        switch request.action {
        case "info":
            return systemInfo(id: request.id)
        case "processes":
            return listProcesses(id: request.id, params: request.params ?? [:])
        case "battery":
            return batteryInfo(id: request.id)
        case "disk":
            return diskInfo(id: request.id)
        case "displays":
            return displayInfo(id: request.id)
        case "windows":
            return listWindows(id: request.id)
        case "frontmost":
            return frontmostApp(id: request.id)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown system action: \(request.action)")
        }
    }

    // MARK: - System Info

    private func systemInfo(id: String) -> CommandResponse {
        let info = ProcessInfo.processInfo
        let osVersion = info.operatingSystemVersionString

        return .success(id: id, payload: [
            "hostname": .string(Host.current().localizedName ?? "Mac"),
            "osVersion": .string(osVersion),
            "processorCount": .int(info.processorCount),
            "activeProcessorCount": .int(info.activeProcessorCount),
            "physicalMemoryGB": .double(Double(info.physicalMemory) / 1_073_741_824),
            "systemUptime": .double(info.systemUptime),
            "userName": .string(NSUserName()),
            "homeDirectory": .string(NSHomeDirectory()),
        ])
    }

    // MARK: - Processes

    private func listProcesses(id: String, params: [String: JSONValue]) -> CommandResponse {
        let apps = NSWorkspace.shared.runningApplications
        let filter = params["filter"]?.stringValue

        let processes: [JSONValue] = apps
            .filter { app in
                guard let name = app.localizedName else { return false }
                if let filter { return name.localizedCaseInsensitiveContains(filter) }
                return app.activationPolicy == .regular || app.activationPolicy == .accessory
            }
            .prefix(50)
            .map { app in
                .object([
                    "name": .string(app.localizedName ?? ""),
                    "bundleId": .string(app.bundleIdentifier ?? ""),
                    "pid": .int(Int(app.processIdentifier)),
                    "isActive": .bool(app.isActive),
                    "isHidden": .bool(app.isHidden),
                    "activationPolicy": .string(app.activationPolicy == .regular ? "regular" : "accessory"),
                ])
            }

        return .success(id: id, payload: [
            "processes": .array(processes),
            "count": .int(processes.count),
        ])
    }

    // MARK: - Battery

    private func batteryInfo(id: String) -> CommandResponse {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first as CFTypeRef)?.takeUnretainedValue() as? [String: Any] else {
            return .success(id: id, payload: [
                "hasBattery": .bool(false),
                "isDesktop": .bool(true),
            ])
        }

        let capacity = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maxCapacity = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
        let powerSource = desc[kIOPSPowerSourceStateKey] as? String ?? "Unknown"
        let timeToEmpty = desc[kIOPSTimeToEmptyKey] as? Int
        let timeToFull = desc[kIOPSTimeToFullChargeKey] as? Int

        var payload: [String: JSONValue] = [
            "hasBattery": .bool(true),
            "percentage": .int(capacity * 100 / max(maxCapacity, 1)),
            "isCharging": .bool(isCharging),
            "powerSource": .string(powerSource),
        ]

        if let tte = timeToEmpty, tte > 0 { payload["minutesRemaining"] = .int(tte) }
        if let ttf = timeToFull, ttf > 0 { payload["minutesToFull"] = .int(ttf) }

        return .success(id: id, payload: payload)
    }

    // MARK: - Disk

    private func diskInfo(id: String) -> CommandResponse {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory()) else {
            return .failure(id: id, code: "DISK_ERROR", message: "Could not read disk info")
        }

        let totalBytes = attrs[.systemSize] as? Int64 ?? 0
        let freeBytes = attrs[.systemFreeSize] as? Int64 ?? 0
        let usedBytes = totalBytes - freeBytes

        return .success(id: id, payload: [
            "totalGB": .double(Double(totalBytes) / 1_073_741_824),
            "freeGB": .double(Double(freeBytes) / 1_073_741_824),
            "usedGB": .double(Double(usedBytes) / 1_073_741_824),
            "usedPercent": .int(totalBytes > 0 ? Int(usedBytes * 100 / totalBytes) : 0),
        ])
    }

    // MARK: - Displays

    private func displayInfo(id: String) -> CommandResponse {
        let screens = NSScreen.screens.enumerated().map { (index, screen) -> JSONValue in
            let frame = screen.frame
            let visibleFrame = screen.visibleFrame
            return .object([
                "index": .int(index),
                "width": .int(Int(frame.width)),
                "height": .int(Int(frame.height)),
                "visibleWidth": .int(Int(visibleFrame.width)),
                "visibleHeight": .int(Int(visibleFrame.height)),
                "isMain": .bool(screen == NSScreen.main),
                "scaleFactor": .double(Double(screen.backingScaleFactor)),
            ])
        }

        return .success(id: id, payload: [
            "displays": .array(screens),
            "count": .int(screens.count),
        ])
    }

    // MARK: - Windows (requires Screen Recording permission)

    private func listWindows(id: String) -> CommandResponse {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return .permissionMissing(id: id, permission: "Screen Recording")
        }

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return .failure(id: id, code: "WINDOW_ERROR", message: "Could not list windows")
        }

        let windows: [JSONValue] = windowList.prefix(50).compactMap { info in
            guard let name = info[kCGWindowOwnerName as String] as? String else { return nil }
            let title = info[kCGWindowName as String] as? String ?? ""
            let windowId = info[kCGWindowNumber as String] as? Int ?? 0
            let pid = info[kCGWindowOwnerPID as String] as? Int ?? 0
            let bounds = info[kCGWindowBounds as String] as? [String: Any]
            let x = bounds?["X"] as? Int ?? 0
            let y = bounds?["Y"] as? Int ?? 0
            let width = bounds?["Width"] as? Int ?? 0
            let height = bounds?["Height"] as? Int ?? 0

            return .object([
                "app": .string(name),
                "title": .string(title),
                "windowId": .int(windowId),
                "pid": .int(pid),
                "x": .int(x),
                "y": .int(y),
                "width": .int(width),
                "height": .int(height),
            ])
        }

        return .success(id: id, payload: [
            "windows": .array(windows),
            "count": .int(windows.count),
        ])
    }

    // MARK: - Frontmost App

    private func frontmostApp(id: String) -> CommandResponse {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return .failure(id: id, code: "NO_APP", message: "No frontmost application")
        }

        return .success(id: id, payload: [
            "name": .string(app.localizedName ?? ""),
            "bundleId": .string(app.bundleIdentifier ?? ""),
            "pid": .int(Int(app.processIdentifier)),
        ])
    }
}
