import Foundation
import os

/// Three-tier permission system modeled after OpenClaw's exec-approval + Claude Code's risk classification.
///
/// Tier 1: Category enable/disable (user toggles in Settings)
/// Tier 2: Risk-based approval (LOW = auto, MEDIUM = ask first time, HIGH = always ask)
/// Tier 3: Durable allowlist (allow-always entries persist across sessions)
@Observable
final class PermissionManager {
    private let logger = Logger(subsystem: Constants.bundleID, category: "Permissions")

    /// Per-category toggle — master switch for each command type
    var categoryEnabled: [CommandCategory: Bool] = {
        var defaults: [CommandCategory: Bool] = [:]
        for cat in CommandCategory.allCases {
            defaults[cat] = false // Off by default — user must opt in
        }
        return defaults
    }()

    /// Durable allowlist — command patterns the user has approved with "allow-always"
    /// Key format: "category:action" or "category:action:detail"
    private(set) var allowlist: Set<String> = []

    /// Pending approval request — set when a command needs user confirmation
    var pendingApproval: ApprovalRequest?

    /// Continuation for the pending approval — resumed when user decides
    private var approvalContinuation: CheckedContinuation<ApprovalDecision, Never>?

    struct ApprovalRequest: Identifiable {
        let id = UUID()
        let command: CommandRequest
        let risk: RiskLevel
        let description: String
    }

    init() {
        loadFromDefaults()
    }

    // MARK: - Category Management

    func isCategoryEnabled(_ category: CommandCategory) -> Bool {
        categoryEnabled[category] ?? false
    }

    func setCategory(_ category: CommandCategory, enabled: Bool) {
        categoryEnabled[category] = enabled
        saveToDefaults()
        logger.info("Category \(category.rawValue) \(enabled ? "enabled" : "disabled")")
    }

    // MARK: - Approval Flow (modeled after OpenClaw's exec-approval protocol)

    /// Check if a command is allowed to execute. Returns the decision.
    /// May suspend to show a UI prompt for MEDIUM/HIGH risk commands.
    @MainActor
    func requestApproval(for command: CommandRequest) async -> ApprovalDecision {
        let category = command.command

        // Tier 1: Category must be enabled
        guard isCategoryEnabled(category) else {
            logger.info("Category \(category.rawValue) disabled — auto-deny")
            return .deny
        }

        // Tier 2: Check durable allowlist
        let pattern = "\(category.rawValue):\(command.action)"
        if allowlist.contains(pattern) {
            logger.debug("Allowlist hit: \(pattern)")
            return .allowOnce // Allowed but we say allowOnce since it's already durable
        }

        // Tier 3: Risk-based decision
        let risk = riskLevel(for: command)
        switch risk {
        case .low:
            return .allowOnce
        case .medium, .high:
            return await promptUser(for: command, risk: risk)
        }
    }

    /// Show approval UI and wait for user decision
    @MainActor
    private func promptUser(for command: CommandRequest, risk: RiskLevel) async -> ApprovalDecision {
        let description = describeCommand(command)

        let decision: ApprovalDecision = await withCheckedContinuation { continuation in
            self.approvalContinuation = continuation
            self.pendingApproval = ApprovalRequest(
                command: command,
                risk: risk,
                description: description
            )
        }

        // If allow-always, add to durable allowlist
        if decision == .allowAlways {
            let pattern = "\(command.command.rawValue):\(command.action)"
            allowlist.insert(pattern)
            saveToDefaults()
            logger.info("Added to allowlist: \(pattern)")
        }

        pendingApproval = nil
        return decision
    }

    /// Called by the UI when the user makes a decision
    @MainActor
    func resolveApproval(_ decision: ApprovalDecision) {
        approvalContinuation?.resume(returning: decision)
        approvalContinuation = nil
    }

    // MARK: - Risk Assessment

    func riskLevel(for command: CommandRequest) -> RiskLevel {
        let baseRisk = command.command.defaultRisk

        // Elevate risk for destructive actions
        switch (command.command, command.action) {
        case (.file, "delete"):
            return .high
        case (.file, "write"):
            return max(baseRisk, .medium)
        case (.terminal, _):
            return .high // All terminal commands are high risk
        case (.applescript, _):
            return .high
        case (.app, "quit"):
            return .medium
        default:
            return baseRisk
        }
    }

    private func describeCommand(_ command: CommandRequest) -> String {
        let params = command.params ?? [:]
        switch (command.command, command.action) {
        case (.file, "read"):
            return "Read file: \(params["path"]?.stringValue ?? "unknown")"
        case (.file, "write"):
            return "Write file: \(params["path"]?.stringValue ?? "unknown")"
        case (.file, "delete"):
            return "Delete file: \(params["path"]?.stringValue ?? "unknown")"
        case (.file, "list"):
            return "List directory: \(params["path"]?.stringValue ?? "unknown")"
        case (.terminal, "execute"):
            return "Run command: \(params["command"]?.stringValue ?? "unknown")"
        case (.screenshot, _):
            return "Take screenshot"
        case (.app, "open"):
            return "Open app: \(params["name"]?.stringValue ?? "unknown")"
        case (.app, "quit"):
            return "Quit app: \(params["name"]?.stringValue ?? "unknown")"
        case (.clipboard, "get"):
            return "Read clipboard"
        case (.clipboard, "set"):
            return "Set clipboard content"
        case (.applescript, "run"):
            let script = params["script"]?.stringValue ?? ""
            let preview = String(script.prefix(80))
            return "Run AppleScript: \(preview)\(script.count > 80 ? "..." : "")"
        default:
            return "\(command.command.displayName): \(command.action)"
        }
    }

    // MARK: - Allowlist Management

    func removeFromAllowlist(_ pattern: String) {
        allowlist.remove(pattern)
        saveToDefaults()
    }

    func clearAllowlist() {
        allowlist.removeAll()
        saveToDefaults()
    }

    // MARK: - Persistence

    private func saveToDefaults() {
        let defaults = UserDefaults.standard

        // Save category toggles
        var categoryDict: [String: Bool] = [:]
        for (cat, enabled) in categoryEnabled {
            categoryDict[cat.rawValue] = enabled
        }
        defaults.set(categoryDict, forKey: "ava_category_enabled")

        // Save allowlist
        defaults.set(Array(allowlist), forKey: Constants.permissionsStorageKey)
    }

    private func loadFromDefaults() {
        let defaults = UserDefaults.standard

        if let dict = defaults.dictionary(forKey: "ava_category_enabled") as? [String: Bool] {
            for (key, value) in dict {
                if let cat = CommandCategory(rawValue: key) {
                    categoryEnabled[cat] = value
                }
            }
        }

        if let list = defaults.stringArray(forKey: Constants.permissionsStorageKey) {
            allowlist = Set(list)
        }
    }
}
