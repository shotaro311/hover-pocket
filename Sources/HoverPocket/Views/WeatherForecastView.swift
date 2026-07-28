import SwiftUI

struct WeatherForecastView: View {
    let panelSize: PanelSizeOption
    let language: AppLanguage
    let isActive: Bool
    let region: WeatherRegion

    @ObservedObject private var store = WeatherForecastStore.shared

    var body: some View {
        Group {
            switch store.state {
            case .loading:
                statusView
            case .loaded(let forecast, let warning):
                WeatherLoadedContent(
                    forecast: forecast,
                    region: region,
                    panelSize: panelSize,
                    language: language,
                    warning: warning,
                    onRefresh: { store.refresh(region: region) }
                )
            case .failed:
                failedView
            }
        }
        .frame(height: metrics.height)
        .background(cardBackground)
        .overlay(cardBorder)
        .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
        .onAppear {
            if isActive {
                store.loadIfNeeded(region: region)
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                store.loadIfNeeded(region: region)
            }
        }
        .onChange(of: region) { _, selectedRegion in
            if isActive {
                store.regionDidChange(to: selectedRegion)
            }
        }
    }

    private var statusView: some View {
        HStack(spacing: metrics.statusSpacing) {
            ProgressView()
                .controlSize(.small)
            Text(text(
                japanese: "\(region.japaneseName)の天気を取得中…",
                english: "Loading weather for \(region.englishName)…"
            ))
            .panelTextFont(size: metrics.statusTitleSize, weight: .bold)
            .foregroundStyle(.white.opacity(0.68))
            .lineLimit(1)
        }
    }

    private var failedView: some View {
        HStack(spacing: metrics.statusSpacing) {
            Image(systemName: "wifi.slash")
                .font(.system(size: metrics.statusIconSize, weight: .semibold))
                .foregroundStyle(.yellow.opacity(0.82))

            Text(text(japanese: "天気を取得できません", english: "Weather unavailable"))
                .panelTextFont(size: metrics.statusTitleSize, weight: .bold)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)

            Spacer(minLength: 2)

            Button(text(japanese: "再試行", english: "Retry")) {
                store.refresh(region: region)
            }
            .panelTextFont(size: metrics.buttonFontSize, weight: .bold)
            .buttonStyle(WeatherActionButtonStyle())
        }
        .padding(.horizontal, metrics.horizontalPadding)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.035))
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
            .stroke(Color.white.opacity(0.075), lineWidth: 1)
    }

    private var metrics: WeatherPanelMetrics {
        WeatherPanelMetrics(panelSize: panelSize)
    }

    private func text(japanese: String, english: String) -> String {
        language == .japanese ? japanese : english
    }
}

