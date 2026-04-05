import SwiftUI

/// Mini chat — glass theme, navy text, light blue accent.
struct ChatSection: View {
    let apiService: APIService
    @State private var input = ""
    @State private var response = ""
    @State private var isStreaming = false
    @State private var streamTask: Task<Void, Never>?
    @State private var selectedAgentId: String?

    private var selectedAgent: APIService.Agent? {
        apiService.agents.first(where: { $0.id == selectedAgentId })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Agent picker
            if apiService.agents.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(apiService.agents, id: \.id) { agent in
                            let selected = agent.id == selectedAgentId
                            Button(action: { selectedAgentId = agent.id }) {
                                Text(agent.name)
                                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                                    .foregroundStyle(selected ? Color.avaBrightBlue : Color.navy.opacity(0.5))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(selected ? Color.avaBrightBlue.opacity(0.1) : .clear, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }
            }

            // Input
            HStack(spacing: 8) {
                TextField(selectedAgent.map { "Ask \($0.name)..." } ?? "Ask your agents...", text: $input)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.navy)
                    .onSubmit { sendMessage() }
                    .disabled(isStreaming)

                if isStreaming {
                    ProgressView().controlSize(.small)
                } else if !input.isEmpty {
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.navy)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.top, apiService.agents.count > 1 ? 0 : 8)
            .padding(.bottom, 8)

            // Response
            if !response.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if let agent = selectedAgent {
                            Text(agent.name)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.avaBrightBlue)
                        }
                        Text(markdownResponse)
                            .font(.caption)
                            .foregroundStyle(Color.navy.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxHeight: 100)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
        }
        .onAppear { if selectedAgentId == nil { selectedAgentId = apiService.orchestratorId } }
    }

    private var markdownResponse: AttributedString {
        (try? AttributedString(markdown: response, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(response)
    }

    private func sendMessage() {
        let msg = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty, let agentId = selectedAgentId ?? apiService.orchestratorId else { return }
        input = ""; response = ""; isStreaming = true
        streamTask?.cancel()
        streamTask = Task {
            do {
                for try await event in apiService.streamChat(agentId: agentId, message: msg) {
                    if case .delta(let text) = event { response += text }
                }
            } catch { if response.isEmpty { response = "Error: \(error.localizedDescription)" } }
            isStreaming = false
        }
    }
}
