import Foundation
import CoreLocation
import os

/// Handles desktop_location commands: get.
/// Matches OpenClaw's location.get.
struct LocationHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "Location")

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        switch request.action {
        case "get":
            return await getLocation(id: request.id)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown location action: \(request.action)")
        }
    }

    private func getLocation(id: String) async -> CommandResponse {
        let locator = SingleLocationFetcher()

        do {
            let location = try await locator.fetch()
            return .success(id: id, payload: [
                "latitude": .double(location.coordinate.latitude),
                "longitude": .double(location.coordinate.longitude),
                "altitude": .double(location.altitude),
                "accuracy": .double(location.horizontalAccuracy),
                "timestamp": .string(location.timestamp.ISO8601Format()),
            ])
        } catch {
            return .permissionMissing(id: id, permission: "Location Services")
        }
    }
}

// MARK: - Single Location Fetch

private class SingleLocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    func fetch() async throws -> CLLocation {
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyBest

            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorized:
                manager.requestLocation()
            default:
                cont.resume(throwing: LocationError.denied)
                self.continuation = nil
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized:
            manager.requestLocation()
        case .denied, .restricted:
            continuation?.resume(throwing: LocationError.denied)
            continuation = nil
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else { return }
        continuation?.resume(returning: location)
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    enum LocationError: LocalizedError {
        case denied
        var errorDescription: String? { "Location access denied" }
    }
}
