import Foundation
import AppKit
import os

/// Handles desktop_system_control commands — volume, brightness, dark mode, Do Not Disturb, lock, sleep.
/// Everything a human does in System Settings, agents can do here.
struct SystemControlHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "SystemControl")

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        let params = request.params ?? [:]

        switch request.action {
        case "volume_get":
            return getVolume(id: request.id)
        case "volume_set":
            return setVolume(id: request.id, params: params)
        case "mute":
            return toggleMute(id: request.id, params: params)
        case "brightness_get":
            return getBrightness(id: request.id)
        case "brightness_set":
            return setBrightness(id: request.id, params: params)
        case "dark_mode_get":
            return getDarkMode(id: request.id)
        case "dark_mode_set":
            return setDarkMode(id: request.id, params: params)
        case "dnd_get":
            return getDND(id: request.id)
        case "dnd_set":
            return setDND(id: request.id, params: params)
        case "lock_screen":
            return lockScreen(id: request.id)
        case "sleep":
            return sleepDisplay(id: request.id)
        case "screensaver":
            return startScreensaver(id: request.id)
        case "empty_trash":
            return emptyTrash(id: request.id)
        case "wifi_status":
            return getWiFiStatus(id: request.id)
        case "wifi_toggle":
            return toggleWiFi(id: request.id, params: params)
        case "bluetooth_status":
            return getBluetoothStatus(id: request.id)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown system_control action: \(request.action)")
        }
    }

    // MARK: - Volume

    private func getVolume(id: String) -> CommandResponse {
        let result = runAppleScript("output volume of (get volume settings)")
        let muted = runAppleScript("output muted of (get volume settings)")
        return .success(id: id, payload: [
            "volume": .int(Int(result) ?? 0),
            "muted": .bool(muted == "true"),
        ])
    }

    private func setVolume(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let level = params["level"]?.intValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "level (0-100) is required")
        }
        let clamped = max(0, min(100, level))
        runAppleScript("set volume output volume \(clamped)")
        return .success(id: id, payload: ["volume": .int(clamped)])
    }

    private func toggleMute(id: String, params: [String: JSONValue]) -> CommandResponse {
        let mute = params["mute"]?.boolValue ?? true
        runAppleScript("set volume output muted \(mute)")
        return .success(id: id, payload: ["muted": .bool(mute)])
    }

    // MARK: - Brightness

    private func getBrightness(id: String) -> CommandResponse {
        let result = runShell("brightness -l 2>/dev/null | grep 'display' | head -1 | awk '{print $NF}'")
        let value = Double(result.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        if value < 0 {
            // Fallback via AppleScript
            return .success(id: id, payload: ["brightness": .string("use 'brightness' CLI: brew install brightness")])
        }
        return .success(id: id, payload: ["brightness": .double(value)])
    }

    private func setBrightness(id: String, params: [String: JSONValue]) -> CommandResponse {
        guard let level = params["level"]?.intValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "level (0.0-1.0 or 0-100) is required")
        }
        let normalized = Double(min(100, max(0, level))) / 100.0
        let result = runShell("brightness \(normalized) 2>/dev/null")
        return .success(id: id, payload: ["brightness": .double(normalized)])
    }

    // MARK: - Dark Mode

    private func getDarkMode(id: String) -> CommandResponse {
        let result = runAppleScript("tell application \"System Events\" to tell appearance preferences to get dark mode")
        return .success(id: id, payload: ["darkMode": .bool(result == "true")])
    }

    private func setDarkMode(id: String, params: [String: JSONValue]) -> CommandResponse {
        let enabled = params["enabled"]?.boolValue ?? true
        runAppleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(enabled)")
        return .success(id: id, payload: ["darkMode": .bool(enabled)])
    }

    // MARK: - Do Not Disturb

    private func getDND(id: String) -> CommandResponse {
        let result = runShell("defaults read com.apple.controlcenter 'NSStatusItem Visible FocusModes' 2>/dev/null")
        return .success(id: id, payload: ["dnd": .string(result.trimmingCharacters(in: .whitespacesAndNewlines))])
    }

    private func setDND(id: String, params: [String: JSONValue]) -> CommandResponse {
        let enabled = params["enabled"]?.boolValue ?? true
        // Toggle Focus/DND via shortcuts
        if enabled {
            runShell("shortcuts run 'Do Not Disturb' 2>/dev/null || osascript -e 'tell application \"System Events\" to keystroke \"\" using {command down, shift down}'")
        }
        return .success(id: id, payload: ["dnd": .bool(enabled)])
    }

    // MARK: - Lock / Sleep / Screensaver

    private func lockScreen(id: String) -> CommandResponse {
        runShell("/System/Library/CoreServices/Menu\\ Extras/User.menu/Contents/Resources/CGSession -suspend")
        return .success(id: id, payload: ["locked": .bool(true)])
    }

    private func sleepDisplay(id: String) -> CommandResponse {
        runShell("pmset displaysleepnow")
        return .success(id: id, payload: ["sleeping": .bool(true)])
    }

    private func startScreensaver(id: String) -> CommandResponse {
        runShell("open -a ScreenSaverEngine")
        return .success(id: id, payload: ["screensaver": .bool(true)])
    }

    // MARK: - Trash

    private func emptyTrash(id: String) -> CommandResponse {
        runAppleScript("tell application \"Finder\" to empty the trash")
        return .success(id: id, payload: ["emptied": .bool(true)])
    }

    // MARK: - WiFi

    private func getWiFiStatus(id: String) -> CommandResponse {
        let ssid = runShell("networksetup -getairportnetwork en0 2>/dev/null | awk -F': ' '{print $2}'").trimmingCharacters(in: .whitespacesAndNewlines)
        let power = runShell("networksetup -getairportpower en0 2>/dev/null | awk '{print $NF}'").trimmingCharacters(in: .whitespacesAndNewlines)

        return .success(id: id, payload: [
            "connected": .bool(!ssid.isEmpty && ssid != "You are not associated with an AirPort network."),
            "ssid": .string(ssid),
            "power": .string(power),
        ])
    }

    private func toggleWiFi(id: String, params: [String: JSONValue]) -> CommandResponse {
        let on = params["enabled"]?.boolValue ?? true
        runShell("networksetup -setairportpower en0 \(on ? "on" : "off")")
        return .success(id: id, payload: ["wifi": .bool(on)])
    }

    // MARK: - Bluetooth

    private func getBluetoothStatus(id: String) -> CommandResponse {
        let result = runShell("defaults read /Library/Preferences/com.apple.Bluetooth ControllerPowerState 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(id: id, payload: [
            "enabled": .bool(result == "1"),
        ])
    }

    // MARK: - Helpers

    @discardableResult
    private func runAppleScript(_ script: String) -> String {
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        return result?.stringValue ?? ""
    }

    @discardableResult
    private func runShell(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
