import Foundation
import os

/// Manages JWT authentication tokens and device identity.
/// Tokens stored in Keychain, device ID persisted across sessions.
@Observable
final class AuthStore: @unchecked Sendable {
    private let logger = Logger(subsystem: Constants.bundleID, category: "Auth")

    private(set) var isPaired: Bool = false
    private(set) var userId: String?

    var accessToken: String? {
        KeychainHelper.load(key: Constants.keychainAccessTokenKey)
    }

    var refreshToken: String? {
        KeychainHelper.load(key: Constants.keychainRefreshTokenKey)
    }

    /// Stable device identifier — persisted in Keychain across app launches
    var deviceId: String {
        if let existing = KeychainHelper.load(key: Constants.keychainDeviceIdKey) {
            return existing
        }
        let newId = UUID().uuidString
        KeychainHelper.save(key: Constants.keychainDeviceIdKey, value: newId)
        return newId
    }

    init() {
        isPaired = accessToken != nil
    }

    // MARK: - Token Management

    func storeTokens(accessToken: String, refreshToken: String, userId: String) {
        KeychainHelper.save(key: Constants.keychainAccessTokenKey, value: accessToken)
        KeychainHelper.save(key: Constants.keychainRefreshTokenKey, value: refreshToken)
        self.userId = userId
        self.isPaired = true
        logger.info("Tokens stored for user \(userId)")
    }

    func clearTokens() {
        KeychainHelper.delete(key: Constants.keychainAccessTokenKey)
        KeychainHelper.delete(key: Constants.keychainRefreshTokenKey)
        self.userId = nil
        self.isPaired = false
        logger.info("Tokens cleared")
    }

    // MARK: - Token Refresh

    func refreshAccessToken() async -> Bool {
        guard let refresh = refreshToken else {
            logger.error("No refresh token available")
            return false
        }

        guard let url = URL(string: "\(Constants.apiBaseURL)/auth/refresh") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["refreshToken": refresh]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                logger.error("Token refresh failed (status \((response as? HTTPURLResponse)?.statusCode ?? 0)) — keeping existing tokens")
                return false
            }

            let result = try JSONDecoder().decode(RefreshResponse.self, from: data)
            storeTokens(accessToken: result.token, refreshToken: result.refreshToken, userId: userId ?? "")
            logger.info("Token refreshed")
            return true
        } catch {
            logger.error("Token refresh error: \(error)")
            return false
        }
    }

    private struct RefreshResponse: Decodable {
        let token: String
        let refreshToken: String
    }
}
