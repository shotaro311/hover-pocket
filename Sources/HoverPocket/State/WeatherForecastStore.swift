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

    func loadIfNeeded(region: WeatherRegion) {
        if case .loaded(let forecast, _) = state,
           forecast.regionID == region.id,
           Date().timeIntervalSince(forecast.fetchedAt) < cacheLifetime {
            return
        }
        load(region: region, force: false)
    }

    func refresh(region: WeatherRegion) {
        load(region: region, force: true)
    }

    func regionDidChange(to region: WeatherRegion) {
        load(region: region, force: true)
    }

    private func load(region: WeatherRegion, force: Bool) {
        if !force,
           case .loaded(let forecast, _) = state,
           forecast.regionID == region.id,
           Date().timeIntervalSince(forecast.fetchedAt) < cacheLifetime {
            return
        }

        fetchTask?.cancel()
        let cachedForecast = cache.load(regionID: region.id)
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
                let forecast = try await service.fetch(region: region)
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

    func load(regionID: String) -> WeatherForecast? {
        guard let data = defaults.data(forKey: keyPrefix + regionID) else {
            return nil
        }
        guard let forecast = try? JSONDecoder().decode(WeatherForecast.self, from: data),
              forecast.regionID == regionID else {
            return nil
        }
        return forecast
    }

    func save(_ forecast: WeatherForecast) {
        guard let data = try? JSONEncoder().encode(forecast) else { return }
        defaults.set(data, forKey: keyPrefix + forecast.regionID)
    }
}
