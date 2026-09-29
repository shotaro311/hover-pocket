import Foundation

@MainActor
enum WeatherVoiceVerification {
    static func run() async throws {
        let suite = "WeatherVoiceVerification-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WeatherVoiceVerificationProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = WeatherForecastService(session: session)
        let location = WeatherLocation.from(region: .defaultRegion)
        let dates = (1...8).map { "2026-09-" + String(format: "%02d", $0) }
        let fixture = try JSONSerialization.data(withJSONObject: [
            "timezone": "Asia/Tokyo", "current": ["temperature_2m": 25.5, "weather_code": 1],
            "daily": ["time": dates, "weather_code": Array(repeating: 1, count: 8),
                "temperature_2m_max": Array(repeating: 30, count: 8), "temperature_2m_min": Array(repeating: 20, count: 8),
                "precipitation_probability_max": Array(repeating: 30, count: 8)]
        ])
        WeatherVoiceVerificationProtocol.state.configure(data: fixture, status: 200)
        let store = WeatherForecastStore(service: service, defaults: defaults)
        let host = PocketAppOSController()
        var unit = WeatherTemperatureUnitOption.celsius
        host.readWeather = { try await WeatherVoiceReader.read(store: store, location: location, temperatureUnit: unit) }
        var serial = 0, checks = 0
        func read() async throws -> [String: Any] {
            serial += 1
            let output = await host.execute(session: "weather", callID: "weather-\(serial)", arguments: .object(["operation": .string("weather")]))
            return try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
        }
        func check(_ result: Bool, _ name: String) throws {
            guard result else { throw PocketPreviewValidationError(code: "weather_voice_" + name) }
            checks += 1
        }
        let first = try await read()
        try check(first["status"] as? String == "succeeded" && first["source"] as? String == "Open-Meteo", "host_reads_existing_service")
        try check(first["current_temperature"] as? Double == 25.5 && first["temperature_unit"] as? String == "celsius", "temperature_and_unit")
        try check((first["days"] as? [[String: Any]])?.count == 8 && first["timezone"] as? String == "Asia/Tokyo" && first["fetched_at"] != nil, "dates_and_freshness")
        try check(first["latitude"] == nil && first["longitude"] == nil && first["locationID"] == nil, "coordinates_not_exposed")
        _ = try await read()
        try check(WeatherVoiceVerificationProtocol.state.requestCount == 1, "fresh_cache_shared_with_ui")
        unit = .fahrenheit
        let changed = try await read()
        try check(changed["temperature_unit"] as? String == "fahrenheit" && WeatherVoiceVerificationProtocol.state.requestCount == 2, "unit_change_fetches_again")
        let stale = try service.decode(data: fixture, locationID: location.id, temperatureScale: .celsius, fetchedAt: Date().addingTimeInterval(-3600))
        WeatherForecastCache(defaults: defaults).save(stale)
        WeatherVoiceVerificationProtocol.state.configure(data: Data(), status: 503)
        let staleStore = WeatherForecastStore(service: service, defaults: defaults)
        host.readWeather = { try await WeatherVoiceReader.read(store: staleStore, location: location, temperatureUnit: .celsius) }
        let cached = try await read()
        try check(cached["status"] as? String == "succeeded" && !(cached["warning"] as? String ?? "").isEmpty && (cached["cache_age_seconds"] as? Int ?? 0) >= 3600, "stale_cache_warning")
        let unavailableLocation = WeatherLocation.current(latitude: 0, longitude: 0)
        let failedStore = WeatherForecastStore(service: service, defaults: defaults)
        host.readWeather = { try await WeatherVoiceReader.read(store: failedStore, location: unavailableLocation, temperatureUnit: .celsius) }
        let failed = try await read()
        try check(failed["status"] as? String == "failed" && failed["code"] as? String == "weather_fetch_failed", "unavailable_without_cache_is_failure")
        print("PASS voice weather: \(checks) checks; shared forecast service/cache, units, dates, fresh/stale/unavailable states, no coordinates in tool output")
    }
}

private final class WeatherVoiceVerificationState: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var status = 200
    private var count = 0
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    func configure(data: Data, status: Int) {
        lock.lock(); defer { lock.unlock() }
        self.data = data; self.status = status; count = 0
    }
    func response() -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return (data, status)
    }
}

private final class WeatherVoiceVerificationProtocol: URLProtocol, @unchecked Sendable {
    static let state = WeatherVoiceVerificationState()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.open-meteo.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (data, status) = Self.state.response()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
