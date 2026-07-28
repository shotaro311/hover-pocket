import SwiftUI

struct WeatherForecastView: View {
    let panelSize: PanelSizeOption
    let language: AppLanguage
    let isActive: Bool
    let region: WeatherRegion

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var store = WeatherForecastStore.shared
    @State private var revealedIconCount = 0
    @State private var hasPlayedIconReveal = false
    @State private var revealGeneration = 0
    @State private var currentConditionEffectActive = false

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
                    revealedIconCount: revealedIconCount,
                    animatesIconReveal: !reduceMotion,
                    currentConditionEffectActive: currentConditionEffectActive,
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
                playIconRevealIfReady()
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                store.loadIfNeeded(region: region)
                playIconRevealIfReady()
            } else {
                resetIconReveal()
            }
        }
        .onChange(of: store.state) { _, _ in
            playIconRevealIfReady()
        }
        .onChange(of: region) { _, selectedRegion in
            if isActive {
                store.regionDidChange(to: selectedRegion)
            }
        }
        .onChange(of: reduceMotion) { _, enabled in
            guard enabled else { return }
            revealGeneration += 1
            revealedIconCount = Self.totalIconCount
            currentConditionEffectActive = false
        }
        .onDisappear {
            resetIconReveal()
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

    private func playIconRevealIfReady() {
        guard isActive,
              case .loaded = store.state,
              !hasPlayedIconReveal else {
            return
        }

        hasPlayedIconReveal = true
        revealGeneration += 1
        let generation = revealGeneration

        if reduceMotion {
            revealedIconCount = Self.totalIconCount
            return
        }

        revealedIconCount = 0
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(70))
            guard generation == revealGeneration, isActive else { return }

            withAnimation(.easeOut(duration: 0.3)) {
                revealedIconCount = 1
            }
            currentConditionEffectActive = true

            Task { @MainActor in
                try? await Task.sleep(for: WeatherForecastAnimation.currentConditionEffectDuration)
                guard generation == revealGeneration, isActive else { return }
                currentConditionEffectActive = false
            }

            for count in 2...Self.totalIconCount {
                try? await Task.sleep(for: .milliseconds(70))
                guard generation == revealGeneration, isActive else { return }

                withAnimation(.easeOut(duration: 0.26)) {
                    revealedIconCount = count
                }
            }
        }
    }

    private func resetIconReveal() {
        revealGeneration += 1
        hasPlayedIconReveal = false
        revealedIconCount = 0
        currentConditionEffectActive = false
    }

    private static let totalIconCount = 8
}

