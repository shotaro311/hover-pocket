import SwiftUI

struct StickyNotesProvider: PocketProvider {
    static let pluginID = PluginID(rawValue: "sticky-notes")

    let manifest = PluginManifest(
        id: StickyNotesProvider.pluginID,
        title: "Sticky Notes",
        symbolName: "note.text",
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
        AnyView(StickyNotesView(actions: actions))
    }
}
