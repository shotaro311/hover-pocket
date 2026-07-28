import Foundation

struct WeatherForecast: Codable, Equatable, Sendable {
    let locationID: String
    let currentTemperature: Double
    let currentCondition: WeatherCondition
    let today: WeatherForecastDay
    let upcomingDays: [WeatherForecastDay]
    let fetchedAt: Date
    let timezoneIdentifier: String
    let temperatureScale: WeatherTemperatureScale

    private enum CodingKeys: String, CodingKey {
        case locationID
        case legacyRegionID = "regionID"
        case currentTemperature
        case currentCondition
        case today
        case upcomingDays
        case fetchedAt
        case timezoneIdentifier
        case temperatureScale
    }

    init(
        locationID: String,
        currentTemperature: Double,
        currentCondition: WeatherCondition,
        today: WeatherForecastDay,
        upcomingDays: [WeatherForecastDay],
        fetchedAt: Date,
        timezoneIdentifier: String,
        temperatureScale: WeatherTemperatureScale
    ) {
        self.locationID = locationID
        self.currentTemperature = currentTemperature
        self.currentCondition = currentCondition
        self.today = today
        self.upcomingDays = upcomingDays
        self.fetchedAt = fetchedAt
        self.timezoneIdentifier = timezoneIdentifier
        self.temperatureScale = temperatureScale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        locationID = try container.decodeIfPresent(String.self, forKey: .locationID)
            ?? container.decode(String.self, forKey: .legacyRegionID)
        currentTemperature = try container.decode(Double.self, forKey: .currentTemperature)
        currentCondition = try container.decode(WeatherCondition.self, forKey: .currentCondition)
        today = try container.decode(WeatherForecastDay.self, forKey: .today)
        upcomingDays = try container.decode([WeatherForecastDay].self, forKey: .upcomingDays)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        timezoneIdentifier = try container.decode(String.self, forKey: .timezoneIdentifier)
        temperatureScale = try container.decodeIfPresent(
            WeatherTemperatureScale.self,
            forKey: .temperatureScale
        ) ?? .celsius
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(locationID, forKey: .locationID)
        try container.encode(currentTemperature, forKey: .currentTemperature)
        try container.encode(currentCondition, forKey: .currentCondition)
        try container.encode(today, forKey: .today)
        try container.encode(upcomingDays, forKey: .upcomingDays)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(timezoneIdentifier, forKey: .timezoneIdentifier)
        try container.encode(temperatureScale, forKey: .temperatureScale)
    }
}

struct WeatherForecastDay: Codable, Identifiable, Equatable, Sendable {
    let date: Date
    let condition: WeatherCondition
    let highTemperature: Double
    let lowTemperature: Double
    let precipitationProbability: Int

    var id: Date {
        date
    }
}

enum WeatherCondition: String, Codable, Equatable, Sendable {
    case clear
    case mostlyClear
    case cloudy
    case fog
    case drizzle
    case rain
    case freezingRain
    case snow
    case showers
    case thunderstorm
    case unknown

    init(wmoCode: Int) {
        switch wmoCode {
        case 0:
            self = .clear
        case 1, 2:
            self = .mostlyClear
        case 3:
            self = .cloudy
        case 45, 48:
            self = .fog
        case 51, 53, 55:
            self = .drizzle
        case 56, 57, 66, 67:
            self = .freezingRain
        case 61, 63, 65:
            self = .rain
        case 71, 73, 75, 77, 85, 86:
            self = .snow
        case 80, 81, 82:
            self = .showers
        case 95, 96, 99:
            self = .thunderstorm
        default:
            self = .unknown
        }
    }

    var symbolName: String {
        switch self {
        case .clear:
            return "sun.max.fill"
        case .mostlyClear:
            return "cloud.sun.fill"
        case .cloudy:
            return "cloud.fill"
        case .fog:
            return "cloud.fog.fill"
        case .drizzle:
            return "cloud.drizzle.fill"
        case .rain, .freezingRain:
            return "cloud.rain.fill"
        case .snow:
            return "cloud.snow.fill"
        case .showers:
            return "cloud.heavyrain.fill"
        case .thunderstorm:
            return "cloud.bolt.rain.fill"
        case .unknown:
            return "cloud.fill"
        }
    }

    var symbolMotionPreset: WeatherSymbolMotionPreset {
        switch self {
        case .clear:
            return .solarRotation
        case .mostlyClear:
            return .partlyCloudyRotation
        case .cloudy, .fog, .unknown:
            return .cloudBreathing
        case .drizzle, .rain, .freezingRain, .showers:
            return .precipitationCycle
        case .snow:
            return .snowDrift
        case .thunderstorm:
            return .thunderPulse
        }
    }

    func title(language: AppLanguage) -> String {
        switch (self, language) {
        case (.clear, .japanese):
            return "晴れ"
        case (.mostlyClear, .japanese):
            return "晴れ時々くもり"
        case (.cloudy, .japanese):
            return "くもり"
        case (.fog, .japanese):
            return "霧"
        case (.drizzle, .japanese):
            return "霧雨"
        case (.rain, .japanese):
            return "雨"
        case (.freezingRain, .japanese):
            return "凍雨"
        case (.snow, .japanese):
            return "雪"
        case (.showers, .japanese):
            return "にわか雨"
        case (.thunderstorm, .japanese):
            return "雷雨"
        case (.unknown, .japanese):
            return "天気不明"
        case (.clear, .english):
            return "Clear"
        case (.mostlyClear, .english):
            return "Partly cloudy"
        case (.cloudy, .english):
            return "Cloudy"
        case (.fog, .english):
            return "Fog"
        case (.drizzle, .english):
            return "Drizzle"
        case (.rain, .english):
            return "Rain"
        case (.freezingRain, .english):
            return "Freezing rain"
        case (.snow, .english):
            return "Snow"
        case (.showers, .english):
            return "Showers"
        case (.thunderstorm, .english):
            return "Thunderstorm"
        case (.unknown, .english):
            return "Unknown"
        }
    }
}

enum WeatherSymbolMotionPreset: String, Equatable, Sendable {
    case solarRotation
    case partlyCloudyRotation
    case cloudBreathing
    case precipitationCycle
    case snowDrift
    case thunderPulse
}
