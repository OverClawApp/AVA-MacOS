import SwiftUI

// MARK: - AVA Design System — Liquid Glass

extension Color {
    static let navy = Color(red: 0.10, green: 0.13, blue: 0.22)
    static let avaBrightBlue = Color(red: 0.30, green: 0.60, blue: 1.0)
    static let avaDeepIndigo = Color(red: 0.10, green: 0.20, blue: 0.55)
    static let avaLightBlue = Color(red: 0.85, green: 0.92, blue: 1.0)
    static let avaDeepCrimson = Color(red: 0.55, green: 0.12, blue: 0.15)
    static let avaBrightRed = Color(red: 0.90, green: 0.30, blue: 0.30)
    static let avaLightRed = Color(red: 0.96, green: 0.89, blue: 0.89)
    static let avaCream = Color(red: 0.96, green: 0.95, blue: 0.93)
    static let avaGreen = Color(red: 0.30, green: 0.85, blue: 0.45)
}

// Keep gradient definitions for backward compat (used in CreditsSection, etc.)
extension LinearGradient {
    static let avaBlue = LinearGradient(
        colors: [Color(red: 0.30, green: 0.60, blue: 1.0), Color(red: 0.15, green: 0.45, blue: 0.95), Color(red: 0.10, green: 0.20, blue: 0.55)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let avaRed = LinearGradient(
        colors: [Color(red: 0.90, green: 0.30, blue: 0.30), Color(red: 0.55, green: 0.12, blue: 0.15), Color(red: 0.40, green: 0.08, blue: 0.20)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

// MARK: - Glass Card

struct AVACardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

extension View {
    func avaCard() -> some View {
        modifier(AVACardStyle())
    }
}

// MARK: - Flat Row (iOS settings pattern)

struct AVAFlatRow: View {
    let icon: String
    let title: String
    var showChevron: Bool = true

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.navy)
                .frame(width: 28)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.navy)
            Spacer()
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - Buttons (glass style)

struct AVAPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color.navy.opacity(configuration.isPressed ? 0.8 : 1.0))
            .clipShape(Capsule())
    }
}

struct AVASecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.navy)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - Dividers (iOS separator style)

struct AVADivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(.separatorColor).opacity(0.5))
            .frame(height: 1)
            .padding(.horizontal, 20)
    }
}
