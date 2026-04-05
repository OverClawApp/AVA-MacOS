import SwiftUI

/// Settings window — white background, navy text, card-based layout matching iOS.
struct SettingsView: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.navy)
                    Text("AVA Desktop")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.navy.opacity(0.5))
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.navy.opacity(0.4))
                        .frame(width: 28, height: 28)
                        .background(Color.navy.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            Divider().padding(.horizontal, 24)

            ScrollView {
                VStack(spacing: 16) {
                    permissionsSection
                    allowlistSection
                    generalSection
                    connectionSection
                }
                .padding(24)
            }
        }
        .frame(width: 420, height: 560)
        .background(.white)
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "lock.shield", title: "Permissions")

            Text("Control which capabilities your AI agents can use.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.navy.opacity(0.4))

            VStack(spacing: 2) {
                ForEach(CommandCategory.allCases, id: \.rawValue) { category in
                    permissionRow(category)
                }
            }
        }
        .avaCard()
    }

    private func permissionRow(_ category: CommandCategory) -> some View {
        HStack(spacing: 10) {
            Image(systemName: category.icon)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(gradientForRisk(category.defaultRisk))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 1) {
                Text(category.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.navy)

                Text(riskLabel(category.defaultRisk))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(riskColor(category.defaultRisk).opacity(0.8))
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { appState.permissionManager.isCategoryEnabled(category) },
                set: { appState.permissionManager.setCategory(category, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Color.avaBrightBlue)
        }
        .padding(.vertical, 6)
    }

    private func gradientForRisk(_ risk: RiskLevel) -> LinearGradient {
        switch risk {
        case .low:
            return LinearGradient(colors: [Color.avaGreen, Color.avaGreen.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .medium:
            return .avaBlue
        case .high:
            return .avaRed
        }
    }

    private func riskLabel(_ risk: RiskLevel) -> String {
        switch risk {
        case .low: return "Auto-approved"
        case .medium: return "Asks first time"
        case .high: return "Always asks"
        }
    }

    private func riskColor(_ risk: RiskLevel) -> Color {
        switch risk {
        case .low: return Color.avaGreen
        case .medium: return Color.avaBrightBlue
        case .high: return Color.avaBrightRed
        }
    }

    // MARK: - Allowlist

    private var allowlistSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader(icon: "list.bullet.rectangle", title: "Allowlist")
                Spacer()
                if !appState.permissionManager.allowlist.isEmpty {
                    Button("Clear All") {
                        appState.permissionManager.clearAllowlist()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.avaBrightRed)
                    .buttonStyle(.plain)
                }
            }

            if appState.permissionManager.allowlist.isEmpty {
                Text("No durable approvals yet. Choosing \"Allow Always\" for a command adds it here.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.navy.opacity(0.35))
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(appState.permissionManager.allowlist).sorted(), id: \.self) { pattern in
                        HStack {
                            Text(pattern)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.navy.opacity(0.7))
                            Spacer()
                            Button(action: {
                                appState.permissionManager.removeFromAllowlist(pattern)
                            }) {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.avaBrightRed.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color.navy.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .avaCard()
    }

    // MARK: - General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "gear", title: "General")

            Toggle(isOn: Binding(
                get: { LaunchAtLogin.isEnabled },
                set: { LaunchAtLogin.setEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at Login")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.navy)
                    Text("Start automatically when you log in")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.navy.opacity(0.4))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Color.avaBrightBlue)
        }
        .avaCard()
    }

    // MARK: - Connection

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "link", title: "Connection")

            if appState.authStore.isPaired {
                Button(action: {
                    Task { await appState.disconnect() }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 12))
                        Text("Disconnect & Unpair")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Color.avaBrightRed)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.avaBrightRed.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            } else {
                Text("Not paired. Use the menu bar to connect your iPhone.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.navy.opacity(0.4))
            }
        }
        .avaCard()
    }

    // MARK: - Helpers

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.navy.opacity(0.6))
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.navy)
        }
    }
}
