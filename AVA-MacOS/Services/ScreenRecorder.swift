import Foundation
import ScreenCaptureKit
import AVFoundation
import os

/// Records the desktop screen while agents execute commands.
/// Uses ScreenCaptureKit (macOS 14+) with AVAssetWriter for MP4 output.
@Observable
final class ScreenRecorder {
    private let logger = Logger(subsystem: Constants.bundleID, category: "ScreenRecorder")

    private(set) var isRecording = false
    private(set) var recordingURL: URL?
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime?

    private let outputDir: String = {
        let dir = NSTemporaryDirectory() + "ava-recordings"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Start Recording

    func startRecording() async throws {
        guard !isRecording else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw RecorderError.permissionDenied
        }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw RecorderError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30fps
        config.showsCursor = true

        // Set up AVAssetWriter
        let filename = "ava-recording-\(Int(Date().timeIntervalSince1970)).mp4"
        let url = URL(fileURLWithPath: outputDir + "/" + filename)
        recordingURL = url

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 5_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: config.width,
                kCVPixelBufferHeightKey as String: config.height,
            ]
        )

        writer.add(input)
        self.assetWriter = writer
        self.videoInput = input
        self.adaptor = adaptor
        self.startTime = nil

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Start capture
        let delegate = StreamDelegate(recorder: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()

        self.stream = stream
        isRecording = true
        logger.info("Screen recording started: \(filename)")
    }

    // MARK: - Stop Recording

    func stopRecording() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false

        try? await stream?.stopCapture()
        stream = nil

        videoInput?.markAsFinished()
        await assetWriter?.finishWriting()

        let url = recordingURL
        assetWriter = nil
        videoInput = nil
        adaptor = nil
        startTime = nil

        logger.info("Screen recording stopped: \(url?.lastPathComponent ?? "nil")")
        return url
    }

    // MARK: - Frame Handling

    fileprivate func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording,
              let input = videoInput,
              input.isReadyForMoreMediaData,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if startTime == nil {
            startTime = timestamp
        }

        let relativeTime = CMTimeSubtract(timestamp, startTime!)
        adaptor?.append(pixelBuffer, withPresentationTime: relativeTime)
    }

    // MARK: - Errors

    enum RecorderError: LocalizedError {
        case permissionDenied
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Screen Recording permission required"
            case .noDisplay: return "No display found"
            }
        }
    }
}

// MARK: - Stream Delegate

private class StreamDelegate: NSObject, SCStreamDelegate, SCStreamOutput {
    weak var recorder: ScreenRecorder?

    init(recorder: ScreenRecorder) {
        self.recorder = recorder
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        recorder?.handleSampleBuffer(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            _ = await recorder?.stopRecording()
        }
    }
}
