import Foundation
import os

/// Auto-installs CLI-Anything and manages generated CLI wrappers.
/// Lets agents create CLI tools for ANY desktop application on demand.
final class CLIAnythingService {
    static let shared = CLIAnythingService()

    private let logger = Logger(subsystem: Constants.bundleID, category: "CLIAnything")
    private let fm = FileManager.default

    let repoDir = NSHomeDirectory() + "/AVA-Projects/cli-anything"
    let clisDir = NSHomeDirectory() + "/AVA-Projects/cli-wrappers"
    private let repoURL = "https://github.com/HKUDS/CLI-Anything.git"

    var isInstalled: Bool {
        fm.fileExists(atPath: repoDir + "/HARNESS.md")
    }

    // MARK: - Install

    func install() async throws {
        if isInstalled {
            logger.info("CLI-Anything already installed")
            return
        }

        try fm.createDirectory(atPath: NSHomeDirectory() + "/AVA-Projects", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: clisDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["clone", "--depth", "1", repoURL, repoDir]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CLIError.installFailed(stderr)
        }

        logger.info("CLI-Anything installed at \(self.repoDir)")
    }

    // MARK: - Read Harness

    func readHarness() throws -> String {
        let harnessPath = repoDir + "/HARNESS.md"
        guard fm.fileExists(atPath: harnessPath) else {
            throw CLIError.notInstalled
        }
        return try String(contentsOfFile: harnessPath, encoding: .utf8)
    }

    // MARK: - List Generated CLIs

    func listGeneratedCLIs() -> [GeneratedCLI] {
        guard let contents = try? fm.contentsOfDirectory(atPath: clisDir) else { return [] }
        return contents.compactMap { name in
            let path = (clisDir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }

            // Check for setup.py or pyproject.toml
            let hasSetup = fm.fileExists(atPath: path + "/setup.py") || fm.fileExists(atPath: path + "/pyproject.toml")
            let installed = isCliInstalled(name: name)

            return GeneratedCLI(name: name, path: path, hasSetup: hasSetup, installed: installed)
        }
    }

    private func isCliInstalled(name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name + "-cli"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    struct GeneratedCLI {
        let name: String
        let path: String
        let hasSetup: Bool
        let installed: Bool
    }

    enum CLIError: LocalizedError {
        case installFailed(String)
        case notInstalled

        var errorDescription: String? {
            switch self {
            case .installFailed(let msg): return "CLI-Anything install failed: \(msg)"
            case .notInstalled: return "CLI-Anything not installed. Run install first."
            }
        }
    }
}
