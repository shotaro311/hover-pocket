import SwiftUI

struct GoogleCalendarProvider: PocketProvider {
    let manifest = PluginManifest(
        id: PluginID(rawValue: "google-calendar"),
        title: "Calendar",
        symbolName: "calendar",
        defaultEnabled: true,
        requestedPermissions: [
            .calendarRead,
            .calendarWrite,
            .network(domain: "accounts.google.com"),
            .network(domain: "oauth2.googleapis.com"),
            .network(domain: "www.googleapis.com")
        ],
        refreshPolicy: .eventDriven
    )

    @MainActor
    func makePreview(
        snapshot: ProviderSnapshot?,
        state: ProviderState,
        actions: ProviderActions
    ) -> AnyView {
        AnyView(GoogleCalendarPreviewView(isActive: actions.isPreviewActive, settings: actions.settings))
    }
}
