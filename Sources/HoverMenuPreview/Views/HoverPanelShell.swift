import AppKit
import SwiftUI

struct HoverPanelShell: View {
    let hoverState: HoverState
    @ObservedObject var store: HoverMenuStore
    @ObservedObject var settings: AppSettings
    let onOpenSettings: () -> Void
    let onExternalDragStarted: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.02, green: 0.02, blue: 0.025))

            VStack(spacing: 0) {
                ProviderHeaderView(
                    providerStore: store.providerStore,
                    settings: settings,
                    onOpenSettings: onOpenSettings
                )

                Divider()
                    .overlay(Color.white.opacity(0.08))

                PluginHostView(
                    providerStore: store.providerStore,
                    settings: settings,
                    isPreviewActive: store.providerActive,
                    onExternalDragStarted: onExternalDragStarted
                )
            }
            .opacity(store.contentVisible ? 1 : 0)
            .scaleEffect(store.contentVisible ? 1 : 0.92, anchor: .top)
            .offset(y: store.contentVisible ? 0 : -14)
        }
        .frame(
            width: PanelLayout.previewSize(for: settings.panelSize).width,
            height: PanelLayout.previewSize(for: settings.panelSize).height
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .onHover { inside in
            inside ? hoverState.onEnter() : hoverState.onExit()
        }
    }

}

private struct ProviderHeaderView: View {
    @ObservedObject var providerStore: ProviderStore
    @ObservedObject var settings: AppSettings
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(providerStore.selectedProvider?.manifest.title ?? "Plugins")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)

                PanelSizeCycleButton(settings: settings)
            }

            Spacer()

            if providerStore.visibleManifests.count > 1 {
                ForEach(providerStore.visibleManifests) { manifest in
                    providerButton(manifest)
                }
            }

            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle(selected: false))
            .help("Settings")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(IconButtonStyle(selected: false))
            .help("Quit")
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    private func providerButton(_ manifest: PluginManifest) -> some View {
        Button {
            providerStore.select(manifest.id)
        } label: {
            Image(systemName: manifest.symbolName)
        }
        .buttonStyle(IconButtonStyle(selected: providerStore.selectedPluginID == manifest.id))
        .help(manifest.title)
        .contextMenu {
            Button("Move Left") {
                providerStore.moveProvider(manifest.id, by: -1)
            }
            .disabled(!providerStore.canMoveProvider(manifest.id, by: -1))

            Button("Move Right") {
                providerStore.moveProvider(manifest.id, by: 1)
            }
            .disabled(!providerStore.canMoveProvider(manifest.id, by: 1))
        }
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
