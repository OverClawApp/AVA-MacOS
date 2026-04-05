import SwiftUI

/// Single menu bar popover — liquid glass theme, no color, navy icons + text.
struct MenuBarView: View {
    @Bindable var appState: AppState
    @State private var currentView: ViewState = .home

    enum ViewState: Equatable {
        case home
        case pairing
        case settings
        case chat(agentId: String)
        case tasks
    }

    var body: some View {
        VStack(spacing: 0) {
            switch currentView {
            case .home: homeView
            case .pairing: inlinePairingView
            case .settings: inlineSettingsView
            case .chat(let agentId):
                if let agent = appState.apiService.agents.first(where: { $0.id == agentId }) {
                    AgentChatView(agent: agent, apiService: appState.apiService) {
                        currentView = .home
                    }
                }
            case .tasks: inlineTasksView
            }
        }
        .frame(width: 320, height: 480)
        .animation(.easeInOut(duration: 0.2), value: currentView)
        .overlay {
            if let request = appState.permissionManager.pendingApproval {
                ZStack {
                    Color.black.opacity(0.2)
                        .ignoresSafeArea()
                    ApprovalView(request: request) { decision in
                        appState.resolveApproval(decision)
                    }
                }
            }
        }
        .onChange(of: appState.pairingService.state) { _, newState in
            if newState == .paired {
                Task { await appState.connectIfPaired() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    currentView = .home
                }
            }
        }
    }

    // MARK: - Home

    private var homeView: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image("MenuBarIcon")
                    .resizable()
                    .renderingMode(.template)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(Color.navy)

