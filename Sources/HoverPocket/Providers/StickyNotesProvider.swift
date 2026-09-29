import SwiftUI

struct StickyNotesProvider: PocketProvider {
    static let pluginID = PluginID(rawValue: "sticky-notes")

    private let store: StickyNotesStore?
    private let reminders: StickyReminderController?

    init(store: StickyNotesStore? = nil, reminders: StickyReminderController? = nil) {
        self.store = store
        self.reminders = reminders
    }

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
        AnyView(StickyNotesView(
            actions: actions,
            store: store ?? .shared,
            reminders: reminders ?? .shared
        ))
    }
}
