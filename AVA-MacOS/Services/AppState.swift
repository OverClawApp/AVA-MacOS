import Foundation
import SwiftUI
import os

/// Central app state — @Observable + @MainActor for SwiftUI reactivity.
/// Modeled after OpenClaw's AppState pattern with bidirectional state syncing.
@Observable
@MainActor
final class AppState {
    private let logger = Logger(subsystem: Constants.bundleID, category: "AppState")

    // Services
    let authStore = AuthStore()
    let permissionManager = PermissionManager()
    private(set) var pairingService: PairingService!
    private(set) var commandRouter: CommandRouter!
    private(set) var apiService: APIService!
    private var wsClient: WebSocketClient?
    private var commandProcessingTask: Task<Void, Never>?

    // UI State
    var showPairing = false
    var showSettings = false
    var connectionState: WebSocketClient.ConnectionState = .disconnected
    var debugLastTestResult: String?

    // Proxy for recent commands from the router
    var recentCommands: [CommandRouter.CommandLogEntry] {
        commandRouter?.recentCommands ?? []
    }

    init() {
        pairingService = PairingService(authStore: authStore)
        commandRouter = CommandRouter(permissionManager: permissionManager)
        apiService = APIService(authStore: authStore)
    }

    // MARK: - Connection Lifecycle

    func connectIfPaired() async {
        guard authStore.isPaired else {
            logger.info("Not paired — skipping connection")
            return
        }

        let client = WebSocketClient(authStore: authStore, onStateChange: { [weak self] state in
            Task { @MainActor in
                self?.connectionState = state
            }
        }, onFatalClose: { [weak self] in
            Task { @MainActor in
                self?.logger.info("Fatal WebSocket close — forcing re-pair")
                await self?.handleRemoteUnpair()
            }
        })
        wsClient = client
        await client.connect()

        // Start processing incoming commands
        startCommandProcessing()

        // Fetch agents for chat
        await apiService.fetchAgents()

        // Auto-install CLI-Anything in background
        Task.detached {
            try? await CLIAnythingService.shared.install()
        }
    }

    func disconnect() async {
        commandProcessingTask?.cancel()
        if let client = wsClient {
            await client.disconnect()
        }
        wsClient = nil
        authStore.clearTokens()
        pairingService.cancelPairing()
        connectionState = .disconnected
        logger.info("Disconnected and unpaired")
    }

    func reconnect() async {
        if let client = wsClient {
            await client.disconnect()
        }
        await connectIfPaired()
    }

    // MARK: - Command Processing Loop

    private func startCommandProcessing() {
        commandProcessingTask?.cancel()
        commandProcessingTask = Task { [weak self] in
            guard let self, let client = self.wsClient else { return }
            guard let stream = await client.eventStream else { return }

            for await frame in stream {
                guard !Task.isCancelled else { break }

                switch frame {
                case .request(let command):
                    await self.handleCommand(command)
                case .event(let event):
                    self.logger.info("Event: \(event.event)")
                    if event.event == "unpaired" {
                        self.logger.info("Device unpaired remotely — clearing tokens")
                        await self.handleRemoteUnpair()
                    }
                case .pong:
                    break // Keepalive response
                }
            }
        }
    }

    private func handleCommand(_ command: CommandRequest) async {
        logger.info("Processing command: \(command.command.rawValue).\(command.action)")

        // Show control overlay
        ControlOverlayManager.shared.show()

        // Execute the command
        let response = await commandRouter.execute(command)

        // Hide overlay
        ControlOverlayManager.shared.hide()

        // Send response back through WebSocket
        if let client = wsClient {
            await client.sendResponse(response)
        }
    }

    // MARK: - Remote Unpair

    private func handleRemoteUnpair() async {
        commandProcessingTask?.cancel()
        if let client = wsClient {
            await client.disconnect()
        }
        wsClient = nil
        authStore.clearTokens()
        connectionState = .disconnected
        showPairing = true
        logger.info("Remote unpair complete — showing pairing view")
    }

    // MARK: - Approval Resolution

    func resolveApproval(_ decision: ApprovalDecision) {
        permissionManager.resolveApproval(decision)
    }
}
