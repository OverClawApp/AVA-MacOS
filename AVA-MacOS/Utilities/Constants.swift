import Foundation

enum Constants {
    static let apiBaseURL = "https://api.overclaw.app"
    static let wsBaseURL = "wss://api.overclaw.app/ws/desktop"
    static let pairEndpoint = "/desktop/pair"

    static let appName = "AVA Desktop"
    static let bundleID = "com.overclaw.ava.desktop"

    // Navy theme matching iOS app
    static let navyHex = "#1A2138"
    static let navyR: Double = 0.102
    static let navyG: Double = 0.129
    static let navyB: Double = 0.220

    // WebSocket
    static let wsPingInterval: TimeInterval = 15
    static let wsReconnectBaseDelay: TimeInterval = 0.5
    static let wsReconnectMaxDelay: TimeInterval = 30
    static let wsRequestTimeout: TimeInterval = 30

    // Keychain
    static let keychainService = "com.overclaw.ava.desktop"
    static let keychainAccessTokenKey = "accessToken"
    static let keychainRefreshTokenKey = "refreshToken"
    static let keychainDeviceIdKey = "deviceId"
    static let keychainPairingCodeKey = "pairingCode"

    // Terminal
    static let terminalOutputMaxLength = 200_000
    static let terminalDefaultTimeout: TimeInterval = 30

    // Permissions
    static let permissionsStorageKey = "ava_permission_allowlist"
}
