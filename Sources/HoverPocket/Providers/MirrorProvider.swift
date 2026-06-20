import SwiftUI

struct MirrorProvider: PocketProvider {
    static let pluginID = PluginID(rawValue: "mirror")

    let manifest = PluginManifest(
        id: Self.pluginID,
        title: "Mirror",
        symbolName: "person.crop.rectangle",
        defaultEnabled: true,
        requestedPermissions: [.camera, .microphone],
        refreshPolicy: .eventDriven
    )

    @MainActor
    func makePreview(
        snapshot: ProviderSnapshot?,
        state: ProviderState,
        actions: ProviderActions
    ) -> AnyView {
        AnyView(MirrorPreviewView(isActive: actions.isPreviewActive, settings: actions.settings))
    }
}
