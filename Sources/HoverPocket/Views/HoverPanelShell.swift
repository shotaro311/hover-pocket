import SwiftUI

struct HoverPanelShell: View {
    let hoverState: HoverState
    @ObservedObject var store: HoverMenuStore
    @ObservedObject var settings: AppSettings
    @ObservedObject private var voiceRuntime = VoiceLaneRuntime.shared
    let onOpenSettings: () -> Void
    let onClosePanel: () -> Void
    let onExternalDragStarted: () -> Void

    var body: some View {
        let baseline = PanelLayout.panelTotalSize(for: settings.panelSize)
        let voiceHeight = VoiceLaneGeometry.height(
            panelSizeRawValue: settings.panelSize.rawValue,
            mode: voiceRuntime.snapshot.mode
        )

        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.02, green: 0.02, blue: 0.025))

            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    ProviderHeaderView(
                        providerStore: store.providerStore,
                        settings: settings,
                        onOpenSettings: onOpenSettings,
                        onClosePanel: {
                            voiceRuntime.detachPanel()
                            onClosePanel()
                        }
                    )

                    Divider()
                        .overlay(Color.white.opacity(0.08))

                    PluginHostView(
                        providerStore: store.providerStore,
                        settings: settings,
                        isPreviewActive: store.providerActive,
                        onExternalDragStarted: onExternalDragStarted,
                        onClosePanel: onClosePanel
                    )
                    .frame(maxHeight: .infinity)
                    .environment(\.panelTextSize, settings.panelTextSize)
                }
                .frame(width: baseline.width, height: baseline.height)

                VoiceLaneHostView(runtime: voiceRuntime, settings: settings)
            }
            .opacity(store.contentVisible ? 1 : 0)
            .scaleEffect(store.contentVisible ? 1 : 0.92, anchor: .top)
            .offset(y: store.contentVisible ? 0 : -14)
        }
        .frame(
            width: baseline.width,
            height: baseline.height + CGFloat(voiceHeight)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .onDisappear {
            voiceRuntime.detachPanel()
        }
        .onHover { inside in
            inside ? hoverState.onEnter() : hoverState.onExit()
        }
    }
}
