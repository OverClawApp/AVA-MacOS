import SwiftUI

/// Tasks section — glass theme, navy text, simplified.
struct TasksSection: View {
    let apiService: APIService
    @State private var tasks: [APIService.TaskItem] = []
    @State private var showCreateSheet = false
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "checklist")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.navy.opacity(0.4))
                    Text("Tasks")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.navy)
                }
                Spacer()
                Button(action: { showCreateSheet = true }) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.navy.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)

            if isLoading {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .padding(.vertical, 8)
            } else if tasks.isEmpty {
                Text("No active tasks")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 1) {
                    ForEach(tasks.prefix(5)) { task in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(taskColor(task.status))
                                .frame(width: 5, height: 5)

                            Text(task.title)
                                .font(.caption)
                                .foregroundStyle(Color.navy)
                                .lineLimit(1)

                            Spacer()

                            if let agent = task.assignedAgentName {
                                Text(agent)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateTaskSheet(apiService: apiService) {
                Task { await fetchTasks() }
            }
        }
        .task { await fetchTasks() }
    }

    private func fetchTasks() async {
        isLoading = tasks.isEmpty
        tasks = (try? await apiService.fetchTasks()) ?? []
        isLoading = false
    }

    private func taskColor(_ status: String) -> Color {
        switch status {
        case "active", "running": return Color.avaGreen
        case "scheduled": return Color.avaBrightBlue
        default: return Color.navy.opacity(0.2)
        }
    }
}

struct CreateTaskSheet: View {
    let apiService: APIService
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var isCreating = false

    var body: some View {
        VStack(spacing: 16) {
            Text("New Task")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.navy)

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.body)

            TextField("Description", text: $description, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .lineLimit(3...5)

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(AVASecondaryButtonStyle())

                Button("Create") {
                    guard let agentId = apiService.orchestratorId else { return }
                    isCreating = true
                    Task {
                        _ = try? await apiService.createTask(title: title, description: description.isEmpty ? nil : description, agentId: agentId)
                        onCreated(); dismiss()
                    }
                }
                .buttonStyle(AVAPrimaryButtonStyle())
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
            }
        }
        .padding(24)
        .frame(width: 300)
        .background(.ultraThinMaterial)
    }
}
