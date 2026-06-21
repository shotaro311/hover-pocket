import SwiftUI

struct ControlsProvider: PocketProvider {
    static let pluginID = PluginID(rawValue: "controls")

    let manifest = PluginManifest(
        id: ControlsProvider.pluginID,
        title: "Controls",
        symbolName: "slider.horizontal.3",
        defaultEnabled: true,
        requestedPermissions: [],
        refreshPolicy: .eventDriven
    )

    @MainActor
    func makePreview(
        snapshot: ProviderSnapshot?,
        state: ProviderState,
        actions: ProviderActions
    ) -> AnyView {
        AnyView(ControlsView(settings: actions.settings, isActive: actions.isPreviewActive))
    }
}
