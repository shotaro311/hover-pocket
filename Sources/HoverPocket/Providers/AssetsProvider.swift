import SwiftUI

struct AssetsProvider: PocketProvider {
    static let pluginID = PluginID(rawValue: "assets")
    let manifest = PluginManifest(id: pluginID, title: "素材", symbolName: "photo.stack",
        defaultEnabled: true, requestedPermissions: [], refreshPolicy: .eventDriven)
    @MainActor func makePreview(snapshot: ProviderSnapshot?, state: ProviderState, actions: ProviderActions) -> AnyView {
        AnyView(AssetLibraryView(active: actions.isPreviewActive, language: actions.settings.appLanguage))
    }
}
