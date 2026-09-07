import Foundation

@MainActor
enum WeatherVoiceReader {
    static func read(store: WeatherForecastStore, location: WeatherLocation,
                     temperatureUnit: WeatherTemperatureUnitOption) async throws -> [String: Any] {
        let (forecast, warning) = try await store.forecastForVoice(location: location, temperatureUnit: temperatureUnit)
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.timeZone = TimeZone(identifier: forecast.timezoneIdentifier) ?? .current
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let days = ([forecast.today] + forecast.upcomingDays).map { day in
            ["date": dayFormatter.string(from: day.date),
             "condition": day.condition.title(language: .japanese),
             "high_temperature": day.highTemperature, "low_temperature": day.lowTemperature,
             "precipitation_probability_percent": day.precipitationProbability] as [String: Any]
        }
        return ["location": location.displayName(language: .japanese),
                "screen_provider_id": "google-calendar",
                "temperature_unit": forecast.temperatureScale.rawValue,
                "current_temperature": forecast.currentTemperature,
                "current_condition": forecast.currentCondition.title(language: .japanese),
                "timezone": forecast.timezoneIdentifier,
                "fetched_at": ISO8601DateFormatter().string(from: forecast.fetchedAt),
                "cache_age_seconds": max(0, Int(Date().timeIntervalSince(forecast.fetchedAt))),
                "warning": warning ?? "", "days": days, "source": "Open-Meteo",
                "instruction": "Use the returned location, date and temperature unit. If warning is nonempty, explain that this is saved data and a fresh update was unavailable. Do not invent unsupported hourly detail."]
    }
}
