import Foundation
import os

/// REST + SSE API client for the AVA backend.
/// Handles chat streaming, usage stats, tasks, and agent listing.
@Observable
@MainActor
final class APIService {
    private let logger = Logger(subsystem: Constants.bundleID, category: "API")
    private let authStore: AuthStore
    private let decoder = JSONDecoder()

    // Cached agents
    private(set) var orchestratorId: String?
    private(set) var agents: [Agent] = []

    init(authStore: AuthStore) {
        self.authStore = authStore
    }

    // MARK: - Authenticated Request Helper

    private func authenticatedRequest(_ path: String, method: String = "GET", body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let token = authStore.accessToken else {
            throw APIError.unauthorized
        }
        guard let url = URL(string: "\(Constants.apiBaseURL)\(path)") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if http.statusCode == 401 {
            // Try refreshing token
            if await authStore.refreshAccessToken() {
                return try await authenticatedRequest(path, method: method, body: body)
            }
            throw APIError.unauthorized
        }

        guard (200...299).contains(http.statusCode) else {
            throw APIError.serverError(http.statusCode)
        }

        return (data, http)
    }

    // MARK: - Agents (find orchestrator)

    struct Agent: Decodable {
        let id: String
        let name: String
        let personality: String?
    }

    struct AgentsResponse: Decodable {
        let agents: [Agent]
    }

    func fetchAgents() async {
        do {
            let (data, _) = try await authenticatedRequest("/agents")
            // Backend returns array directly, or wrapped in { agents: [...] }
            if let response = try? decoder.decode(AgentsResponse.self, from: data) {
                agents = response.agents
            } else {
                agents = try decoder.decode([Agent].self, from: data)
            }
            orchestratorId = agents.first(where: { $0.personality == "orchestrator" })?.id
                ?? agents.first?.id
            logger.info("Loaded \(self.agents.count) agents, orchestrator: \(self.orchestratorId ?? "none")")
        } catch {
            logger.error("Failed to fetch agents: \(error)")
        }
    }

    // MARK: - Chat SSE Streaming

    func streamChat(agentId: String, message: String) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let token = self.authStore.accessToken else {
                        continuation.finish(throwing: APIError.unauthorized)
                        return
                    }
                    guard let url = URL(string: "\(Constants.apiBaseURL)/agents/\(agentId)/chat") else {
                        continuation.finish(throwing: APIError.invalidURL)
                        return
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    let body = ChatBody(message: "[Desktop]\n\(message)")
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        continuation.finish(throwing: APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0))
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let json = String(line.dropFirst(6))
                        guard let eventData = json.data(using: .utf8) else { continue }

                        // Try parsing different event types
                        if let delta = try? self.decoder.decode(DeltaEvent.self, from: eventData) {
                            continuation.yield(.delta(delta.delta))
                        } else if let done = try? self.decoder.decode(DoneEvent.self, from: eventData), done.done {
                            continuation.yield(.done)
                            continuation.finish()
                            return
                        } else if let status = try? self.decoder.decode(StatusEvent.self, from: eventData) {
                            continuation.yield(.status(status.status))
                        }
                        // Ignore other event types (image, audio, tool_call, etc.)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private struct ChatBody: Encodable {
        let message: String
    }
    private struct DeltaEvent: Decodable { let delta: String }
    private struct DoneEvent: Decodable { let done: Bool }
    private struct StatusEvent: Decodable { let status: String }

    enum ChatEvent {
        case delta(String)
        case status(String)
        case done
    }

    // MARK: - Usage / Credits

    struct UsageResponse: Decodable {
        let offices: [OfficeUsage]
    }

    struct OfficeUsage: Decodable, Identifiable {
        var id: Int { officeNumber }
        let officeNumber: Int
        let tier: String
        let creditsUsed: Int
        let creditsLimit: Int
        let monthlyRatio: Double
    }

    func fetchUsage() async throws -> UsageResponse {
        let (data, _) = try await authenticatedRequest("/stats/usage")
        return try decoder.decode(UsageResponse.self, from: data)
    }

    // MARK: - Tasks

    struct TaskItem: Decodable, Identifiable {
        let id: String
        let title: String
        let status: String
        let scheduleKind: String?
        let description: String?
        let taskPersonas: [TaskPersona]?

        struct TaskPersona: Decodable {
            let persona: PersonaRef?
        }
        struct PersonaRef: Decodable {
            let id: String
            let name: String
        }

        var assignedAgentName: String? {
            taskPersonas?.first?.persona?.name
        }
    }

    func fetchTasks() async throws -> [TaskItem] {
        let (data, _) = try await authenticatedRequest("/tasks")
        return try decoder.decode([TaskItem].self, from: data)
    }

    struct CreateTaskBody: Encodable {
        let title: String
        let description: String?
        let agentIds: [String]
        let scheduleKind: String
    }

    func createTask(title: String, description: String?, agentId: String) async throws -> TaskItem {
        let body = CreateTaskBody(
            title: title,
            description: description,
            agentIds: [agentId],
            scheduleKind: "at"
        )
        let bodyData = try JSONEncoder().encode(body)
        let (data, _) = try await authenticatedRequest("/tasks", method: "POST", body: bodyData)
        return try decoder.decode(TaskItem.self, from: data)
    }

    // MARK: - Errors

    enum APIError: LocalizedError {
        case unauthorized
        case invalidURL
        case invalidResponse
        case serverError(Int)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "Not authenticated"
            case .invalidURL: return "Invalid URL"
            case .invalidResponse: return "Invalid response"
            case .serverError(let code): return "Server error (\(code))"
            }
        }
    }
}
