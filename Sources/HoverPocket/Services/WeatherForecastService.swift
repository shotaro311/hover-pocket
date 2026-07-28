import Foundation

enum WeatherForecastServiceError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case unavailable(statusCode: Int)
    case malformedForecast

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "天気の取得先を作成できませんでした。"
        case .invalidResponse:
            return "天気サービスから正しい応答を受け取れませんでした。"
        case .unavailable:
            return "天気サービスへ接続できませんでした。"
        case .malformedForecast:
            return "天気データを読み取れませんでした。"
        }
    }
}

struct WeatherForecastService: Sendable {
    static let attributionURL = URL(string: "https://open-meteo.com/")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(region: WeatherRegion) async throws -> WeatherForecast {
        let url = try requestURL(region: region)
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse else {
            throw WeatherForecastServiceError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw WeatherForecastServiceError.unavailable(statusCode: response.statusCode)
        }
        return try decode(data: data, regionID: region.id)
    }

    func requestURL(region: WeatherRegion) throws -> URL {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: Self.coordinateString(region.latitude)),
            URLQueryItem(name: "longitude", value: Self.coordinateString(region.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(
                name: "daily",
                value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"
            ),
            URLQueryItem(name: "timezone", value: "Asia/Tokyo"),
            URLQueryItem(name: "forecast_days", value: "8")
        ]
        guard let url = components?.url else {
            throw WeatherForecastServiceError.invalidRequest
        }
        return url
    }

    func decode(data: Data, regionID: String, fetchedAt: Date = Date()) throws -> WeatherForecast {
        let response = try JSONDecoder().decode(OpenMeteoForecastResponse.self, from: data)
        let count = [
            response.daily.time.count,
            response.daily.weatherCode.count,
            response.daily.temperatureMax.count,
            response.daily.temperatureMin.count,
            response.daily.precipitationProbabilityMax.count
        ].min() ?? 0
        guard count >= 8 else {
            throw WeatherForecastServiceError.malformedForecast
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: response.timezone) ?? .current
        formatter.dateFormat = "yyyy-MM-dd"

        let days = try (0..<count).map { index -> WeatherForecastDay in
            guard let date = formatter.date(from: response.daily.time[index]) else {
                throw WeatherForecastServiceError.malformedForecast
            }
            return WeatherForecastDay(
                date: date,
                condition: WeatherCondition(wmoCode: response.daily.weatherCode[index]),
                highTemperature: response.daily.temperatureMax[index],
                lowTemperature: response.daily.temperatureMin[index],
                precipitationProbability: min(
                    100,
                    max(0, response.daily.precipitationProbabilityMax[index])
                )
            )
        }

        return WeatherForecast(
            regionID: regionID,
            currentTemperature: response.current.temperature,
            currentCondition: WeatherCondition(wmoCode: response.current.weatherCode),
            today: days[0],
            upcomingDays: Array(days.dropFirst().prefix(7)),
            fetchedAt: fetchedAt,
            timezoneIdentifier: response.timezone
        )
    }

    private static func coordinateString(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private struct OpenMeteoForecastResponse: Decodable {
    struct Current: Decodable {
        let temperature: Double
        let weatherCode: Int

        enum CodingKeys: String, CodingKey {
            case temperature = "temperature_2m"
            case weatherCode = "weather_code"
        }
    }

    struct Daily: Decodable {
        let time: [String]
        let weatherCode: [Int]
        let temperatureMax: [Double]
        let temperatureMin: [Double]
        let precipitationProbabilityMax: [Int]

        enum CodingKeys: String, CodingKey {
            case time
            case weatherCode = "weather_code"
            case temperatureMax = "temperature_2m_max"
            case temperatureMin = "temperature_2m_min"
            case precipitationProbabilityMax = "precipitation_probability_max"
        }
    }

    let timezone: String
    let current: Current
    let daily: Daily
}
