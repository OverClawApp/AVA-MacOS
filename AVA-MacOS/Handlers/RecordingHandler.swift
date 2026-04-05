import Foundation
import os

/// Handles desktop_recording commands — start/stop screen recording.
/// Wraps the ScreenRecorder service.
struct RecordingHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "Recording")
    private let recorder = ScreenRecorder()

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        switch request.action {
        case "start":
            return try await startRecording(id: request.id)
        case "stop":
            return await stopRecording(id: request.id)
        case "status":
            return status(id: request.id)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown recording action: \(request.action)")
        }
    }

    private func startRecording(id: String) async throws -> CommandResponse {
        guard !recorder.isRecording else {
            return .failure(id: id, code: "ALREADY_RECORDING", message: "Already recording")
        }

        try await recorder.startRecording()
        return .success(id: id, payload: ["recording": .bool(true)])
    }

    private func stopRecording(id: String) async -> CommandResponse {
        guard recorder.isRecording else {
            return .failure(id: id, code: "NOT_RECORDING", message: "Not recording")
        }

        guard let url = await recorder.stopRecording() else {
            return .failure(id: id, code: "STOP_FAILED", message: "Failed to stop recording")
        }

        return .success(id: id, payload: [
            "recording": .bool(false),
            "path": .string(url.path),
            "filename": .string(url.lastPathComponent),
        ])
    }

    private func status(id: String) -> CommandResponse {
        .success(id: id, payload: [
            "recording": .bool(recorder.isRecording),
            "path": .string(recorder.recordingURL?.path ?? ""),
        ])
    }
}