struct WeatherLoadedContent: View {
    let forecast: WeatherForecast
    let region: WeatherRegion
    let panelSize: PanelSizeOption
    let language: AppLanguage
    let warning: String?
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: metrics.sectionSpacing) {
            currentWeather

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)

            upcomingForecast
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.vertical, metrics.verticalPadding)
    }

    private var currentWeather: some View {
        HStack(spacing: metrics.currentSpacing) {
            Image(systemName: forecast.currentCondition.symbolName)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: metrics.currentIconSize, weight: .semibold))
                .frame(width: metrics.currentIconWidth)

            Text(temperature(forecast.currentTemperature))
                .panelTextFont(size: metrics.currentTemperatureSize, weight: .bold, design: .rounded)
                .foregroundStyle(.white)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: panelSize == .large ? 2 : 0) {
                Text(region.name(language: language))
                    .panelTextFont(size: metrics.regionFontSize, weight: .bold)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Text(forecast.currentCondition.title(language: language))
                    .panelTextFont(size: metrics.conditionFontSize, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 2)

            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: metrics.currentDetailSpacing) {
                    Text("H \(temperature(forecast.today.highTemperature))")
                        .foregroundStyle(.white.opacity(0.78))
                    Text("L \(temperature(forecast.today.lowTemperature))")
                        .foregroundStyle(.white.opacity(0.46))
                }

                HStack(spacing: metrics.currentDetailSpacing) {
                    Label(
                        "\(forecast.today.precipitationProbability)%",
                        systemImage: "drop.fill"
                    )
                    .foregroundStyle(.cyan.opacity(0.72))

                    Link(destination: WeatherForecastService.attributionURL) {
                        Text("Open-Meteo")
                            .panelTextFont(size: metrics.attributionSize, weight: .medium)
                            .foregroundStyle(.white.opacity(0.28))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .panelTextFont(size: metrics.currentDetailSize, weight: .semibold, design: .monospaced)
            .lineLimit(1)

            Button(action: onRefresh) {
                Image(systemName: warning == nil ? "arrow.clockwise" : "exclamationmark.triangle.fill")
                    .font(.system(size: metrics.refreshIconSize, weight: .semibold))
                    .foregroundStyle(warning == nil ? Color.white.opacity(0.3) : Color.yellow.opacity(0.82))
            }
            .buttonStyle(.plain)
            .help(
                warning == nil
                    ? text(japanese: "天気を更新", english: "Refresh weather")
                    : text(
                        japanese: "保存済みの予報を表示しています。更新に失敗しました。",
                        english: "Showing a saved forecast because the update failed."
                    )
            )
        }
    }

    private var upcomingForecast: some View {
        HStack(spacing: metrics.daySpacing) {
            ForEach(forecast.upcomingDays) { day in
                VStack(spacing: metrics.dayItemSpacing) {
                    Text(weekday(for: day.date))
                        .panelTextFont(size: metrics.weekdaySize, weight: .bold, design: .monospaced)
                        .foregroundStyle(.white.opacity(0.48))

                    Image(systemName: day.condition.symbolName)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: metrics.dayIconSize, weight: .semibold))

                    HStack(spacing: 1) {
                        Text(temperature(day.highTemperature))
                            .foregroundStyle(.white.opacity(0.78))
                        Text(temperature(day.lowTemperature))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .panelTextFont(size: metrics.dayTemperatureSize, weight: .semibold, design: .monospaced)
                    .lineLimit(1)

                    Label("\(day.precipitationProbability)%", systemImage: "drop.fill")
                        .labelStyle(.titleAndIcon)
                        .panelTextFont(size: metrics.precipitationSize, weight: .semibold, design: .monospaced)
                        .foregroundStyle(.cyan.opacity(0.62))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func temperature(_ value: Double) -> String {
        "\(Int(value.rounded()))°"
    }

    private func weekday(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        let result = formatter.string(from: date)
        return language == .japanese ? String(result.prefix(1)) : String(result.prefix(3))
    }

    private func text(japanese: String, english: String) -> String {
        language == .japanese ? japanese : english
    }

    private var metrics: WeatherPanelMetrics {
        WeatherPanelMetrics(panelSize: panelSize)
    }
}

struct WeatherPanelMetrics {
    let height: CGFloat
    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let sectionSpacing: CGFloat
    let currentSpacing: CGFloat
    let currentDetailSpacing: CGFloat
    let currentIconSize: CGFloat
    let currentIconWidth: CGFloat
    let currentTemperatureSize: CGFloat
    let regionFontSize: CGFloat
    let conditionFontSize: CGFloat
    let currentDetailSize: CGFloat
    let attributionSize: CGFloat
    let refreshIconSize: CGFloat
    let daySpacing: CGFloat
    let dayItemSpacing: CGFloat
    let weekdaySize: CGFloat
    let dayIconSize: CGFloat
    let dayTemperatureSize: CGFloat
    let precipitationSize: CGFloat
    let statusSpacing: CGFloat
    let statusIconSize: CGFloat
    let statusTitleSize: CGFloat
    let buttonFontSize: CGFloat

    init(panelSize: PanelSizeOption) {
        switch panelSize {
        case .small:
            height = 50
            cornerRadius = 7
            horizontalPadding = 6
            verticalPadding = 3
            sectionSpacing = 2
            currentSpacing = 3
            currentDetailSpacing = 3
            currentIconSize = 12
            currentIconWidth = 14
            currentTemperatureSize = 12
            regionFontSize = 6.5
            conditionFontSize = 5.5
            currentDetailSize = 6.5
            attributionSize = 5.5
            refreshIconSize = 7
            daySpacing = 1
            dayItemSpacing = 0
            weekdaySize = 6
            dayIconSize = 7
            dayTemperatureSize = 5.5
            precipitationSize = 5.5
            statusSpacing = 5
            statusIconSize = 13
            statusTitleSize = 8
            buttonFontSize = 7
        case .medium:
            height = 64
            cornerRadius = 8
            horizontalPadding = 7
            verticalPadding = 4
            sectionSpacing = 3
            currentSpacing = 4
            currentDetailSpacing = 4
            currentIconSize = 15
            currentIconWidth = 17
            currentTemperatureSize = 15
            regionFontSize = 7.5
            conditionFontSize = 6.5
            currentDetailSize = 7
            attributionSize = 6
            refreshIconSize = 8
            daySpacing = 2
            dayItemSpacing = 0.5
            weekdaySize = 6.5
            dayIconSize = 8.5
            dayTemperatureSize = 6
            precipitationSize = 6
            statusSpacing = 6
            statusIconSize = 15
            statusTitleSize = 9
            buttonFontSize = 8
        case .large:
            height = 116
            cornerRadius = 9
            horizontalPadding = 9
            verticalPadding = 7
            sectionSpacing = 5
            currentSpacing = 6
            currentDetailSpacing = 6
            currentIconSize = 26
            currentIconWidth = 29
            currentTemperatureSize = 24
            regionFontSize = 9
            conditionFontSize = 8
            currentDetailSize = 8
            attributionSize = 6.5
            refreshIconSize = 9
            daySpacing = 3
            dayItemSpacing = 2
            weekdaySize = 7
            dayIconSize = 12
            dayTemperatureSize = 6.5
            precipitationSize = 6.5
            statusSpacing = 8
            statusIconSize = 22
            statusTitleSize = 10
            buttonFontSize = 9
        }
    }
}

private struct WeatherActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.66 : 0.88))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.075))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
    }
}
