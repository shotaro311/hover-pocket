import SwiftUI

struct AiUsageProvider: PocketProvider {
    static let pluginID = PluginID(rawValue: "ai-usage")

    let manifest = PluginManifest(
        id: Self.pluginID, title: "AI Usage", symbolName: "gauge.with.dots.needle.67percent",
        defaultEnabled: true, requestedPermissions: [], refreshPolicy: .manual
    )

    @MainActor
    func makePreview(snapshot: ProviderSnapshot?, state: ProviderState, actions: ProviderActions) -> AnyView {
        AnyView(AiUsagePanelView(
            settings: actions.settings, usage: .shared, isActive: actions.isPreviewActive,
            openSettings: actions.openAISettings
        ))
    }
}
