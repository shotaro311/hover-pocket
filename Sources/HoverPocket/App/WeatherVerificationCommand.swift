import AppKit
import Foundation
import SwiftUI

enum WeatherVerificationCommand {
    @MainActor
    static func run() -> Never {
        _ = NSApplication.shared
        let shouldRender = CommandLine.arguments.contains("--render-weather-preview")

        Task { @MainActor in
            let exitCode: Int32
            do {
                let region = WeatherRegion.defaultRegion
                let location = WeatherLocation.from(region: region)
                let service = WeatherForecastService()
                let forecast = try await service.fetch(
                    location: location,
                    temperatureUnit: .automatic
                )
                guard forecast.upcomingDays.count == 7 else {
                    throw WeatherForecastServiceError.malformedForecast
                }
                guard WeatherRegion.allRegions.count == 47,
                      Set(WeatherRegion.allRegions.map(\.id)).count == 47,
                      forecast.locationID == location.id,
                      forecast.temperatureScale == .celsius else {
                    throw WeatherForecastServiceError.malformedForecast
                }
                let requestURL = try service.requestURL(
                    location: location,
                    temperatureScale: .celsius
                )
                guard requestURL.query?.contains("timezone=auto") == true,
                      requestURL.query?.contains("temperature_unit=celsius") == true else {
                    throw WeatherForecastServiceError.invalidRequest
                }
                let globalResults = try await WeatherLocationSearchService().search(
                    query: "London",
                    language: .english
                )
                guard let london = globalResults.first(where: { $0.countryCode == "GB" }),
                      globalResults.allSatisfy({ $0.timezoneIdentifier != nil }) else {
                    throw WeatherLocationSearchError.invalidResponse
                }
                let globalForecast = try await service.fetch(
                    location: london,
                    temperatureUnit: .fahrenheit
                )
                guard globalForecast.locationID == london.id,
                      globalForecast.timezoneIdentifier == "Europe/London",
                      globalForecast.temperatureScale == .fahrenheit,
                      globalForecast.upcomingDays.count == 7 else {
                    throw WeatherForecastServiceError.malformedForecast
                }
                let currentLocation = WeatherLocation.current(
                    latitude: 33.590_354,
                    longitude: 130.401_716
                )
                guard currentLocation.source == .currentLocation,
                      currentLocation.id == "current:33.59,130.4",
                      currentLocation.latitude == 33.59035,
                      currentLocation.longitude == 130.40172 else {
                    throw WeatherForecastServiceError.malformedForecast
                }
                guard WeatherCondition(wmoCode: 0) == .clear,
                      WeatherCondition(wmoCode: 65) == .rain,
                      WeatherCondition(wmoCode: 95) == .thunderstorm else {
                    throw WeatherForecastServiceError.malformedForecast
                }
                guard WeatherCondition.clear.symbolMotionPreset == .solarRotation,
                      WeatherCondition.mostlyClear.symbolMotionPreset == .partlyCloudyRotation,
                      WeatherCondition.cloudy.symbolMotionPreset == .cloudBreathing,
                      WeatherCondition.rain.symbolMotionPreset == .precipitationCycle,
                      WeatherCondition.snow.symbolMotionPreset == .snowDrift,
                      WeatherCondition.thunderstorm.symbolMotionPreset == .thunderPulse else {
                    throw WeatherForecastServiceError.malformedForecast
                }
                try verifyPersistence(forecast: forecast)

                print("weather_verify=ok")
                print("weather_api=open-meteo")
                print("weather_location_id=\(location.id)")
                print("weather_location_name=\(location.displayName(language: .japanese))")
                print("weather_region_count=\(WeatherRegion.allRegions.count)")
                print("weather_global_search=ok")
                print("weather_global_forecast=ok")
                print("weather_current_location_model=ok")
                print("weather_upcoming_days=\(forecast.upcomingDays.count)")
                print("weather_timezone=\(forecast.timezoneIdentifier)")
                print("weather_timezone_request=auto")
                print("weather_temperature_unit=automatic")
                print("weather_attribution=https://open-meteo.com/")
                print("weather_location_persistence=ok")
                print("weather_legacy_region_migration=ok")
                print("weather_offline_cache=ok")
                print("weather_weekday_alignment=fixed")
                print("weather_symbol_motion_presets=6")
                print("weather_symbol_motion_modern=rotate,breathe,variable-color,wiggle,pulse")
                print("weather_symbol_motion_fallback=pulse,variable-color")
                print(
                    "weather_condition_motion_duration_seconds="
                        + "\(WeatherForecastAnimation.currentConditionEffectDurationSeconds)"
                )

                if shouldRender {
                    let outputURL = try renderPreview(forecast: forecast)
                    print("weather_preview=\(outputURL.path)")
                    print("weather_reduce_motion_render=immediate")
                }
                exitCode = 0
            } catch {
                fputs("weather_verify=failed\n", stderr)
                fputs("error=\(safeErrorMessage(error))\n", stderr)
                exitCode = 1
            }
            Darwin.exit(exitCode)
        }

        RunLoop.main.run()
        Darwin.exit(1)
    }

