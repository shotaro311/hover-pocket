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
                let forecast = try await WeatherForecastService().fetch(region: region)
                guard forecast.upcomingDays.count == 7 else {
                    throw WeatherForecastServiceError.malformedForecast
                }
                guard WeatherRegion.allRegions.count == 47,
                      Set(WeatherRegion.allRegions.map(\.id)).count == 47,
                      forecast.regionID == region.id else {
                    throw WeatherForecastServiceError.malformedForecast
                }
                guard WeatherCondition(wmoCode: 0) == .clear,
                      WeatherCondition(wmoCode: 65) == .rain,
                      WeatherCondition(wmoCode: 95) == .thunderstorm else {
                    throw WeatherForecastServiceError.malformedForecast
                }
                try verifyPersistence(forecast: forecast)

                print("weather_verify=ok")
                print("weather_api=open-meteo")
                print("weather_region_id=\(region.id)")
                print("weather_region_name=\(region.japaneseName)")
                print("weather_region_count=\(WeatherRegion.allRegions.count)")
                print("weather_upcoming_days=\(forecast.upcomingDays.count)")
                print("weather_timezone=\(forecast.timezoneIdentifier)")
                print("weather_attribution=https://open-meteo.com/")
                print("weather_region_persistence=ok")
                print("weather_offline_cache=ok")

                if shouldRender {
                    let outputURL = try renderPreview(forecast: forecast)
                    print("weather_preview=\(outputURL.path)")
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

        let selectedRegion = WeatherRegion.region(id: "40")!
        let settings = AppSettings(defaults: defaults)
        settings.weatherRegion = selectedRegion
        let restoredSettings = AppSettings(defaults: defaults)
        guard restoredSettings.weatherRegion.id == selectedRegion.id else {
            throw WeatherForecastServiceError.malformedForecast
        }

        let cache = WeatherForecastCache(defaults: defaults)
        cache.save(forecast)
        guard cache.load(regionID: forecast.regionID) == forecast else {
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
            region: WeatherRegion.region(id: forecast.regionID) ?? .defaultRegion,
            panelSize: .large,
            language: .japanese,
            warning: nil,
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
