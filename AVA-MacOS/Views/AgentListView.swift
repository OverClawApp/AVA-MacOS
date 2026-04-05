import SwiftUI

/// Agent list — shows all agents with avatars, names, personality, last message preview.
/// Matches the iOS app's home screen layout.
struct AgentListView: View {
    let agents: [APIService.Agent]
    let onSelectAgent: (APIService.Agent) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                    Button(action: { onSelectAgent(agent) }) {
                        agentRow(agent)
                    }
                    .buttonStyle(.plain)

                    if index < agents.count - 1 {
                        Rectangle()
                            .fill(Color(.separatorColor).opacity(0.3))
                            .frame(height: 0.5)
                            .padding(.leading, 72)
                            .padding(.trailing, 20)
                    }
                }
            }
        }
    }

    private func agentRow(_ agent: APIService.Agent) -> some View {
        HStack(spacing: 12) {
            // Character avatar
            PixelAvatarView(agentId: agent.id, personality: agent.personality, size: 44)

            // Name, personality, last message
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(agent.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.navy)

                    Text(agent.displayPersonality)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if let lastAt = agent.lastMessageAt {
                        Text(timeAgo(lastAt))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(agent.lastMessage ?? "Start a conversation")
                    .font(.system(size: 13))
                    .foregroundStyle(agent.lastMessage != nil ? Color.navy.opacity(0.6) : Color.navy.opacity(0.3))
                    .lineLimit(2)
            }

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }
}
