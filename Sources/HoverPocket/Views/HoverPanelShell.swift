import SwiftUI

struct HoverPanelShell: View {
    let hoverState: HoverState
    @ObservedObject var store: HoverMenuStore
    @ObservedObject var settings: AppSettings
    let onOpenSettings: () -> Void
    let onClosePanel: () -> Void
    let onExternalDragStarted: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.02, green: 0.02, blue: 0.025))

            VStack(spacing: 0) {
                ProviderHeaderView(
                    providerStore: store.providerStore,
                    settings: settings,
                    onOpenSettings: onOpenSettings,
                    onClosePanel: onClosePanel
                )

                Divider()
                    .overlay(Color.white.opacity(0.08))

                PluginHostView(
                    providerStore: store.providerStore,
                    settings: settings,
                    isPreviewActive: store.providerActive,
                    onExternalDragStarted: onExternalDragStarted
                )
                .frame(maxHeight: .infinity)

                Divider()
                    .overlay(Color.white.opacity(0.08))

                AICommandPaletteView(store: store.aiCommandStore, settings: settings, isVisible: store.contentVisible)
                    .frame(height: PanelLayout.aiPaletteHeight)
            }
            .opacity(store.contentVisible ? 1 : 0)
            .scaleEffect(store.contentVisible ? 1 : 0.92, anchor: .top)
            .offset(y: store.contentVisible ? 0 : -14)
        }
        .frame(
            width: PanelLayout.panelTotalSize(for: settings.panelSize).width,
            height: PanelLayout.panelTotalSize(for: settings.panelSize).height
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
