import Foundation
import os

/// Actor-based WebSocket client modeled after OpenClaw's GatewayChannelActor.
///
/// Features from research:
/// - UUID request-response correlation (OpenClaw pattern)
/// - Exponential backoff reconnection: 500ms -> 30s (OpenClaw pattern)
/// - Keepalive pings every 15s (OpenClaw pattern)
/// - Capability advertisement on connect (OpenClaw NodePairRequest pattern)
/// - Three-frame protocol: req/res/event (OpenClaw gateway protocol)
actor WebSocketClient {
    private let logger = Logger(subsystem: Constants.bundleID, category: "WebSocket")

    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var reconnectAttempt = 0
    private var isIntentionalDisconnect = false

    // Request-response correlation (OpenClaw pattern: pending requests keyed by UUID)
    private var pendingResponses: [String: CheckedContinuation<Void, Never>] = [:]

    // Event stream for pushing events to the app
    private var eventContinuation: AsyncStream<InboundFrame>.Continuation?
    private(set) var eventStream: AsyncStream<InboundFrame>?

    // State
    private(set) var connectionState: ConnectionState = .disconnected

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
    }

    // Dependencies
    private let authStore: AuthStore
    private let onStateChange: @Sendable (ConnectionState) -> Void

    init(authStore: AuthStore, onStateChange: @escaping @Sendable (ConnectionState) -> Void) {
        self.authStore = authStore
        self.onStateChange = onStateChange

        let (stream, continuation) = AsyncStream<InboundFrame>.makeStream()
        self.eventStream = stream
        self.eventContinuation = continuation
    }

    // MARK: - Connection

    func connect() async {
        guard connectionState == .disconnected || {
            if case .reconnecting = connectionState { return true }
            return false
        }() else { return }

        isIntentionalDisconnect = false
        await updateState(.connecting)

        // Refresh token if reconnecting (may have expired during disconnect)
        if reconnectAttempt > 0 {
            _ = await authStore.refreshAccessToken()
        }

        guard let token = await authStore.accessToken else {
            logger.error("No access token — cannot connect")
            await updateState(.disconnected)
            return
        }

        guard var components = URLComponents(string: Constants.wsBaseURL) else { return }
        components.queryItems = [URLQueryItem(name: "token", value: token)]

        guard let url = components.url else { return }

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)

        let request = URLRequest(url: url)
        socket = session?.webSocketTask(with: request)
        socket?.resume()

        // Send hello frame with capabilities
        let deviceId = await authStore.deviceId
        let hello = HelloFrame.current(deviceId: deviceId)
        await send(.hello(hello))

        reconnectAttempt = 0
        await updateState(.connected)
        logger.info("WebSocket connected")

        startPingLoop()
        startReceiveLoop()
    }

    func disconnect() async {
        isIntentionalDisconnect = true
        pingTask?.cancel()
        receiveTask?.cancel()
        reconnectTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        await updateState(.disconnected)
        logger.info("WebSocket disconnected")
    }

    // MARK: - Send

    func send(_ frame: OutboundFrame) async {
        do {
            let data = try JSONEncoder().encode(frame)
            try await socket?.send(.data(data))
        } catch {
            logger.error("Send failed: \(error)")
            await handleDisconnect()
        }
    }

    func sendResponse(_ response: CommandResponse) async {
        await send(.response(response))
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let socket = await self.socket else { break }
                    let message = try await socket.receive()
                    await self.handleMessage(message)
                } catch {
                    if !Task.isCancelled {
                        await self.logger.error("Receive error: \(error)")
                        await self.handleDisconnect()
                    }
                    break
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        let data: Data
        switch message {
        case .data(let d):
            data = d
        case .string(let s):
            guard let d = s.data(using: .utf8) else { return }
            data = d
        @unknown default:
            return
        }

        do {
            let frame = try JSONDecoder().decode(InboundFrame.self, from: data)
            eventContinuation?.yield(frame)
        } catch {
            logger.error("Failed to decode frame: \(error)")
        }
    }

    // MARK: - Keepalive Ping (OpenClaw pattern: 15-second interval)

    private func startPingLoop() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Constants.wsPingInterval))
                guard !Task.isCancelled else { break }
                await self?.send(.ping)
            }
        }
    }

    // MARK: - Reconnection (OpenClaw pattern: exponential backoff 500ms -> 30s)

    private func handleDisconnect() async {
        guard !isIntentionalDisconnect else { return }

        pingTask?.cancel()
        receiveTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil

        reconnectAttempt += 1
        let attempt = reconnectAttempt
        await updateState(.reconnecting(attempt: attempt))

        let delay = min(
            Constants.wsReconnectBaseDelay * pow(2, Double(attempt - 1)),
            Constants.wsReconnectMaxDelay
        )

        logger.info("Reconnecting in \(delay)s (attempt \(attempt))")

        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await connect()
        }
    }

    private func updateState(_ state: ConnectionState) {
        connectionState = state
        onStateChange(state)
    }
}
