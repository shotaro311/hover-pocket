import CoreLocation
import Foundation

enum WeatherLocationVerificationCommand {
    @MainActor
    static func run() async throws {
        func require(_ condition: Bool, _ name: String) throws {
            if !condition { throw NSError(domain: "WeatherLocationVerification", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: name]) }
        }

        let disabled = WeatherLocationSettingsModel(locationServicesEnabled: { false })
        var disabledCallbacks = 0
        disabled.requestCurrentLocation(language: .japanese) { _ in disabledCallbacks += 1 }
        try require(!disabled.isLocating && disabledCallbacks == 1 && disabled.message != nil, "disabled")

        let deniedManager = VerificationLocationManager()
        deniedManager.status = .denied
        let denied = WeatherLocationSettingsModel(makeLocationManager: { deniedManager }, locationServicesEnabled: { true })
        denied.requestCurrentLocation(language: .japanese) { _ in }
        try require(!denied.isLocating && denied.message != nil && deniedManager.locationRequests == 0, "denied")

        let waitingManager = VerificationLocationManager()
        let waiting = WeatherLocationSettingsModel(makeLocationManager: { waitingManager },
            locationServicesEnabled: { true }, locationTimeout: .milliseconds(10))
        var timeoutCallbacks = 0
        waiting.requestCurrentLocation(language: .japanese) { _ in timeoutCallbacks += 1 }
        for _ in 0..<100 where waiting.isLocating {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(!waiting.isLocating && waiting.message != nil && timeoutCallbacks == 1,
                    "timeout clears busy state (busy=\(waiting.isLocating), message=\(waiting.message != nil), callbacks=\(timeoutCallbacks))")
        try require(waitingManager.permissionRequests == 1 && waitingManager.delegate == nil, "permission wait stops")

        let firstManager = VerificationLocationManager()
        let secondManager = VerificationLocationManager()
        firstManager.status = .authorizedAlways
        secondManager.status = .authorizedAlways
        var managerIndex = 0
        let model = WeatherLocationSettingsModel(makeLocationManager: {
            managerIndex += 1
            return managerIndex == 1 ? firstManager : secondManager
        }, locationServicesEnabled: { true })
        var callbacks = 0
        var received: WeatherLocation?
        model.requestCurrentLocation(language: .japanese) { _ in callbacks += 1 }
        model.locationManagerDidChangeAuthorization(firstManager)
        try await Task.sleep(for: .milliseconds(10))
        try require(firstManager.locationRequests == 1, "authorization callback must not duplicate request")
        model.cancelCurrentLocation()
        try require(!model.isLocating && callbacks == 1 && firstManager.delegate == nil, "cancel")
        model.requestCurrentLocation(language: .japanese) { location in callbacks += 1; received = location }
        model.locationManager(firstManager, didUpdateLocations: [CLLocation(latitude: 1, longitude: 2)])
        model.locationManager(firstManager, didFailWithError: CLError(.locationUnknown))
        try await Task.sleep(for: .milliseconds(10))
        try require(model.isLocating && received == nil && callbacks == 1, "stale callbacks cannot complete retry")
        model.locationManager(secondManager, didUpdateLocations: [CLLocation(latitude: 3, longitude: 4)])
        try await Task.sleep(for: .milliseconds(10))
        try require(!model.isLocating && received?.source == .currentLocation && callbacks == 2, "success")
        try require(secondManager.delegate == nil && secondManager.stopRequests == 1, "success stops location service")

        let invalidManager = VerificationLocationManager()
        invalidManager.status = .authorizedAlways
        let invalid = WeatherLocationSettingsModel(makeLocationManager: { invalidManager }, locationServicesEnabled: { true })
        var invalidResult: WeatherLocation?
        invalid.requestCurrentLocation(language: .english) { invalidResult = $0 }
        invalid.locationManager(invalidManager, didUpdateLocations: [])
        try await Task.sleep(for: .milliseconds(10))
        try require(!invalid.isLocating && invalidResult == nil && invalid.message != nil, "empty result fails without overwriting location")
        print("PASS weather location: disabled, denied, timeout, cancel, retry, stale callback, success, empty result")
    }
}

private final class VerificationLocationManager: CLLocationManager {
    var status: CLAuthorizationStatus = .notDetermined
    var permissionRequests = 0
    var locationRequests = 0
    var stopRequests = 0

    override var authorizationStatus: CLAuthorizationStatus { status }
    override func requestWhenInUseAuthorization() { permissionRequests += 1 }
    override func requestLocation() { locationRequests += 1 }
    override func stopUpdatingLocation() { stopRequests += 1 }
}
