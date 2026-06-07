import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var providerStore: ProviderStore
    @ObservedObject private var calendarStore = GoogleCalendarStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                displaySection

                Divider()

                panelsSection

                Divider()

                mirrorSection

                Divider()

                googleCalendarSection
            }
            .padding(20)
        }
        .frame(width: 460, height: 500)
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Display")
                .font(.system(size: 13, weight: .bold))

            Picker("Display", selection: $settings.displayPlacementMode) {
                ForEach(DisplayPlacementMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(settings.displayPlacementMode.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var panelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Panels")
                .font(.system(size: 13, weight: .bold))

            Toggle("Open last used panel", isOn: $settings.rememberLastSelectedProvider)

            if !settings.rememberLastSelectedProvider, !providerStore.visibleManifests.isEmpty {
                Picker("Default panel", selection: preferredProviderSelection) {
                    ForEach(providerStore.visibleManifests) { manifest in
                        Label(manifest.title, systemImage: manifest.symbolName)
                            .tag(manifest.id.rawValue)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(settings.orderedManifests(providerStore.registry.manifests)) { manifest in
                    HStack(spacing: 8) {
                        Image(systemName: manifest.symbolName)
                            .frame(width: 18)
                            .foregroundStyle(.secondary)

                        Text(manifest.title)
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

    private var mirrorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mirror")
                .font(.system(size: 13, weight: .bold))

            Toggle("Show microphone test under mirror", isOn: $settings.showMirrorMicrophoneCheck)

            Text("Microphone starts only when you press the test button.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var googleCalendarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Google Calendar")
                .font(.system(size: 13, weight: .bold))

            HStack(spacing: 10) {
                calendarStatus

                Spacer()

                if calendarStore.isSignedIn {
                    Button("Disconnect") {
                        calendarStore.signOut()
                    }
                } else {
                    Button(calendarConnectTitle) {
                        calendarStore.signIn()
                    }
                    .disabled(!calendarStore.isConfigured || calendarStore.connectionState == .signingIn)
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
            return "Set GOOGLE_CLIENT_ID and relaunch."
        case .signedOut:
            return "Not connected"
        case .needsReconnect:
            return "Reconnect to allow editing"
        case .signingIn:
            return "Waiting for Google sign-in"
        case .signedIn:
            return "Connected"
        }
    }

    private var calendarConnectTitle: String {
        switch calendarStore.connectionState {
        case .signingIn:
            return "Connecting"
        case .needsReconnect:
            return "Reconnect"
        default:
            return "Connect"
        }
    }
}
