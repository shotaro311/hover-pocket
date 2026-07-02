import SwiftUI

struct TimerProvider: PocketProvider {
    static let pluginID = PluginID(rawValue: "timer")

    let manifest = PluginManifest(
        id: TimerProvider.pluginID,
        title: "Timer",
        symbolName: "timer",
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
        AnyView(TimerView(settings: actions.settings, isActive: actions.isPreviewActive))
    }
}
