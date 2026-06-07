import AppKit
import SwiftUI

struct HoverPanelShell: View {
    let hoverState: HoverState
    @ObservedObject var store: HoverMenuStore
    let onOpenSettings: () -> Void
    let onExternalDragStarted: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.02, green: 0.02, blue: 0.025))

            VStack(spacing: 0) {
                header

                Divider()
                    .overlay(Color.white.opacity(0.08))

                PluginHostView(
                    providerStore: store.providerStore,
                    settings: store.settings,
                    isPreviewActive: store.providerActive,
                    onExternalDragStarted: onExternalDragStarted
                )
            }
            .opacity(store.contentVisible ? 1 : 0)
            .scaleEffect(store.contentVisible ? 1 : 0.92, anchor: .top)
            .offset(y: store.contentVisible ? 0 : -14)
        }
        .frame(width: PanelLayout.previewSize.width, height: PanelLayout.previewSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .onHover { inside in
            inside ? hoverState.onEnter() : hoverState.onExit()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(store.providerStore.selectedProvider?.manifest.title ?? "Plugins")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)

            Spacer()

            if store.providerStore.visibleManifests.count > 1 {
                ForEach(store.providerStore.visibleManifests) { manifest in
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
            store.providerStore.select(manifest.id)
        } label: {
            Image(systemName: manifest.symbolName)
        }
        .buttonStyle(IconButtonStyle(selected: store.providerStore.selectedPluginID == manifest.id))
        .help(manifest.title)
        .contextMenu {
            Button("Move Left") {
                store.providerStore.moveProvider(manifest.id, by: -1)
            }
            .disabled(!store.providerStore.canMoveProvider(manifest.id, by: -1))

            Button("Move Right") {
                store.providerStore.moveProvider(manifest.id, by: 1)
            }
            .disabled(!store.providerStore.canMoveProvider(manifest.id, by: 1))
        }
    }
}
