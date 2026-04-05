import Foundation
import AVFoundation
import AppKit
import os

/// Handles desktop_camera commands: list, snap, clip.
/// Matches OpenClaw's camera.list/camera.snap/camera.clip.
struct CameraHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "Camera")

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        let params = request.params ?? [:]

        switch request.action {
        case "list":
            return listCameras(id: request.id)
        case "snap":
            return try await capturePhoto(id: request.id, params: params)
        case "clip":
            return try await recordClip(id: request.id, params: params)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown camera action: \(request.action)")
        }
    }

    // MARK: - List Cameras

    private func listCameras(id: String) -> CommandResponse {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        ).devices

        let cameras = devices.map { device -> JSONValue in
            .object([
                "name": .string(device.localizedName),
                "id": .string(device.uniqueID),
                "position": .string(device.position == .front ? "front" : device.position == .back ? "back" : "external"),
                "isConnected": .bool(device.isConnected),
            ])
        }

        return .success(id: id, payload: [
            "cameras": .array(cameras),
            "count": .int(cameras.count),
        ])
    }

    // MARK: - Capture Photo

    private func capturePhoto(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        let deviceId = params["deviceId"]?.stringValue

        // Find camera
        let device: AVCaptureDevice?
        if let deviceId {
            device = AVCaptureDevice(uniqueID: deviceId)
        } else {
            device = AVCaptureDevice.default(for: .video)
        }

        guard let camera = device else {
            return .failure(id: id, code: "NO_CAMERA", message: "No camera found")
        }

        // Use screencapture -c for webcam (simplest reliable approach on macOS)
        // Alternative: AVCaptureSession + AVCapturePhotoOutput
        let tempFile = NSTemporaryDirectory() + "ava_camera_\(UUID().uuidString).jpg"

        let photoData = try await captureWithAVFoundation(camera: camera)

        guard let data = photoData else {
            return .failure(id: id, code: "CAPTURE_FAILED", message: "Failed to capture photo")
        }

        let base64 = data.base64EncodedString()
        let format = params["format"]?.stringValue ?? "jpeg"

        return .success(id: id, payload: [
            "image": .string(base64),
            "encoding": .string("base64"),
            "format": .string(format),
            "camera": .string(camera.localizedName),
            "size": .int(data.count),
        ])
    }

    private func captureWithAVFoundation(camera: AVCaptureDevice) async throws -> Data? {
        let session = AVCaptureSession()
        session.sessionPreset = .photo

        guard let input = try? AVCaptureDeviceInput(device: camera) else { return nil }
        guard session.canAddInput(input) else { return nil }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)

        let delegate = PhotoCaptureDelegate()
        output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "camera"))

        session.startRunning()

        // Wait for a frame
        try await Task.sleep(for: .milliseconds(500))

        session.stopRunning()

        guard let buffer = delegate.lastBuffer else { return nil }
        let imageBuffer = CMSampleBufferGetImageBuffer(buffer)!
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let rep = NSCIImageRep(ciImage: ciImage)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)

        return image.tiffRepresentation.flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        }
    }

    // MARK: - Record Clip

    private func recordClip(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        let duration = params["duration"]?.intValue ?? 5
        guard duration <= 30 else {
            return .failure(id: id, code: "TOO_LONG", message: "Max clip duration is 30 seconds")
        }

        let tempFile = NSTemporaryDirectory() + "ava_clip_\(UUID().uuidString).mp4"

        // Use ffmpeg or avfoundation via terminal for video capture
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-f", "avfoundation", "-framerate", "30",
            "-i", "0", "-t", "\(duration)",
            "-c:v", "libx264", "-preset", "ultrafast",
            tempFile,
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // ffmpeg not installed — return error with instructions
            return .failure(id: id, code: "FFMPEG_MISSING", message: "Video recording requires ffmpeg. Install with: brew install ffmpeg")
        }

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: tempFile) else {
            return .failure(id: id, code: "RECORD_FAILED", message: "Clip recording failed")
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: tempFile)[.size] as? Int) ?? 0

        return .success(id: id, payload: [
            "path": .string(tempFile),
            "duration": .int(duration),
            "size": .int(fileSize),
            "format": .string("mp4"),
        ])
    }
}

// MARK: - Photo Delegate

private class PhotoCaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var lastBuffer: CMSampleBuffer?

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lastBuffer = sampleBuffer
    }
}
