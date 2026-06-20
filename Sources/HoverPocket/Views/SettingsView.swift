import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var providerStore: ProviderStore
    @ObservedObject private var calendarStore = GoogleCalendarStore.shared
    @ObservedObject private var appUpdater = AppUpdater.shared

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

                providersSection

                Divider()

                stickyNotesSection

                Divider()

                mirrorSection

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