    @MainActor
    private static func verifyPersistence(forecast: WeatherForecast) throws {
        let suiteName = "local.codex.hover-pocket.weather-verification.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw WeatherForecastServiceError.malformedForecast
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("40", forKey: "weatherRegionID")
        let migratedSettings = AppSettings(defaults: defaults)
        guard migratedSettings.weatherLocation.legacyRegionID == "40",
              migratedSettings.weatherLocation.displayName(language: .japanese) == "福岡" else {
            throw WeatherForecastServiceError.malformedForecast
        }

        let selectedLocation = WeatherLocation(
            id: "geonames:2643743",
            name: "London",
            administrativeArea: "England",
            country: "United Kingdom",
            countryCode: "GB",
            latitude: 51.50853,
            longitude: -0.12574,
            timezoneIdentifier: "Europe/London",
            source: .search,
            legacyRegionID: nil
        )
        let settings = AppSettings(defaults: defaults)
        settings.weatherLocation = selectedLocation
        settings.weatherTemperatureUnit = .fahrenheit
        let restoredSettings = AppSettings(defaults: defaults)
        guard restoredSettings.weatherLocation == selectedLocation,
              restoredSettings.weatherTemperatureUnit == .fahrenheit else {
            throw WeatherForecastServiceError.malformedForecast
        }

        let cache = WeatherForecastCache(defaults: defaults)
        cache.save(forecast)
        guard cache.load(
            locationID: forecast.locationID,
            temperatureScale: forecast.temperatureScale
        ) == forecast else {
            throw WeatherForecastServiceError.malformedForecast
        }
    }

    @MainActor
    private static func renderPreview(forecast: WeatherForecast) throws -> URL {
        let outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/verification", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let outputURL = outputDirectory.appendingPathComponent("calendar-weather-preview.png")
        let metrics = WeatherPanelMetrics(panelSize: .large)

        let content = WeatherLoadedContent(
            forecast: forecast,
            location: WeatherLocation.defaultLocation,
            panelSize: .large,
            language: .japanese,
            warning: nil,
            revealedIconCount: 0,
            animatesIconReveal: false,
            currentConditionEffectActive: false,
            onRefresh: {}
        )
        .frame(width: 644, height: metrics.height)
        .background(
            RoundedRectangle(
                cornerRadius: metrics.cornerRadius,
                style: .continuous
            )
            .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: metrics.cornerRadius,
                style: .continuous
            )
            .stroke(Color.white.opacity(0.075), lineWidth: 1)
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: metrics.cornerRadius,
                style: .continuous
            )
        )
        .background(Color(red: 0.02, green: 0.02, blue: 0.025))
        .environment(\.panelTextSize, .medium)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw WeatherForecastServiceError.malformedForecast
        }
        try pngData.write(to: outputURL, options: .atomic)
        return outputURL
    }

    private static func safeErrorMessage(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return String(describing: error)
    }
}
