import Foundation

// MARK: - Three-Frame Protocol (modeled after OpenClaw's gateway protocol)

/// Inbound frame from the backend WebSocket relay
enum InboundFrame: Decodable {
    case request(CommandRequest)
    case event(EventFrame)
    case pong

    private enum FrameType: String, Decodable {
        case req, event, pong
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(FrameType.self, forKey: .type)
        switch type {
        case .req:
            self = .request(try CommandRequest(from: decoder))
        case .event:
            self = .event(try EventFrame(from: decoder))
        case .pong:
            self = .pong
        }
    }
}

/// Outbound frame to the backend
enum OutboundFrame: Encodable {
    case hello(HelloFrame)
    case response(CommandResponse)
    case ping

    func encode(to encoder: Encoder) throws {
        switch self {
        case .hello(let frame):
            try frame.encode(to: encoder)
        case .response(let frame):
            try frame.encode(to: encoder)
        case .ping:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("ping", forKey: .type)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }
}

// MARK: - Hello (capability advertisement, modeled after OpenClaw's NodePairRequest)

struct HelloFrame: Codable {
    let type = "hello"
    let deviceId: String
    let platform = "macos"
    let version: String
    let capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case type, deviceId, platform, version, capabilities
    }

    static func current(deviceId: String) -> HelloFrame {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return HelloFrame(
            deviceId: deviceId,
            version: version,
            capabilities: CommandCategory.allCases.map(\.rawValue)
        )
    }
}

struct HelloOkFrame: Decodable {
    let type: String
    let gatewayVersion: String?
    let protocolVersion: Int?
}

// MARK: - Command Request (backend -> desktop)

struct CommandRequest: Codable, Identifiable {
    let type: String // "req"
    let id: String
    let command: CommandCategory
    let action: String
    let params: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case type, id, command, action, params
    }
}

// MARK: - Command Response (desktop -> backend)

struct CommandResponse: Codable {
    let type = "res"
    let id: String
    let ok: Bool
    let payload: [String: JSONValue]?
    let error: CommandError?

    enum CodingKeys: String, CodingKey {
        case type, id, ok, payload, error
    }

    static func success(id: String, payload: [String: JSONValue] = [:]) -> CommandResponse {
        CommandResponse(id: id, ok: true, payload: payload, error: nil)
    }

    static func failure(id: String, code: String, message: String) -> CommandResponse {
        CommandResponse(id: id, ok: false, payload: nil, error: CommandError(code: code, message: message))
    }

    static func permissionDenied(id: String, command: CommandCategory) -> CommandResponse {
        failure(id: id, code: "PERMISSION_DENIED", message: "User denied permission for \(command.rawValue)")
    }

    static func permissionMissing(id: String, permission: String) -> CommandResponse {
        failure(id: id, code: "PERMISSION_MISSING", message: "macOS permission not granted: \(permission)")
    }
}

struct CommandError: Codable {
    let code: String
    let message: String
}

// MARK: - Event Frame (server push)

struct EventFrame: Codable {
    let type: String // "event"
    let event: String
    let payload: [String: JSONValue]?
}

// MARK: - Command Categories

enum CommandCategory: String, Codable, CaseIterable {
    case file = "desktop_file"
    case terminal = "desktop_terminal"
    case screenshot = "desktop_screenshot"
    case app = "desktop_app"
    case clipboard = "desktop_clipboard"
    case applescript = "desktop_applescript"
    case input = "desktop_input"
    case system = "desktop_system"
    case notify = "desktop_notify"
    case codeReview = "desktop_code_review"
    case codebase = "desktop_codebase"
    case accessibility = "desktop_accessibility"
    case browser = "desktop_browser"
    case window = "desktop_window"
    case process = "desktop_process"
    case recording = "desktop_recording"
    case url = "desktop_url"
    case vision = "desktop_vision"
    case camera = "desktop_camera"
    case location = "desktop_location"
    case pim = "desktop_pim"
    case mcp = "desktop_mcp"
    case cliGen = "desktop_cli_gen"
    case systemControl = "desktop_system_control"
    case watch = "desktop_watch"
    case automation = "desktop_automation"

    var displayName: String {
        switch self {
        case .file: return "File System"
        case .terminal: return "Terminal"
        case .screenshot: return "Screenshots"
        case .app: return "App Control"
        case .clipboard: return "Clipboard"
        case .applescript: return "AppleScript"
        case .input: return "Mouse & Keyboard"
        case .system: return "System Info"
        case .notify: return "Notifications"
        case .codeReview: return "Code Review"
        case .codebase: return "Codebase"
        case .accessibility: return "UI Elements"
        case .browser: return "Browser"
        case .window: return "Windows"
        case .process: return "Processes"
        case .recording: return "Screen Recording"
        case .url: return "URLs"
        case .vision: return "Vision Control"
        case .camera: return "Camera"
        case .location: return "Location"
        case .pim: return "Contacts & Calendar"
        case .mcp: return "MCP Servers"
        case .cliGen: return "CLI Generator"
        case .systemControl: return "System Control"
        case .watch: return "File Watcher"
        case .automation: return "Automation"
        }
    }

    var icon: String {
        switch self {
        case .file: return "folder"
        case .terminal: return "terminal"
        case .screenshot: return "camera.viewfinder"
        case .app: return "app.badge.checkmark"
        case .clipboard: return "doc.on.clipboard"
        case .applescript: return "applescript"
        case .input: return "cursorarrow.click"
        case .system: return "cpu"
        case .notify: return "bell"
        case .codeReview: return "eye"
        case .codebase: return "text.magnifyingglass"
        case .accessibility: return "rectangle.3.group"
        case .browser: return "globe"
        case .window: return "macwindow.on.rectangle"
        case .process: return "gearshape.2"
        case .recording: return "record.circle"
        case .url: return "link"
        case .vision: return "eye.circle"
        case .camera: return "camera"
        case .location: return "location"
        case .pim: return "person.crop.rectangle"
        case .mcp: return "puzzlepiece.extension"
        case .cliGen: return "hammer"
        case .systemControl: return "slider.horizontal.3"
        case .watch: return "eye.trianglebadge.exclamationmark"
        case .automation: return "play.rectangle"
        }
    }

    /// Risk classification (modeled after Claude Code's LOW/MEDIUM/HIGH system)
    var defaultRisk: RiskLevel {
        switch self {
        case .screenshot, .clipboard, .system, .notify, .url: return .low
        case .file, .app, .codebase, .window, .recording: return .medium
        case .terminal, .applescript, .input, .codeReview, .accessibility, .browser, .process, .vision: return .high
        case .camera, .location, .pim, .mcp, .cliGen, .watch: return .medium
        case .systemControl, .automation: return .high
        }
    }
}

// MARK: - Risk Classification (from Claude Code internals)

enum RiskLevel: String, Codable, Comparable {
    case low
    case medium
    case high

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        let order: [RiskLevel] = [.low, .medium, .high]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

// MARK: - Approval (modeled after OpenClaw's exec-approval system)

enum ApprovalDecision: String, Codable {
    case allowOnce = "allow-once"
    case allowAlways = "allow-always"
    case deny
}

// MARK: - JSON Value (flexible Codable for params/payload)

enum JSONValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}