                Text("AVA Desktop")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.navy)

                Spacer()

                statusBadgeView
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            AVADivider()

            if appState.authStore.isPaired {
                // Agent list (like iOS home)
                AgentListView(agents: appState.apiService.agents) { agent in
                    currentView = .chat(agentId: agent.id)
                }
            } else {
                Spacer()
                unpairedView
                Spacer()
            }

            AVADivider()
            footerView
        }
    }

    // MARK: - Status Badge

    private var statusBadgeView: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.navy.opacity(0.6))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var statusColor: Color {
        switch appState.connectionState {
        case .connected: return Color.avaGreen
        case .connecting, .reconnecting: return .yellow
        case .disconnected: return Color.navy.opacity(0.3)
        }
    }

    private var statusLabel: String {
        switch appState.connectionState {
        case .connected: return "Live"
        case .connecting, .reconnecting: return "..."
        case .disconnected: return "Off"
        }
    }

    // MARK: - Unpaired

    private var unpairedView: some View {
        VStack(spacing: 16) {
            Image("MenuBarIcon")
                .resizable()
                .renderingMode(.template)
                .frame(width: 40, height: 40)
                .foregroundStyle(Color.navy.opacity(0.15))

            Text("Connect your iPhone")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.navy)

            Text("Pair with AVA to give your agents access to this Mac")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Pair with iPhone") {
                currentView = .pairing
            }
            .buttonStyle(AVAPrimaryButtonStyle())
        }
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "clock")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.navy.opacity(0.4))
                Text("Recent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.navy)
            }
            .padding(.horizontal, 20)

            VStack(spacing: 1) {
                ForEach(appState.recentCommands.prefix(5)) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: entry.command.icon)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.navy.opacity(0.5))
                            .frame(width: 20)

                        Text(entry.description)
                            .font(.caption)
                            .foregroundStyle(Color.navy)
                            .lineLimit(1)

                        Spacer()

                        Circle()
                            .fill(entry.success ? Color.avaGreen : Color.avaBrightRed)
                            .frame(width: 5, height: 5)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 0) {
            footerTab(icon: "message", label: "Agents", active: currentView == .home) {
                currentView = .home
            }
            footerTab(icon: "checklist", label: "Tasks", active: currentView == .tasks) {
                currentView = .tasks
            }
            footerTab(icon: "gear", label: "Settings", active: currentView == .settings) {
                currentView = .settings
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func footerTab(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(active ? Color.avaBrightBlue : Color.navy.opacity(0.35))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Inline Pairing

    private var inlinePairingView: some View {
        VStack(spacing: 0) {
            inlineNav(title: "Pair") {
                appState.pairingService.cancelPairing()
                currentView = .home
            }

            Spacer()

            VStack(spacing: 20) {
                switch appState.pairingService.state {
                case .generating:
                    ProgressView().controlSize(.large)
                    Text("Generating...")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)

                case .waitingForScan:
                    if let qrImage = appState.pairingService.qrImage {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 180, height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    if let code = appState.pairingService.pairingCode {
                        Text(code)
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.navy)
                    }

                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for scan...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .paired:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.avaGreen)
                    Text("Paired")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.navy)

                case .error(let msg):
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.navy.opacity(0.4))
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Button("Retry") {
                        Task { await appState.pairingService.startPairing() }
                    }
                    .buttonStyle(AVASecondaryButtonStyle())

                case .idle:
                    EmptyView()
                }
            }

            Spacer()

            Text("Scan with AVA on your iPhone")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .task {
            if appState.pairingService.state == .idle {
                await appState.pairingService.startPairing()
            }
        }
    }

    // MARK: - Inline Tasks

    private var inlineTasksView: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image("MenuBarIcon")
                    .resizable()
                    .renderingMode(.template)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(Color.navy)

                Text("Tasks")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.navy)

                Spacer()

                statusBadgeView
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            AVADivider()

            // Full tasks view
            TasksSection(apiService: appState.apiService)
                .padding(.top, 8)

            Spacer()

            // Credits at bottom
            CreditsSection(apiService: appState.apiService)

            AVADivider()
            footerView
        }
    }

    // MARK: - Inline Settings

    private var inlineSettingsView: some View {
        VStack(spacing: 0) {
            // Same header as home
            HStack(spacing: 10) {
                Image("MenuBarIcon")
                    .resizable()
                    .renderingMode(.template)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(Color.navy)

                Text("Settings")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.navy)

                Spacer()

                statusBadgeView
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            AVADivider()

            ScrollView {
                VStack(spacing: 0) {
                    // Permissions
                    ForEach(Array(CommandCategory.allCases.enumerated()), id: \.element.rawValue) { index, cat in
                        VStack(spacing: 0) {
                            HStack {
                                Image(systemName: cat.icon)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(Color.navy)
                                    .frame(width: 28)
                                Text(simpleName(cat))
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.navy)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { appState.permissionManager.isCategoryEnabled(cat) },
                                    set: { appState.permissionManager.setCategory(cat, enabled: $0) }
                                ))
                                .toggleStyle(.ava)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)

                            // Separator between rows (not after last)
                            if index < CommandCategory.allCases.count - 1 {
                                Rectangle()
                                    .fill(Color(.separatorColor).opacity(0.3))
                                    .frame(height: 0.5)
                                    .padding(.leading, 68)
                                    .padding(.trailing, 20)
                            }
                        }
                    }

                    AVADivider().padding(.vertical, 8)

                    // Launch at Login
                    HStack {
                        Image(systemName: "sunrise")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Color.navy)
                            .frame(width: 28)
                        Text("Launch at Login")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.navy)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { LaunchAtLogin.isEnabled },
                            set: { LaunchAtLogin.setEnabled($0) }
                        ))
                        .toggleStyle(.ava)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)

                    AVADivider().padding(.vertical, 8)

                    // Disconnect
                    if appState.authStore.isPaired {
                        Button(action: {
                            Task {
                                await appState.disconnect()
                                currentView = .home
                            }
                        }) {
                            HStack {
                                Image(systemName: "link.badge.plus")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(Color.navy.opacity(0.5))
                                    .frame(width: 28)
                                Text("Disconnect")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.navy.opacity(0.5))
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }

                    #if DEBUG
                    AVADivider().padding(.vertical, 4)
                    Button(action: {
                        currentView = .home
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            Task {
                                let testReq = CommandRequest(
                                    type: "req", id: UUID().uuidString,
                                    command: .terminal, action: "execute",
                                    params: ["command": .string("echo Hello from AVA")]
                                )
                                let resp = await appState.commandRouter.execute(testReq)
                                appState.debugLastTestResult = resp.ok ? "Allowed" : (resp.error?.message ?? "Denied")
                            }
                        }
                    }) {
                        HStack {
                            Image(systemName: "play.circle")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Color.navy)
                                .frame(width: 28)
                            Text("Test Permission")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.navy)
                            Spacer()
                            if let result = appState.debugLastTestResult {
                                Text(result)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        ControlOverlayManager.shared.show()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            ControlOverlayManager.shared.hide()
                        }
                    }) {
                        HStack {
                            Image(systemName: "rectangle.dashed")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Color.navy)
                                .frame(width: 28)
                            Text("Test Control UI")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.navy)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    #endif
                }
                .padding(.vertical, 8)
            }

            AVADivider()
            footerView
        }
    }

    // MARK: - Helpers

    private func inlineNav(title: String, onBack: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.navy.opacity(0.5))
            }
            .buttonStyle(.plain)

            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.navy)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func simpleName(_ cat: CommandCategory) -> String {
        switch cat {
        case .file: return "Files"
        case .terminal: return "Terminal"
        case .screenshot: return "Screenshots"
        case .app: return "Apps"
        case .clipboard: return "Clipboard"
        case .applescript: return "AppleScript"
        case .input: return "Input"
        case .system: return "System Info"
        case .notify: return "Notifications"
        case .codeReview: return "Code Review"
        case .codebase: return "Codebase"
        case .accessibility: return "UI Elements"
        case .browser: return "Browser"
        case .window: return "Windows"
        case .process: return "Processes"
        case .recording: return "Recording"
        case .url: return "URLs"
        case .vision: return "Vision"
        case .camera: return "Camera"
        case .location: return "Location"
        case .pim: return "Contacts"
        case .mcp: return "MCP"
        case .cliGen: return "CLI Gen"
        case .systemControl: return "Controls"
        case .watch: return "File Watch"
        case .automation: return "Automation"
        }
    }
}
