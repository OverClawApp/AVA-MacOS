import Foundation

/// Advertised on WebSocket connect — tells the backend what this device can execute.
/// Modeled after OpenClaw's NodePairRequest capability system.
struct DeviceCapabilities: Codable {
    let platform = "macos"
    let osVersion: String
    let commands: [CommandInfo]
    let permissions: [String: Bool]

    struct CommandInfo: Codable {
        let category: String
        let actions: [String]
    }

    static func current(permissionManager: PermissionManager) -> DeviceCapabilities {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        let commands: [CommandInfo] = [
            CommandInfo(category: "desktop_file", actions: ["read", "write", "list", "info", "delete", "search"]),
            CommandInfo(category: "desktop_terminal", actions: ["execute"]),
            CommandInfo(category: "desktop_screenshot", actions: ["capture", "window", "screen"]),
            CommandInfo(category: "desktop_app", actions: ["open", "list", "activate", "quit"]),
            CommandInfo(category: "desktop_clipboard", actions: ["get", "set"]),
            CommandInfo(category: "desktop_applescript", actions: ["run"]),
            CommandInfo(category: "desktop_input", actions: ["mouse_move", "mouse_click", "mouse_scroll", "mouse_drag", "key_press", "type_text"]),
            CommandInfo(category: "desktop_system", actions: ["info", "processes", "battery", "disk", "displays", "windows", "frontmost"]),
            CommandInfo(category: "desktop_notify", actions: ["show", "clear"]),
            CommandInfo(category: "desktop_code_review", actions: ["review_pr", "diff"]),
            CommandInfo(category: "desktop_codebase", actions: ["index", "search", "get_context", "import_repo", "list_projects"]),
        ]

        var permissions: [String: Bool] = [:]
        for category in CommandCategory.allCases {
            permissions[category.rawValue] = permissionManager.isCategoryEnabled(category)
        }

        return DeviceCapabilities(
            osVersion: osVersion,
            commands: commands,
            permissions: permissions
        )
    }
}
