import CoreLocation
import Foundation

@MainActor
final class WeatherLocationSettingsModel: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published var searchText = ""
    @Published private(set) var searchResults: [WeatherLocation] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isLocating = false
    @Published private(set) var message: String?

    private let searchService: WeatherLocationSearchService
    private var locationManager: CLLocationManager?
    private let makeLocationManager: () -> CLLocationManager
    private let locationServicesEnabled: () -> Bool
    private let locationTimeout: Duration
    private var locationTimeoutTask: Task<Void, Never>?
    private var isRequestingLocation = false
    private var searchTask: Task<Void, Never>?
    private var locationCompletion: ((WeatherLocation?) -> Void)?
    private var locationLanguage: AppLanguage = .japanese

    init(
        searchService: WeatherLocationSearchService = WeatherLocationSearchService(),
        makeLocationManager: @escaping () -> CLLocationManager = { CLLocationManager() },
        locationServicesEnabled: @escaping () -> Bool = { CLLocationManager.locationServicesEnabled() },
        locationTimeout: Duration = .seconds(20)
    ) {
        self.searchService = searchService
        self.makeLocationManager = makeLocationManager
        self.locationServicesEnabled = locationServicesEnabled
        self.locationTimeout = locationTimeout
        super.init()
    }

    func search(language: AppLanguage) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            searchResults = []
            message = language == .japanese
                ? "都市名または郵便番号を2文字以上入力してください。"
                : "Enter at least two characters for a city or postal code."
            return
        }

        searchTask?.cancel()
        searchResults = []
        isSearching = true
        message = nil
        searchTask = Task { [weak self, searchService] in
            do {
                let results = try await searchService.search(query: query, language: language)
                guard !Task.isCancelled else { return }
                self?.searchResults = results
                self?.isSearching = false
                self?.message = results.isEmpty
                    ? (language == .japanese ? "該当する地域が見つかりませんでした。" : "No matching locations found.")
                    : nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.searchResults = []
                self?.isSearching = false
                self?.message = Self.safeMessage(error, language: language)
            }
        }
    }

    func clearSearch() {
        cancelCurrentLocation()
        searchResults = []
        searchText = ""
        message = nil
    }

    func requestCurrentLocation(
        language: AppLanguage,
        completion: @escaping (WeatherLocation?) -> Void
    ) {
        guard !isLocating else { return }
        guard locationServicesEnabled() else {
            message = language == .japanese
                ? "macOSの位置情報サービスが無効です。"
                : "Location Services are disabled in macOS."
            completion(nil)
            return
        }

        locationCompletion = completion
        locationLanguage = language
        isLocating = true
        message = nil
        let locationManager = makeLocationManager()
        self.locationManager = locationManager
        // Core Location delivers delegate callbacks on the manager's creation thread (MainActor).
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        locationTimeoutTask = Task { [weak self, locationTimeout] in
            do {
                try await Task.sleep(for: locationTimeout)
            } catch {
                return
            }
            guard let self else { return }
            self.finishLocation(nil, message: self.locationLanguage == .japanese
                ? "現在地を取得できませんでした。位置情報の許可とWi-Fiを確認して、もう一度お試しください。都市名での選択もできます。"
                : "Could not get your location. Check location permission and Wi-Fi, then try again, or select a city.")
        }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorized:
            requestLocationIfNeeded()
        case .denied, .restricted:
            finishLocation(
                nil,
                message: deniedLocationMessage(language: language)
            )
        @unknown default:
            finishLocation(
                nil,
                message: unavailableLocationMessage(language: language)
            )
        }
    }

    func cancelCurrentLocation() {
        finishLocation(nil, message: nil)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === locationManager else { return }
        handleAuthorizationChange()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager === locationManager else { return }
        guard let location = locations.last,
              location.horizontalAccuracy >= 0,
              CLLocationCoordinate2DIsValid(location.coordinate) else {
            finishLocation(nil, message: unavailableLocationMessage(language: locationLanguage))
            return
        }
        finishLocation(
            WeatherLocation.current(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
            message: nil
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard manager === locationManager else { return }
        let denied = (error as? CLError)?.code == .denied
        finishLocation(nil, message: denied
            ? deniedLocationMessage(language: locationLanguage)
            : unavailableLocationMessage(language: locationLanguage))
    }

    private func finishLocation(_ location: WeatherLocation?, message: String?) {
        guard isLocating else { return }
        locationTimeoutTask?.cancel()
        locationTimeoutTask = nil
        locationManager?.stopUpdatingLocation()
        locationManager?.delegate = nil
        locationManager = nil
        isRequestingLocation = false
        isLocating = false
        self.message = message
        let completion = locationCompletion
        locationCompletion = nil
        completion?(location)
    }

    private func handleAuthorizationChange() {
        guard isLocating, let locationManager else { return }
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorized:
            requestLocationIfNeeded()
        case .denied, .restricted:
            finishLocation(nil, message: deniedLocationMessage(language: locationLanguage))
        case .notDetermined:
            break
        @unknown default:
            finishLocation(nil, message: unavailableLocationMessage(language: locationLanguage))
        }
    }

    private func requestLocationIfNeeded() {
        guard !isRequestingLocation, let locationManager else { return }
        isRequestingLocation = true
        locationManager.requestLocation()
    }

    private static func safeMessage(_ error: Error, language: AppLanguage) -> String {
        if let searchError = error as? WeatherLocationSearchError {
            return searchError.message(language: language)
        }
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return language == .japanese
            ? "地域を検索できませんでした。"
            : "Could not search for locations."
    }

    private func deniedLocationMessage(language: AppLanguage) -> String {
        language == .japanese
            ? "位置情報が許可されていません。システム設定から許可できます。"
            : "Location access is denied. You can enable it in System Settings."
    }

    private func unavailableLocationMessage(language: AppLanguage) -> String {
        language == .japanese
            ? "現在地を取得できませんでした。"
            : "Could not get the current location."
    }
}
