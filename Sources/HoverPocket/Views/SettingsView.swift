import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var providerStore: ProviderStore
    @ObservedObject private var calendarStore = GoogleCalendarStore.shared
    @ObservedObject private var appUpdater = AppUpdater.shared
    @StateObject private var weatherLocationModel = WeatherLocationSettingsModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                languageSection

                Divider()

                displaySection

                Divider()

                entryPointSection

                Divider()

                panelsSection

                Divider()

                voiceLaneSection

                Divider()

                providersSection

                Divider()

                stickyNotesSection

                Divider()

                mirrorSection

                Divider()

                weatherSection

                Divider()

                googleCalendarSection

                Divider()

                updatesSection
            }
            .padding(20)
        }
        .frame(width: 460, height: 500)
    }

    private var language: AppLanguage {
        settings.appLanguage
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(settings.text(.language))
                .font(.system(size: 13, weight: .bold))

            Picker(settings.text(.language), selection: $settings.appLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(settings.text(.displaySectionTitle))
                .font(.system(size: 13, weight: .bold))

            Picker(settings.text(.displayPickerTitle), selection: $settings.displayPlacementMode) {
                ForEach(DisplayPlacementMode.allCases) { mode in
                    Text(mode.title(language: language)).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(settings.displayPlacementMode.detail(language: language))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Toggle(settings.text(.showMirrorOnSecondaryDisplays), isOn: $settings.showMirrorOnSecondaryDisplays)

                Text(settings.text(.showMirrorOnSecondaryDisplaysDetail))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var entryPointSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.text(.entryPointSectionTitle))
                .font(.system(size: 13, weight: .bold))

            VStack(alignment: .leading, spacing: 6) {
                Toggle(settings.text(.showSideHandle), isOn: $settings.showNotchSideHandleArea)

                Text(handleIconDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker(settings.text(.handleIcon), selection: $settings.pillHandleIconStyle) {
                    ForEach(PillHandleIconStyle.allCases) { style in
                        Text(style.title(language: language)).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.showNotchSideHandleArea)
            }
        }
    }

    private var panelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.text(.panelsSectionTitle))
                .font(.system(size: 13, weight: .bold))

            Toggle(settings.text(.openLastUsedPanel), isOn: $settings.rememberLastSelectedProvider)

            VStack(alignment: .leading, spacing: 6) {
                Picker(settings.text(.panelSize), selection: $settings.panelSize) {
                    ForEach(PanelSizeOption.allCases) { option in
                        Text(option.title(language: language)).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.panelSize.detail(language: language))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker(settings.text(.panelTextSize), selection: $settings.panelTextSize) {
                    ForEach(PanelTextSizeOption.allCases) { option in
                        Text(option.title(language: language)).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.panelTextSize.detail(language: language))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !settings.rememberLastSelectedProvider, !providerStore.visibleManifests.isEmpty {
                Picker(settings.text(.defaultPanel), selection: preferredProviderSelection) {
                    ForEach(providerStore.visibleManifests) { manifest in
                        Label(manifest.title(language: language), systemImage: manifest.symbolName)
                            .tag(manifest.id.rawValue)
                    }
                }
            }
        }
    }

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.text(.providersSectionTitle))
                .font(.system(size: 13, weight: .bold))

            VStack(alignment: .leading, spacing: 6) {
                Picker(settings.text(.iconSwitching), selection: $settings.providerSwitchingMode) {
                    ForEach(ProviderSwitchingMode.allCases) { mode in
                        Text(mode.title(language: language)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.providerSwitchingMode.detail(language: language))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(settings.text(.providerOrderHint))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(settings.orderedManifests(providerStore.registry.manifests)) { manifest in
                    HStack(spacing: 8) {
                        Image(systemName: manifest.symbolName)
                            .frame(width: 18)
                            .foregroundStyle(.secondary)

                        Text(manifest.title(language: language))
                            .font(.system(size: 12))

                        Spacer()

                        Toggle(
                            "",
                            isOn: providerVisibilityBinding(for: manifest)
                        )
                        .labelsHidden()
                        .disabled(isOnlyVisibleProvider(manifest))
                    }
                }
            }
        }
    }

    private var voiceLaneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Codex Voice Lane")
                .font(.system(size: 13, weight: .bold))

            Toggle(
                localized(
                    japanese: "音声会話レーンを表示",
                    english: "Show the voice conversation lane"
                ),
                isOn: $settings.codexVoiceEnabled
            )

            Text(
                localized(
                    japanese: "すべてのパネルの最下段に同じ会話を表示します。既定ではオフです。",
                    english: "Shows the same conversation below every panel. It is off by default."
                )
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Picker(
                localized(japanese: "表示", english: "Layout"),
                selection: $settings.codexVoiceLayoutMode
            ) {
                ForEach(VoiceLaneLayoutMode.allCases) { mode in
                    Text(mode.title(language: language)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!settings.codexVoiceEnabled)

            Toggle(
                localized(
                    japanese: "開いたときに自動で聞き始める",
                    english: "Start listening when opened"
                ),
                isOn: $settings.codexVoiceAutoListen
            )
            .disabled(!settings.codexVoiceEnabled)

            Toggle(
                localized(
                    japanese: "今日の予定タイトルと時間をCodexと共有",
                    english: "Share today's event titles and times with Codex"
                ),
                isOn: $settings.codexVoiceCalendarReadEnabled
            )
            .disabled(!settings.codexVoiceEnabled)

            Text(
                localized(
                    japanese: "Calendarの読み取りはこの許可をオンにした場合だけ利用できます。いつでもオフにできます。",
                    english: "Calendar reads are available only while this permission is enabled. You can revoke it at any time."
                )
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text(
                localized(
                    japanese: "自動リスニングはVoice Laneとは別に明示設定し、音声は保存しません。",
                    english: "Auto listen is a separate opt-in. Audio is not stored."
                )
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var handleIconDetail: String {
        if !settings.showNotchSideHandleArea {
            return settings.text(.handleIconHiddenDetail)
        }
        return settings.pillHandleIconStyle.detail(language: language)
    }

    private var mirrorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.text(.mirror))
                .font(.system(size: 13, weight: .bold))

            Toggle(settings.text(.showMicrophoneTest), isOn: $settings.showMirrorMicrophoneCheck)

            Text(settings.text(.microphoneTestDetail))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stickyNotesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.text(.stickyNotes))
                .font(.system(size: 13, weight: .bold))

            Toggle(settings.text(.showStickyNoteUndo), isOn: $settings.showStickyNoteUndoToast)
        }
    }

    private var weatherSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.text(.weather))
                .font(.system(size: 13, weight: .bold))

            HStack(spacing: 8) {
                Image(systemName: locationSymbol)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.weatherLocation.displayName(language: language))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(settings.weatherLocation.detail(language: language))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if weatherLocationModel.isLocating {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Button {
                weatherLocationModel.requestCurrentLocation(language: language) { location in
                    if let location {
                        settings.weatherLocation = location
                    }
                }
            } label: {
                Label(
                    localized(
                        japanese: "現在地を使用",
                        english: "Use current location"
                    ),
                    systemImage: "location.fill"
                )
            }
            .disabled(weatherLocationModel.isLocating)

            HStack(spacing: 8) {
                TextField(
                    localized(
                        japanese: "都市名または郵便番号",
                        english: "City or postal code"
                    ),
                    text: $weatherLocationModel.searchText
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    weatherLocationModel.search(language: language)
                }

                Button {
                    weatherLocationModel.search(language: language)
                } label: {
                    if weatherLocationModel.isSearching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .disabled(weatherLocationModel.isSearching)
                .help(localized(japanese: "地域を検索", english: "Search locations"))
            }

            if !weatherLocationModel.searchResults.isEmpty {
                VStack(spacing: 0) {
                    ForEach(weatherLocationModel.searchResults.prefix(6)) { location in
                        Button {
                            settings.weatherLocation = location
                            weatherLocationModel.clearSearch()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "mappin")
                                    .frame(width: 14)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(location.displayName(language: language))
                                        .font(.system(size: 11, weight: .medium))
                                    Text(location.detail(language: language))
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)

                        if location.id != weatherLocationModel.searchResults.prefix(6).last?.id {
                            Divider()
                        }
                    }
                }
                .background(.quaternary.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            if let message = weatherLocationModel.message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker(
                localized(
                    japanese: "日本の都道府県",
                    english: "Japanese prefecture"
                ),
                selection: japaneseRegionSelection
            ) {
                Text(localized(japanese: "選択してください", english: "Choose…"))
                    .tag("")
                ForEach(WeatherRegion.allRegions) { region in
                    Text(region.name(language: language))
                        .tag(region.id)
                }
            }

            Picker(
                localized(japanese: "温度単位", english: "Temperature unit"),
                selection: $settings.weatherTemperatureUnit
            ) {
                ForEach(WeatherTemperatureUnitOption.allCases) { option in
                    Text(option.title(language: language))
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)

            Text(settings.text(.weatherRegionDetail))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var japaneseRegionSelection: Binding<String> {
        Binding(
            get: { settings.weatherLocation.legacyRegionID ?? "" },
            set: { regionID in
                guard let region = WeatherRegion.region(id: regionID) else { return }
                settings.weatherLocation = WeatherLocation.from(region: region)
                weatherLocationModel.clearSearch()
            }
        )
    }

    private var locationSymbol: String {
        settings.weatherLocation.source == .currentLocation
            ? "location.fill"
            : "mappin.and.ellipse"
    }

    private func localized(japanese: String, english: String) -> String {
        language == .japanese ? japanese : english
    }

    private var googleCalendarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.text(.calendarSectionTitle))
                .font(.system(size: 13, weight: .bold))

            HStack(spacing: 10) {
                calendarStatus

                Spacer()

                if calendarStore.isSignedIn {
                    Button(settings.text(.disconnect)) {
                        calendarStore.signOut()
                    }
                } else {
                    Button(calendarConnectTitle) {
                        calendarStore.connect()
                    }
                    .disabled(!calendarStore.isConfigured || calendarStore.connectionState == .signingIn || calendarStore.connectionState == .restoring)
                }
            }

            if let message = calendarStore.lastErrorMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.text(.updates))
                .font(.system(size: 13, weight: .bold))

            HStack(spacing: 10) {
                Label(appUpdater.statusText(language: language), systemImage: appUpdater.statusSystemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(settings.text(.checkForUpdates)) {
                    appUpdater.checkForUpdates()
                }
                .disabled(!appUpdater.canCheckForUpdates)
            }
        }
    }

    private var preferredProviderSelection: Binding<String> {
        Binding(
            get: {
                let visible = providerStore.visibleManifests
                if let preferred = settings.preferredProviderRawValue,
                   visible.contains(where: { $0.id.rawValue == preferred }) {
                    return preferred
                }
                return visible.first?.id.rawValue ?? ""
            },
            set: { settings.preferredProviderRawValue = $0 }
        )
    }

    private func providerVisibilityBinding(for manifest: PluginManifest) -> Binding<Bool> {
        Binding(
            get: {
                settings.isProviderVisible(manifest.id)
            },
            set: { isVisible in
                settings.setProvider(
                    manifest.id,
                    isVisible: isVisible,
                    manifests: providerStore.registry.manifests
                )
            }
        )
    }

    private func isOnlyVisibleProvider(_ manifest: PluginManifest) -> Bool {
        settings.isProviderVisible(manifest.id) && providerStore.visibleManifests.count <= 1
    }

    private var calendarStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: calendarStatusSymbol)
                .foregroundStyle(calendarStore.isSignedIn ? .green : .secondary)

            Text(calendarStatusText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var calendarStatusSymbol: String {
        switch calendarStore.connectionState {
        case .missingConfiguration:
            return "key.slash"
        case .restoring:
            return "arrow.triangle.2.circlepath"
        case .signedOut:
            return "person.crop.circle.badge.plus"
        case .needsReconnect:
            return "exclamationmark.arrow.triangle.2.circlepath"
        case .signingIn:
            return "arrow.triangle.2.circlepath"
        case .signedIn:
            return "checkmark.circle.fill"
        }
    }

    private var calendarStatusText: String {
        switch calendarStore.connectionState {
        case .missingConfiguration:
            return settings.text(.calendarConfigMissingDetail)
        case .restoring:
            return settings.text(.calendarConnectionChecking)
        case .signedOut:
            return settings.text(.calendarConnectionNotConnected)
        case .needsReconnect:
            return settings.text(.calendarConnectionReconnect)
        case .signingIn:
            return settings.text(.calendarConnectionConnecting)
        case .signedIn:
            return settings.text(.calendarConnectionConnected)
        }
    }

    private var calendarConnectTitle: String {
        switch calendarStore.connectionState {
        case .signingIn:
            return settings.text(.calendarConnectConnecting)
        case .restoring:
            return settings.text(.calendarConnectChecking)
        case .needsReconnect:
            return settings.text(.calendarConnectReconnect)
        default:
            return settings.text(.calendarConnectOpenLogin)
        }
    }

}
