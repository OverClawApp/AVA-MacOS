import Foundation
import os

/// Routes incoming commands from the WebSocket to the appropriate handler.
/// Enforces the permission gate before execution (Claude Code PermissionGate pattern).
@MainActor
final class CommandRouter {
    private let logger = Logger(subsystem: Constants.bundleID, category: "CommandRouter")

    private let permissionManager: PermissionManager
    private let fileHandler = FileSystemHandler()
    private let terminalHandler = TerminalHandler()
    private let screenshotHandler = ScreenshotHandler()
    private let appHandler = AppControlHandler()
    private let clipboardHandler = ClipboardHandler()
    private let appleScriptHandler = AppleScriptHandler()
    private let inputHandler = InputHandler()
    private let systemHandler = SystemHandler()
    private let notificationHandler = NotificationHandler()
    private let codeReviewHandler = CodeReviewHandler()
    private let codebaseHandler = CodebaseHandler()
    private let accessibilityHandler = AccessibilityHandler()
    private let browserHandler = BrowserHandler()
    private let windowHandler = WindowHandler()
    private let processHandler = ProcessHandler()
    private let recordingHandler = RecordingHandler()
    private let urlHandler = URLHandler()
    private let visionHandler = VisionHandler()
    private let cameraHandler = CameraHandler()
    private let locationHandler = LocationHandler()
    private let pimHandler = PIMHandler()
    private let mcpHandler = MCPHandler()
    private let cliGenHandler = CLIGenHandler()
    private let systemControlHandler = SystemControlHandler()
    private let fileWatchHandler = FileWatchHandler()
    private let automationHandler = AutomationHandler()

    /// Recent commands for display in the menu bar
    @Published var recentCommands: [CommandLogEntry] = []

    struct CommandLogEntry: Identifiable {
        let id = UUID()
        let timestamp = Date()
        let command: CommandCategory
        let action: String
        let description: String
        let success: Bool
    }

    init(permissionManager: PermissionManager) {
        self.permissionManager = permissionManager
    }

    // MARK: - Route & Execute

    func execute(_ request: CommandRequest) async -> CommandResponse {
        logger.info("Command: \(request.command.rawValue).\(request.action) [id=\(request.id)]")

        // Permission gate — every command passes through (Claude Code pattern)
        let decision = await permissionManager.requestApproval(for: request)

        guard decision != .deny else {
            logCommand(request, success: false, description: "Permission denied")
            return .permissionDenied(id: request.id, command: request.command)
        }

        // Route to handler
        let response: CommandResponse
        do {
            response = try await routeToHandler(request)
        } catch {
            logger.error("Handler error: \(error)")
            response = .failure(id: request.id, code: "HANDLER_ERROR", message: error.localizedDescription)
        }

        let desc = "\(request.command.displayName) → \(request.action)"
        logCommand(request, success: response.ok, description: desc)
        return response
    }

    private func routeToHandler(_ request: CommandRequest) async throws -> CommandResponse {
        switch request.command {
        case .file:
            return try await fileHandler.handle(request)
        case .terminal:
            return try await terminalHandler.handle(request)
        case .screenshot:
            return try await screenshotHandler.handle(request)
        case .app:
            return try await appHandler.handle(request)
        case .clipboard:
            return try await clipboardHandler.handle(request)
        case .applescript:
            return try await appleScriptHandler.handle(request)
        case .input:
            return try await inputHandler.handle(request)
        case .system:
            return try await systemHandler.handle(request)
        case .notify:
            return try await notificationHandler.handle(request)
        case .codeReview:
            return try await codeReviewHandler.handle(request)
        case .codebase:
            return try await codebaseHandler.handle(request)
        case .accessibility:
            return try await accessibilityHandler.handle(request)
        case .browser:
            return try await browserHandler.handle(request)
        case .window:
            return try await windowHandler.handle(request)
        case .process:
            return try await processHandler.handle(request)
        case .recording:
            return try await recordingHandler.handle(request)
        case .url:
            return try await urlHandler.handle(request)
        case .vision:
            return try await visionHandler.handle(request)
        case .camera:
            return try await cameraHandler.handle(request)
        case .location:
            return try await locationHandler.handle(request)
        case .pim:
            return try await pimHandler.handle(request)
        case .mcp:
            return try await mcpHandler.handle(request)
        case .cliGen:
            return try await cliGenHandler.handle(request)
        case .systemControl:
            return try await systemControlHandler.handle(request)
        case .watch:
            return try await fileWatchHandler.handle(request)
        case .automation:
            return try await automationHandler.handle(request)
        }
    }

    private func logCommand(_ request: CommandRequest, success: Bool, description: String) {
        let entry = CommandLogEntry(
            command: request.command,
            action: request.action,
            description: description,
            success: success
        )
        recentCommands.insert(entry, at: 0)
        if recentCommands.count > 50 {
            recentCommands = Array(recentCommands.prefix(50))
        }
    }
}
