import SwiftUI

/// Credits display — glass theme, navy text, light blue progress bar.
struct CreditsSection: View {
    let apiService: APIService
    @State private var usage: APIService.OfficeUsage?
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let usage {
                HStack(spacing: 10) {
                    Text(usage.tier.capitalized)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.navy.opacity(0.5))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(formatCredits(usage.creditsUsed))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.navy)
                            Text("/ \(formatCredits(usage.creditsLimit))")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(usage.monthlyRatio * 100))%")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.navy.opacity(0.06))
                                    .frame(height: 4)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.avaBrightBlue)
                                    .frame(width: max(0, geo.size.width * min(usage.monthlyRatio, 1.0)), height: 4)
                            }
                        }
                        .frame(height: 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
        .task { await fetchUsage() }
        .onAppear { startRefreshing() }
        .onDisappear { refreshTask?.cancel() }
    }

    private func fetchUsage() async {
        usage = try? await apiService.fetchUsage().offices.first
    }

    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await fetchUsage()
            }
        }
    }

    private func formatCredits(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", Double(value) / 1_000) }
        return "\(value)"
    }
}
