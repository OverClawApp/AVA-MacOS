import SwiftUI
import AppKit

/// Full-screen overlay shown when AVA is controlling the computer.
/// Blue glow border around the entire screen + floating pill indicator.
class ControlOverlayManager {
    static let shared = ControlOverlayManager()

    private var overlayWindow: NSWindow?
    private var pillWindow: NSWindow?
    private var glowAnimation: Timer?

    var isShowing: Bool { overlayWindow != nil }

    // MARK: - Show

    func show() {
        guard overlayWindow == nil else { return }
        guard let screen = NSScreen.main else { return }

        // Full-screen glow border window
        let overlay = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        overlay.level = .screenSaver
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary]
        overlay.hasShadow = false

        let glowView = NSHostingView(rootView: GlowBorderView())
        glowView.frame = screen.frame
        overlay.contentView = glowView

        overlay.orderFrontRegardless()
        overlayWindow = overlay

        // Floating pill indicator
        let pillWidth: CGFloat = 280
        let pillHeight: CGFloat = 36
        let pillX = screen.frame.midX - pillWidth / 2
        let pillY = screen.frame.maxY - 80 // Near top of screen

        let pill = NSWindow(
            contentRect: NSRect(x: pillX, y: pillY, width: pillWidth, height: pillHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        pill.level = .screenSaver
        pill.backgroundColor = .clear
        pill.isOpaque = false
        pill.ignoresMouseEvents = true
        pill.collectionBehavior = [.canJoinAllSpaces, .stationary]
        pill.hasShadow = true

        let pillView = NSHostingView(rootView: ControlPillView())
        pillView.frame = NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight)
        pill.contentView = pillView

        pill.orderFrontRegardless()
        pillWindow = pill
    }

    // MARK: - Hide

    func hide() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        pillWindow?.orderOut(nil)
        pillWindow = nil
    }
}

// MARK: - Glow Border (blue, animated)

struct GlowBorderView: View {
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Top edge glow
                LinearGradient(
                    colors: [Color.avaBrightBlue.opacity(pulse ? 0.8 : 0.55), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 140)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                // Bottom edge glow
                LinearGradient(
                    colors: [Color.avaBrightBlue.opacity(pulse ? 0.8 : 0.55), .clear],
                    startPoint: .bottom, endPoint: .top
                )
                .frame(height: 140)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                // Left edge glow
                LinearGradient(
                    colors: [Color.avaBrightBlue.opacity(pulse ? 0.7 : 0.45), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: 120)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                // Right edge glow
                LinearGradient(
                    colors: [Color.avaBrightBlue.opacity(pulse ? 0.7 : 0.45), .clear],
                    startPoint: .trailing, endPoint: .leading
                )
                .frame(width: 120)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

                // Corner accents
                RadialGradient(colors: [Color.avaBrightBlue.opacity(0.9), .clear], center: .topLeading, startRadius: 0, endRadius: 250)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                RadialGradient(colors: [Color.avaBrightBlue.opacity(0.9), .clear], center: .topTrailing, startRadius: 0, endRadius: 250)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                RadialGradient(colors: [Color.avaBrightBlue.opacity(0.9), .clear], center: .bottomLeading, startRadius: 0, endRadius: 250)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                RadialGradient(colors: [Color.avaBrightBlue.opacity(0.9), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 250)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .blur(radius: 30)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Floating Pill

struct ControlPillView: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            // Pulsing dot
            Circle()
                .fill(Color.avaBrightBlue)
                .frame(width: 8, height: 8)
                .scaleEffect(pulse ? 1.3 : 1.0)
                .opacity(pulse ? 0.6 : 1.0)

            Image("MenuBarIcon")
                .resizable()
                .renderingMode(.template)
                .frame(width: 14, height: 14)
                .foregroundStyle(Color.navy)

            Text("AVA is controlling your computer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.navy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: Color.avaBrightBlue.opacity(0.2), radius: 8, y: 2)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
