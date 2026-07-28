import Combine
import Foundation

enum WeatherForecastViewState: Equatable {
    case loading
    case loaded(WeatherForecast, warning: String?)
    case failed(message: String)
}

@MainActor
final class WeatherForecastStore: ObservableObject {
    static let shared = WeatherForecastStore()

    @Published private(set) var state: WeatherForecastViewState = .loading

    private let service: WeatherForecastService
    private let cache: WeatherForecastCache
    private var fetchTask: Task<Void, Never>?
    private let cacheLifetime: TimeInterval = 30 * 60

    init(
        service: WeatherForecastService = WeatherForecastService(),
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        cache = WeatherForecastCache(defaults: defaults)
    }

    func loadIfNeeded(
        location: WeatherLocation,
        temperatureUnit: WeatherTemperatureUnitOption
    ) {
        let scale = temperatureUnit.resolvedScale(for: location)
        if case .loaded(let forecast, _) = state,
           forecast.locationID == location.id,
           forecast.temperatureScale == scale,
           Date().timeIntervalSince(forecast.fetchedAt) < cacheLifetime {
            return
        }
        load(location: location, temperatureUnit: temperatureUnit, force: false)
    }

    func refresh(
        location: WeatherLocation,
        temperatureUnit: WeatherTemperatureUnitOption
    ) {
        load(location: location, temperatureUnit: temperatureUnit, force: true)
    }

    func locationDidChange(
        to location: WeatherLocation,
        temperatureUnit: WeatherTemperatureUnitOption
    ) {
        load(location: location, temperatureUnit: temperatureUnit, force: true)
    }

    private func load(
        location: WeatherLocation,
        temperatureUnit: WeatherTemperatureUnitOption,
        force: Bool
    ) {
        let temperatureScale = temperatureUnit.resolvedScale(for: location)
        if !force,
           case .loaded(let forecast, _) = state,
           forecast.locationID == location.id,
           forecast.temperatureScale == temperatureScale,
           Date().timeIntervalSince(forecast.fetchedAt) < cacheLifetime {
            return
        }

        fetchTask?.cancel()
        let cachedForecast = cache.load(
            locationID: location.id,
            temperatureScale: temperatureScale
        )
        if let cachedForecast {
            let isFresh = Date().timeIntervalSince(cachedForecast.fetchedAt) < cacheLifetime
            state = .loaded(
                cachedForecast,
                warning: isFresh ? nil : "保存済みの予報を表示しながら更新しています。"
            )
            if !force, isFresh {
                return
            }
        } else {
            state = .loading
        }

        fetchTask = Task { [weak self, service, cache] in
            do {
                let forecast = try await service.fetch(
                    location: location,
                    temperatureUnit: temperatureUnit
                )
                guard !Task.isCancelled else { return }
                cache.save(forecast)
                self?.state = .loaded(forecast, warning: nil)
            } catch {
                guard !Task.isCancelled else { return }
                let message = Self.safeErrorMessage(error)
                if let cachedForecast {
                    self?.state = .loaded(cachedForecast, warning: message)
                } else {
                    self?.state = .failed(message: message)
                }
            }
        }
    }

    private static func safeErrorMessage(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return "天気を取得できませんでした。"
    }
}

struct WeatherForecastCache {
    private let defaults: UserDefaults
    private let keyPrefix = "weatherForecastCache."

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load(
        locationID: String,
        temperatureScale: WeatherTemperatureScale
    ) -> WeatherForecast? {
        let scaleKey = keyPrefix + locationID + "." + temperatureScale.rawValue
        let legacyKey = keyPrefix + locationID
        guard let data = defaults.data(forKey: scaleKey)
            ?? (temperatureScale == .celsius ? defaults.data(forKey: legacyKey) : nil) else {
            return nil
        }
        guard let forecast = try? JSONDecoder().decode(WeatherForecast.self, from: data),
              forecast.locationID == locationID,
              forecast.temperatureScale == temperatureScale else {
            return nil
        }
        return forecast
    }

    func save(_ forecast: WeatherForecast) {
        guard let data = try? JSONEncoder().encode(forecast) else { return }
        let key = keyPrefix + forecast.locationID + "." + forecast.temperatureScale.rawValue
        defaults.set(data, forKey: key)
    }
}
