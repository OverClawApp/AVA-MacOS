import Foundation
import CoreImage
import AppKit
import os

/// QR code pairing flow:
/// 1. POST /desktop/pair → get pairing code
/// 2. Generate QR code containing pairing URL
/// 3. User scans with AVA iOS app
/// 4. Backend links desktop to user account
/// 5. Poll for completion → receive JWT tokens
@Observable
final class PairingService {
    private let logger = Logger(subsystem: Constants.bundleID, category: "Pairing")
    private let authStore: AuthStore

    private(set) var pairingCode: String?
    private(set) var qrImage: NSImage?
    private(set) var state: PairingState = .idle
    private var pollTask: Task<Void, Never>?
    private var pairingSecret: String?

    enum PairingState: Equatable {
        case idle
        case generating
        case waitingForScan
        case paired
        case error(String)
    }

    init(authStore: AuthStore) {
        self.authStore = authStore
    }

    // MARK: - Start Pairing

    func startPairing() async {
        state = .generating

        guard let url = URL(string: "\(Constants.apiBaseURL)\(Constants.pairEndpoint)") else {
            state = .error("Invalid API URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "deviceId": authStore.deviceId,
            "platform": "macos",
            "name": Host.current().localizedName ?? "Mac",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                state = .error("Server error (\(statusCode))")
                return
            }

            let result = try JSONDecoder().decode(PairResponse.self, from: data)
            pairingCode = result.code
            pairingSecret = result.secret

            // Generate QR code — deep link for AVA iOS app
            let pairingURL = "ava://pair/\(result.code)"
            qrImage = generateQRCode(from: pairingURL)

            state = .waitingForScan
            logger.info("Pairing code generated: \(result.code)")

            // Start polling for completion
            startPolling(code: result.code, secret: result.secret)

        } catch {
            state = .error("Failed to generate pairing code")
            logger.error("Pairing error: \(error)")
        }
    }

    func cancelPairing() {
        pollTask?.cancel()
        pairingCode = nil
        qrImage = nil
        state = .idle
    }

    // MARK: - Poll for Completion

    private func startPolling(code: String, secret: String) {
        pollTask?.cancel()
        pollTask = Task {
            // Poll every 2 seconds for up to 5 minutes
            for _ in 0..<150 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(2))

                guard let url = URL(string: "\(Constants.apiBaseURL)\(Constants.pairEndpoint)/\(code)/status?secret=\(secret)") else { continue }

                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }

                    let result = try JSONDecoder().decode(PairStatusResponse.self, from: data)

                    if result.paired, let token = result.token, let refresh = result.refreshToken, let userId = result.userId {
                        await MainActor.run {
                            authStore.storeTokens(accessToken: token, refreshToken: refresh, userId: userId)
                            state = .paired
                        }
                        logger.info("Pairing completed for user \(userId)")
                        return
                    }
                } catch {
                    logger.debug("Poll error (will retry): \(error)")
                }
            }

            // Timeout
            await MainActor.run {
                state = .error("Pairing timed out. Try again.")
            }
        }
    }

    // MARK: - QR Code Generation

    private func generateQRCode(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8) else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let output = filter.outputImage else { return nil }

        // Scale up for clarity
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaled = output.transformed(by: scale)

        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Response Models

    private struct PairResponse: Decodable {
        let code: String
        let secret: String
    }

    private struct PairStatusResponse: Decodable {
        let paired: Bool
        let token: String?
        let refreshToken: String?
        let userId: String?
    }
}
