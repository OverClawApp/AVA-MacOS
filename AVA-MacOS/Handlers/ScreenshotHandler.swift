import Foundation
import AppKit
import ScreenCaptureKit
import os

/// Handles desktop_screenshot commands: capture, window, screen.
/// Uses ScreenCaptureKit (macOS 14+) and `screencapture` CLI fallback.
/// TCC permission wrapping modeled after OpenClaw's PERMISSION_MISSING pattern.
struct ScreenshotHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "Screenshot")

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        let params = request.params ?? [:]

        switch request.action {
        case "capture":
            return try await captureFullScreen(id: request.id, params: params)
        case "window":
            return try await captureWindow(id: request.id, params: params)
        case "screen":
            return try await captureScreen(id: request.id, params: params)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown screenshot action: \(request.action)")
        }
    }

    // MARK: - Capture via screencapture CLI (reliable, works with TCC)

    private func captureFullScreen(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return .permissionMissing(id: id, permission: "Screen Recording")
        }

        let tempFile = NSTemporaryDirectory() + "ava_screenshot_\(UUID().uuidString).png"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-C", tempFile] // -x = no sound, -C = capture cursor

        try process.run()
        process.waitUntilExit()

        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: tempFile) else {
            return .failure(id: id, code: "CAPTURE_FAILED", message: "screencapture failed")
        }

        return try encodeImageFile(id: id, path: tempFile, params: params)
    }

    private func captureWindow(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return .permissionMissing(id: id, permission: "Screen Recording")
        }

        let appName = params["app"]?.stringValue
        let windowId = params["windowId"]?.intValue

        let tempFile = NSTemporaryDirectory() + "ava_screenshot_\(UUID().uuidString).png"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")

        if let windowId {
            process.arguments = ["-x", "-l", "\(windowId)", tempFile]
        } else if let appName {
            // Activate the app first, then capture frontmost window
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
            }) {
                app.activate()
                try? await Task.sleep(for: .milliseconds(500))
            }
            process.arguments = ["-x", "-w", tempFile] // -w = window mode
        } else {
            return .failure(id: id, code: "MISSING_PARAM", message: "app or windowId required")
        }

        try process.run()
        process.waitUntilExit()

        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: tempFile) else {
            return .failure(id: id, code: "CAPTURE_FAILED", message: "Window capture failed")
        }

        return try encodeImageFile(id: id, path: tempFile, params: params)
    }

    private func captureScreen(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return .permissionMissing(id: id, permission: "Screen Recording")
        }

        let screenIndex = params["screenIndex"]?.intValue ?? 0
        let screens = NSScreen.screens

        guard screenIndex < screens.count else {
            return .failure(id: id, code: "INVALID_SCREEN", message: "Screen index \(screenIndex) out of range (have \(screens.count))")
        }

        let tempFile = NSTemporaryDirectory() + "ava_screenshot_\(UUID().uuidString).png"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -D specifies display number (1-indexed)
        process.arguments = ["-x", "-D", "\(screenIndex + 1)", tempFile]

        try process.run()
        process.waitUntilExit()

        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: tempFile) else {
            return .failure(id: id, code: "CAPTURE_FAILED", message: "Screen capture failed")
        }

        return try encodeImageFile(id: id, path: tempFile, params: params)
    }

    // MARK: - Image Encoding

    private func encodeImageFile(id: String, path: String, params: [String: JSONValue]) throws -> CommandResponse {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let image = NSImage(contentsOfFile: path) else {
            return .failure(id: id, code: "ENCODE_FAILED", message: "Failed to load captured image")
        }

        let format = params["format"]?.stringValue ?? "png"
        let outputData: Data

        if format == "jpeg" || format == "jpg" {
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else {
                return .failure(id: id, code: "ENCODE_FAILED", message: "Failed to convert image")
            }
            let quality = params["quality"]?.intValue.map { Double($0) / 100.0 } ?? 0.8
            guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
                return .failure(id: id, code: "ENCODE_FAILED", message: "JPEG encoding failed")
            }
            outputData = jpeg
        } else {
            outputData = data // Already PNG from screencapture
        }

        let base64 = outputData.base64EncodedString()
        let size = image.size

        return .success(id: id, payload: [
            "image": .string(base64),
            "encoding": .string("base64"),
            "format": .string(format),
            "width": .int(Int(size.width)),
            "height": .int(Int(size.height)),
            "size": .int(outputData.count),
        ])
    }
}
