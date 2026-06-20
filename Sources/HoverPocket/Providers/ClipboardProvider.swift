import SwiftUI

struct ClipboardProvider: PocketProvider {
    static let pluginID = PluginID(rawValue: "clipboard-history")

    let manifest = PluginManifest(
        id: ClipboardProvider.pluginID,
        title: "Clipboard",
        symbolName: "doc.on.clipboard",
        defaultEnabled: true,
        requestedPermissions: [
            .clipboardRead,
            .clipboardWrite
        ],
        refreshPolicy: .eventDriven
    )

    @MainActor
    func makePreview(
        snapshot: ProviderSnapshot?,
        state: ProviderState,
        actions: ProviderActions
    ) -> AnyView {
        AnyView(ClipboardHistoryView(onExternalDragStarted: actions.beginExternalDrag))
    }
}
