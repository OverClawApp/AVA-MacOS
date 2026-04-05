import Foundation
import os

/// Handles desktop_applescript commands: run.
/// Requires macOS Automation (Apple Events) TCC permission.
struct AppleScriptHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "AppleScript")

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        guard request.action == "run" else {
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown applescript action: \(request.action)")
        }

        let params = request.params ?? [:]
        guard let script = params["script"]?.stringValue else {
            return .failure(id: request.id, code: "MISSING_PARAM", message: "script is required")
        }

        return await executeAppleScript(id: request.id, script: script)
    }

    // MARK: - Execution

    private func executeAppleScript(id: String, script: String) async -> CommandResponse {
        logger.info("Running AppleScript (\(script.prefix(80))...)")

        var error: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        let result = appleScript?.executeAndReturnError(&error)

        if let error {
            let errorMessage = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            let errorNumber = error[NSAppleScript.errorNumber] as? Int ?? -1
            logger.error("AppleScript error \(errorNumber): \(errorMessage)")

            return .failure(
                id: id,
                code: "APPLESCRIPT_ERROR",
                message: "\(errorMessage) (error \(errorNumber))"
            )
        }

        let output = result?.stringValue ?? ""
        return .success(id: id, payload: [
            "result": .string(output),
        ])
    }
}
