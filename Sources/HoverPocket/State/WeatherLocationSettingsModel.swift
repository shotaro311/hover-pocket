import CoreLocation
import Foundation

@MainActor
final class WeatherLocationSettingsModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var searchText = ""
    @Published private(set) var searchResults: [WeatherLocation] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isLocating = false
    @Published private(set) var message: String?

    private let searchService: WeatherLocationSearchService
    private let locationManager: CLLocationManager
    private var searchTask: Task<Void, Never>?
    private var locationCompletion: ((WeatherLocation?) -> Void)?
    private var locationLanguage: AppLanguage = .japanese

    init(
        searchService: WeatherLocationSearchService = WeatherLocationSearchService(),
        locationManager: CLLocationManager = CLLocationManager()
    ) {
        self.searchService = searchService
        self.locationManager = locationManager
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
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
        searchResults = []
        searchText = ""
        message = nil
    }

    func requestCurrentLocation(
        language: AppLanguage,
        completion: @escaping (WeatherLocation?) -> Void
    ) {
        guard CLLocationManager.locationServicesEnabled() else {
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

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorized:
            locationManager.requestLocation()
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

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.handleAuthorizationChange()
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        let location = locations.last
        Task { @MainActor [weak self] in
            guard let self, let location else {
                guard let self else { return }
                self.finishLocation(
                    nil,
                    message: self.unavailableLocationMessage(language: self.locationLanguage)
                )
                return
            }
            self.finishLocation(
                WeatherLocation.current(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                ),
                message: nil
            )
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.finishLocation(
                nil,
                message: self.unavailableLocationMessage(language: self.locationLanguage)
            )
        }
    }

    private func finishLocation(_ location: WeatherLocation?, message: String?) {
        isLocating = false
        self.message = message
        let completion = locationCompletion
        locationCompletion = nil
        completion?(location)
    }

    private func handleAuthorizationChange() {
        guard isLocating else { return }
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorized:
            locationManager.requestLocation()
        case .denied, .restricted:
            finishLocation(nil, message: deniedLocationMessage(language: locationLanguage))
        case .notDetermined:
            break
        @unknown default:
            finishLocation(nil, message: unavailableLocationMessage(language: locationLanguage))
        }
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