struct WeatherLoadedContent: View {
    let forecast: WeatherForecast
    let region: WeatherRegion
    let panelSize: PanelSizeOption
    let language: AppLanguage
    let warning: String?
    let revealedIconCount: Int
    let animatesIconReveal: Bool
    let currentConditionEffectActive: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: metrics.sectionSpacing) {
            currentWeather
                .frame(width: metrics.currentSectionWidth, alignment: .leading)

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(width: 1)

            upcomingForecast
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.vertical, metrics.verticalPadding)
    }

    private var currentWeather: some View {
        VStack(alignment: .leading, spacing: metrics.currentBlockSpacing) {
            HStack(spacing: metrics.currentSpacing) {
                WeatherCurrentAnimatedSymbol(
                    name: forecast.currentCondition.symbolName,
                    motionPreset: forecast.currentCondition.symbolMotionPreset,
                    size: metrics.currentIconSize,
                    width: metrics.currentIconWidth,
                    isRevealed: revealedIconCount >= 1,
                    animatesReveal: animatesIconReveal,
                    conditionEffectActive: currentConditionEffectActive
                )

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
            }

            HStack(spacing: metrics.currentDetailSpacing) {
                Text("H \(temperature(forecast.today.highTemperature))")
                    .foregroundStyle(.white.opacity(0.78))
                Text("L \(temperature(forecast.today.lowTemperature))")
                    .foregroundStyle(.white.opacity(0.46))

                Label(
                    "\(forecast.today.precipitationProbability)%",
                    systemImage: "drop.fill"
                )
                .foregroundStyle(.cyan.opacity(0.72))

                Spacer(minLength: 0)

                Link(destination: WeatherForecastService.attributionURL) {
                    Text("Open-Meteo")
                        .panelTextFont(size: metrics.attributionSize, weight: .medium)
                        .foregroundStyle(.white.opacity(0.32))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)

                Button(action: onRefresh) {
                    Image(systemName: warning == nil ? "arrow.clockwise" : "exclamationmark.triangle.fill")
                        .font(.system(size: metrics.refreshIconSize, weight: .semibold))
                        .foregroundStyle(warning == nil ? Color.white.opacity(0.34) : Color.yellow.opacity(0.82))
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
            .panelTextFont(size: metrics.currentDetailSize, weight: .semibold, design: .monospaced)
            .lineLimit(1)
        }
    }

    private var upcomingForecast: some View {
        VStack(alignment: .leading, spacing: metrics.forecastHeadingSpacing) {
            Text(text(japanese: "週間予報", english: "7-day forecast"))
                .panelTextFont(size: metrics.forecastHeadingSize, weight: .bold)
                .foregroundStyle(.white.opacity(0.52))
                .lineLimit(1)

            HStack(alignment: .top, spacing: metrics.daySpacing) {
                ForEach(forecast.upcomingDays.indices, id: \.self) { index in
                    let day = forecast.upcomingDays[index]
                    VStack(spacing: metrics.dayItemSpacing) {
                        Text(weekday(for: day.date))
                            .panelTextFont(size: metrics.weekdaySize, weight: .bold, design: .monospaced)
                            .foregroundStyle(.white.opacity(0.52))

                        WeatherAnimatedSymbol(
                            name: day.condition.symbolName,
                            size: metrics.dayIconSize,
                            isRevealed: revealedIconCount >= index + 2,
                            animatesReveal: animatesIconReveal
                        )

                        HStack(spacing: 1) {
                            Text(temperature(day.highTemperature))
                                .foregroundStyle(.white.opacity(0.82))
                            Text(temperature(day.lowTemperature))
                                .foregroundStyle(.white.opacity(0.44))
                        }
                        .panelTextFont(size: metrics.dayTemperatureSize, weight: .semibold, design: .monospaced)
                        .lineLimit(1)

                        Label("\(day.precipitationProbability)%", systemImage: "drop.fill")
                            .labelStyle(.titleAndIcon)
                            .panelTextFont(size: metrics.precipitationSize, weight: .semibold, design: .monospaced)
                            .foregroundStyle(.cyan.opacity(0.68))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
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

enum WeatherForecastAnimation {
    static let currentConditionEffectDurationSeconds = 5.0
    static let currentConditionEffectDuration: Duration = .seconds(
        currentConditionEffectDurationSeconds
    )
}

private struct WeatherCurrentAnimatedSymbol: View {
    let name: String
    let motionPreset: WeatherSymbolMotionPreset
    let size: CGFloat
    let width: CGFloat
    let isRevealed: Bool
    let animatesReveal: Bool
    let conditionEffectActive: Bool

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: width, height: size)

            if !animatesReveal || isRevealed {
                WeatherConditionEffectSymbol(
                    name: name,
                    motionPreset: motionPreset,
                    size: size,
                    width: width,
                    isActive: conditionEffectActive
                )
                .transition(.symbolEffect(.appear, options: .nonRepeating))
            }
        }
        .frame(width: width, height: size)
    }
}

private struct WeatherConditionEffectSymbol: View {
    let name: String
    let motionPreset: WeatherSymbolMotionPreset
    let size: CGFloat
    let width: CGFloat
    let isActive: Bool

    @ViewBuilder
    var body: some View {
        switch motionPreset {
        case .sunlightPulse:
            symbol
                .symbolEffect(
                    .pulse.byLayer,
                    options: .repeating.speed(0.7),
                    isActive: isActive
                )
        case .cloudPulse:
            symbol
                .symbolEffect(
                    .pulse.wholeSymbol,
                    options: .repeating.speed(0.55),
                    isActive: isActive
                )
        case .precipitationCycle:
            symbol
                .symbolEffect(
                    .variableColor.iterative.reversing,
                    options: .repeating.speed(0.8),
                    isActive: isActive
                )
        }
    }

    private var symbol: some View {
        Image(systemName: name)
            .symbolRenderingMode(.multicolor)
            .font(.system(size: size, weight: .semibold))
            .frame(width: width, height: size)
    }
}

private struct WeatherAnimatedSymbol: View {
    let name: String
    let size: CGFloat
    var width: CGFloat?
    let isRevealed: Bool
    let animatesReveal: Bool

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: width, height: size)

            if !animatesReveal || isRevealed {
                symbol
                    .transition(.symbolEffect(.appear, options: .nonRepeating))
            }
        }
        .frame(height: size)
    }

    private var symbol: some View {
        Image(systemName: name)
            .symbolRenderingMode(.multicolor)
            .font(.system(size: size, weight: .semibold))
            .frame(width: width, height: size)
    }
}

struct WeatherPanelMetrics {
    let height: CGFloat
    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let sectionSpacing: CGFloat
    let currentSectionWidth: CGFloat
    let currentBlockSpacing: CGFloat
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
    let forecastHeadingSpacing: CGFloat
    let forecastHeadingSize: CGFloat
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
            height = 58
            cornerRadius = 8
            horizontalPadding = 8
            verticalPadding = 4
            sectionSpacing = 7
            currentSectionWidth = 145
            currentBlockSpacing = 2
            currentSpacing = 4
            currentDetailSpacing = 2
            currentIconSize = 20
            currentIconWidth = 22
            currentTemperatureSize = 18
            regionFontSize = 7
            conditionFontSize = 6
            currentDetailSize = 6.5
            attributionSize = 5.5
            refreshIconSize = 7.5
            forecastHeadingSpacing = 2
            forecastHeadingSize = 6.5
            daySpacing = 1
            dayItemSpacing = 1
            weekdaySize = 6.5
            dayIconSize = 11
            dayTemperatureSize = 6
            precipitationSize = 5.7
            statusSpacing = 5
            statusIconSize = 13
            statusTitleSize = 8
            buttonFontSize = 7
        case .medium:
            height = 67
            cornerRadius = 8
            horizontalPadding = 10
            verticalPadding = 5
            sectionSpacing = 9
            currentSectionWidth = 165
            currentBlockSpacing = 3
            currentSpacing = 6
            currentDetailSpacing = 3
            currentIconSize = 26
            currentIconWidth = 28
            currentTemperatureSize = 22
            regionFontSize = 8.5
            conditionFontSize = 7
            currentDetailSize = 7.5
            attributionSize = 6
            refreshIconSize = 8.5
            forecastHeadingSpacing = 3
            forecastHeadingSize = 7.5
            daySpacing = 2
            dayItemSpacing = 1.5
            weekdaySize = 7.5
            dayIconSize = 15
            dayTemperatureSize = 7
            precipitationSize = 6.5
            statusSpacing = 6
            statusIconSize = 15
            statusTitleSize = 9
            buttonFontSize = 8
        case .large:
            height = 122
            cornerRadius = 10
            horizontalPadding = 12
            verticalPadding = 8
            sectionSpacing = 14
            currentSectionWidth = 205
            currentBlockSpacing = 7
            currentSpacing = 7
            currentDetailSpacing = 5
            currentIconSize = 38
            currentIconWidth = 42
            currentTemperatureSize = 32
            regionFontSize = 11
            conditionFontSize = 9.5
            currentDetailSize = 9
            attributionSize = 7
            refreshIconSize = 10
            forecastHeadingSpacing = 6
            forecastHeadingSize = 9
            daySpacing = 4
            dayItemSpacing = 4
            weekdaySize = 9
            dayIconSize = 22
            dayTemperatureSize = 8.5
            precipitationSize = 8
            statusSpacing = 8
            statusIconSize = 22
            statusTitleSize = 11
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
