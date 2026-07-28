import Foundation

enum WeatherLocationSearchError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case unavailable

    var errorDescription: String? {
        message(language: .japanese)
    }

    func message(language: AppLanguage) -> String {
        switch (self, language) {
        case (.invalidRequest, .japanese):
            return "検索内容を確認してください。"
        case (.invalidRequest, .english):
            return "Check the city or postal code."
        case (.invalidResponse, .japanese):
            return "地域検索の結果を読み取れませんでした。"
        case (.invalidResponse, .english):
            return "The location search result could not be read."
        case (.unavailable, .japanese):
            return "地域検索サービスへ接続できませんでした。"
        case (.unavailable, .english):
            return "Could not connect to the location search service."
        }
    }
}

struct WeatherLocationSearchService: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(
        query: String,
        language: AppLanguage,
        count: Int = 8
    ) async throws -> [WeatherLocation] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.count >= 2 else {
            throw WeatherLocationSearchError.invalidRequest
        }

        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: trimmedQuery),
            URLQueryItem(name: "count", value: String(min(max(count, 1), 20))),
            URLQueryItem(name: "language", value: language == .japanese ? "ja" : "en"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components?.url else {
            throw WeatherLocationSearchError.invalidRequest
        }

        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse else {
            throw WeatherLocationSearchError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw WeatherLocationSearchError.unavailable
        }

        let decoded = try JSONDecoder().decode(OpenMeteoGeocodingResponse.self, from: data)
        return decoded.results?.map(\.weatherLocation) ?? []
    }
}

private struct OpenMeteoGeocodingResponse: Decodable {
    let results: [OpenMeteoGeocodingResult]?
}

private struct OpenMeteoGeocodingResult: Decodable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let timezone: String?
    let countryCode: String?
    let country: String?
    let admin1: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case latitude
        case longitude
        case timezone
        case countryCode = "country_code"
        case country
        case admin1
    }

    var weatherLocation: WeatherLocation {
        WeatherLocation(
            id: "geonames:\(id)",
            name: name,
            administrativeArea: admin1,
            country: country,
            countryCode: countryCode,
            latitude: latitude,
            longitude: longitude,
            timezoneIdentifier: timezone,
            source: .search,
            legacyRegionID: nil
        )
    }
}
