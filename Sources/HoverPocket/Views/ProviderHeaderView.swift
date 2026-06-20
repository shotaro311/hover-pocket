import SwiftUI

struct ProviderHeaderView: View {
    @ObservedObject var providerStore: ProviderStore
    @ObservedObject var settings: AppSettings
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            titleArea

            Spacer()

            if providerStore.visibleManifests.count > 1 {
                providerButtons

                HeaderIconDivider()
            }

            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle(selected: false))
            .help("Settings")
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    private var titleArea: some View {
        HStack(spacing: 8) {
            Text(providerStore.selectedProvider?.manifest.title ?? "Plugins")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)

            PanelSizeCycleButton(settings: settings)
        }
    }

    private var providerButtons: some View {
        ForEach(providerStore.visibleManifests) { manifest in
            ProviderIconButton(
                manifest: manifest,
                isSelected: providerStore.selectedPluginID == manifest.id,
                switchingMode: settings.providerSwitchingMode,
                canMoveLeft: providerStore.canMoveProvider(manifest.id, by: -1),
                canMoveRight: providerStore.canMoveProvider(manifest.id, by: 1),
                onSelect: { providerStore.select(manifest.id) },
                onMoveLeft: { providerStore.moveProvider(manifest.id, by: -1) },
                onMoveRight: { providerStore.moveProvider(manifest.id, by: 1) }
            )
        }
    }
}

private struct ProviderIconButton: View {
    let manifest: PluginManifest
    let isSelected: Bool
    let switchingMode: ProviderSwitchingMode
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let onSelect: () -> Void
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void

    var body: some View {
        Button {
            selectIfClickMode()
        } label: {
            Image(systemName: manifest.symbolName)
        }
        .buttonStyle(IconButtonStyle(selected: isSelected))
        .help(manifest.title)
        .onHover { inside in
            guard inside else { return }
            selectIfHoverMode()
        }
        .contextMenu {
            Button("Move Left") {
                onMoveLeft()
            }
            .disabled(!canMoveLeft)

            Button("Move Right") {
                onMoveRight()
            }
            .disabled(!canMoveRight)
        }
    }

    private func selectIfClickMode() {
        guard switchingMode == .click else { return }
        onSelect()
    }

    private func selectIfHoverMode() {
        guard switchingMode == .hover else { return }
        onSelect()
    }
}

private struct HeaderIconDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 2)
    }
}

private struct PanelSizeCycleButton: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Button {
            settings.panelSize = settings.panelSize.next
        } label: {
            Text(settings.panelSize.shortTitle)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
                .frame(width: 22, height: 20)
                .contentTransition(.opacity)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.16), value: settings.panelSize)
        .accessibilityLabel("Panel size \(settings.panelSize.shortTitle)")
        .help("Panel size: \(settings.panelSize.title)")
    }
}
