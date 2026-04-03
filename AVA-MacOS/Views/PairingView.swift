import SwiftUI

/// QR code pairing window — white background, navy text, blue gradient header.
struct PairingView: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Blue gradient header
            VStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.white)

                Text("Pair with AVA")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)

                Text("Scan this code with your AVA iOS app")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
            .background(LinearGradient.avaBlue)

            // Content
            VStack(spacing: 20) {
                // QR Code
                qrCodeSection
                    .padding(.top, 20)

                // Status
                statusSection

                // Actions
                actionButtons
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .frame(width: 380, height: 500)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .task {
            if appState.pairingService.state == .idle {
                await appState.pairingService.startPairing()
            }
        }
        .onChange(of: appState.pairingService.state) { _, newState in
            if newState == .paired {
                Task { await appState.connectIfPaired() }
            }
        }
    }

    // MARK: - QR Code

    @ViewBuilder
    private var qrCodeSection: some View {
        switch appState.pairingService.state {
        case .generating:
            ProgressView()
                .controlSize(.large)
                .frame(width: 200, height: 200)

        case .waitingForScan:
            if let qrImage = appState.pairingService.qrImage {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .padding(12)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            }

        case .paired:
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.avaGreen)
                Text("Paired!")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.navy)
            }
            .frame(width: 200, height: 200)

        case .error:
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.avaBrightRed)
            }
            .frame(width: 200, height: 200)

        case .idle:
            Color.clear.frame(width: 200, height: 200)
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        switch appState.pairingService.state {
        case .generating:
            Text("Generating pairing code...")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.navy.opacity(0.5))

        case .waitingForScan:
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for scan...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.navy.opacity(0.5))
                }

                if let code = appState.pairingService.pairingCode {
                    Text(code)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.navy)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.navy.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

        case .paired:
            Text("Successfully connected to your AVA account")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.avaGreen)
                .multilineTextAlignment(.center)

        case .error(let message):
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.avaBrightRed)
                .multilineTextAlignment(.center)

        case .idle:
            EmptyView()
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionButtons: some View {
        switch appState.pairingService.state {
        case .waitingForScan:
            Button("Cancel") {
                appState.pairingService.cancelPairing()
                dismiss()
            }
            .buttonStyle(AVASecondaryButtonStyle())

        case .error:
            HStack(spacing: 12) {
                Button("Try Again") {
                    Task { await appState.pairingService.startPairing() }
                }
                .buttonStyle(AVAPrimaryButtonStyle())

                Button("Close") { dismiss() }
                    .buttonStyle(AVASecondaryButtonStyle())
            }

        case .paired:
            Button("Done") {
                Task { await appState.connectIfPaired() }
                dismiss()
            }
            .buttonStyle(AVAPrimaryButtonStyle())

        default:
            EmptyView()
        }
    }
}
