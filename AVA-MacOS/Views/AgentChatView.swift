import SwiftUI

/// Full chat view for a specific agent — message history + input + streaming.
/// Matches the iOS app's chat experience.
struct AgentChatView: View {
    let agent: APIService.Agent
    let apiService: APIService
    let onBack: () -> Void

    @State private var messages: [APIService.ChatMessage] = []
    @State private var input = ""
    @State private var isStreaming = false
    @State private var streamingText = ""
    @State private var streamTask: Task<Void, Never>?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.navy.opacity(0.5))
                }
                .buttonStyle(.plain)

                PixelAvatarView(agentId: agent.id, personality: agent.personality, size: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.navy)
                    Text(agent.displayPersonality)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Rectangle()
                .fill(Color(.separatorColor).opacity(0.3))
                .frame(height: 0.5)

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if isLoading {
                            ProgressView().controlSize(.small).padding(.top, 20)
                        }

                        ForEach(messages) { msg in
                            messageBubble(msg)
                                .id(msg.id)
                        }

                        // Streaming message
                        if isStreaming && !streamingText.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                PixelAvatarView(agentId: agent.id, personality: agent.personality, size: 22)
                                    .fixedSize()
                                    .frame(width: 22, height: 22)
                                    .clipShape(Circle())

                                Text(markdownText(streamingText))
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.navy)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 16)
                            .id("streaming")
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: streamingText) { _, _ in
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Rectangle()
                .fill(Color(.separatorColor).opacity(0.3))
                .frame(height: 0.5)

            // Input
            HStack(spacing: 8) {
                TextField("Message \(agent.name)...", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.navy)
                    .onSubmit { sendMessage() }
                    .disabled(isStreaming)

                if isStreaming {
                    ProgressView().controlSize(.small)
                } else if !input.isEmpty {
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.navy)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .task { await loadMessages() }
    }

    // MARK: - Message Bubble

    private func messageBubble(_ msg: APIService.ChatMessage) -> some View {
        let isUser = msg.role == "user"

        return HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 40) }

            if !isUser {
                PixelAvatarView(agentId: agent.id, personality: agent.personality, size: 22)
            }

            Text(markdownText(cleanContent(msg.content)))
                .font(.system(size: 13))
                .foregroundStyle(isUser ? .white : Color.navy)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    isUser
                        ? AnyShapeStyle(Color.navy)
                        : AnyShapeStyle(.ultraThinMaterial),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .textSelection(.enabled)

            if !isUser { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Clean Content

    private func cleanContent(_ text: String) -> String {
        text.replacingOccurrences(of: "[Desktop]\n", with: "")
            .replacingOccurrences(of: "[Desktop]", with: "")
    }

    // MARK: - Markdown

    private func markdownText(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    // MARK: - Load Messages

    private func loadMessages() async {
        isLoading = true
        do {
            messages = try await apiService.fetchMessages(agentId: agent.id, limit: 50)
        } catch {
            // Silent fail — show empty chat
        }
        isLoading = false
    }

    // MARK: - Send

    private func sendMessage() {
        let msg = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }

        // Add user message locally
        let userMsg = APIService.ChatMessage(
            id: UUID().uuidString,
            role: "user",
            content: msg,
            createdAt: Date()
        )
        messages.append(userMsg)

        input = ""
        streamingText = ""
        isStreaming = true

        streamTask?.cancel()
        streamTask = Task {
            do {
                for try await event in apiService.streamChat(agentId: agent.id, message: msg) {
                    if case .delta(let text) = event { streamingText += text }
                }

                // Add assistant response to messages
                if !streamingText.isEmpty {
                    let assistantMsg = APIService.ChatMessage(
                        id: UUID().uuidString,
                        role: "assistant",
                        content: streamingText,
                        createdAt: Date()
                    )
                    messages.append(assistantMsg)
                }
            } catch {
                if streamingText.isEmpty {
                    streamingText = "Error: \(error.localizedDescription)"
                }
            }
            streamingText = ""
            isStreaming = false
        }
    }
}
