import Foundation

enum WeatherLocationSource: String, Codable, Sendable {
    case japaneseRegion
    case search
    case currentLocation
}

struct WeatherLocation: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let administrativeArea: String?
    let country: String?
    let countryCode: String?
    let latitude: Double
    let longitude: Double
    let timezoneIdentifier: String?
    let source: WeatherLocationSource
    let legacyRegionID: String?

    static let defaultLocation = from(region: .defaultRegion)

    static func from(region: WeatherRegion) -> WeatherLocation {
        WeatherLocation(
            id: region.id,
            name: region.representativeCityJapanese,
            administrativeArea: region.japaneseName,
            country: "日本",
            countryCode: "JP",
            latitude: region.latitude,
            longitude: region.longitude,
            timezoneIdentifier: "Asia/Tokyo",
            source: .japaneseRegion,
            legacyRegionID: region.id
        )
    }

    static func current(latitude: Double, longitude: Double) -> WeatherLocation {
        let cacheLatitude = roundedCoordinate(latitude, places: 2)
        let cacheLongitude = roundedCoordinate(longitude, places: 2)
        return WeatherLocation(
            id: "current:\(cacheLatitude),\(cacheLongitude)",
            name: "",
            administrativeArea: nil,
            country: nil,
            countryCode: nil,
            latitude: roundedCoordinate(latitude, places: 5),
            longitude: roundedCoordinate(longitude, places: 5),
            timezoneIdentifier: TimeZone.current.identifier,
            source: .currentLocation,
            legacyRegionID: nil
        )
    }

    func displayName(language: AppLanguage) -> String {
        if source == .currentLocation {
            return language == .japanese ? "現在地" : "Current location"
        }
        if let legacyRegionID,
           let region = WeatherRegion.region(id: legacyRegionID) {
            return region.representativeCity(language: language)
        }
        return name
    }

    func detail(language: AppLanguage) -> String {
        if source == .currentLocation {
            return coordinateSummary
        }
        if let legacyRegionID,
           let region = WeatherRegion.region(id: legacyRegionID) {
            return language == .japanese
                ? "\(region.japaneseName)・日本"
                : "\(region.englishName), Japan"
        }

        let components = [administrativeArea, country]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty, value != name else { return nil }
                return value
            }
        return components.isEmpty ? coordinateSummary : components.joined(separator: language == .japanese ? "・" : ", ")
    }

    var coordinateSummary: String {
        String(
            format: "%.3f, %.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            latitude,
            longitude
        )
    }

    private static func roundedCoordinate(_ value: Double, places: Int) -> Double {
        let multiplier = pow(10.0, Double(places))
        return (value * multiplier).rounded() / multiplier
    }
}

enum WeatherTemperatureUnitOption: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case celsius
    case fahrenheit

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch (self, language) {
        case (.automatic, .japanese):
            return "自動"
        case (.automatic, .english):
            return "Auto"
        case (.celsius, _):
            return "℃"
        case (.fahrenheit, _):
            return "℉"
        }
    }

    func resolvedScale(
        for location: WeatherLocation,
        locale: Locale = .current
    ) -> WeatherTemperatureScale {
        switch self {
        case .celsius:
            return .celsius
        case .fahrenheit:
            return .fahrenheit
        case .automatic:
            if let countryCode = location.countryCode?.uppercased() {
                return Self.fahrenheitCountryCodes.contains(countryCode) ? .fahrenheit : .celsius
            }
            return locale.measurementSystem == .us ? .fahrenheit : .celsius
        }
    }

    private static let fahrenheitCountryCodes: Set<String> = [
        "BS", "BZ", "KY", "FM", "MH", "PW", "US"
    ]
}

enum WeatherTemperatureScale: String, Codable, Equatable, Sendable {
    case celsius
    case fahrenheit

    var queryValue: String { rawValue }
}
