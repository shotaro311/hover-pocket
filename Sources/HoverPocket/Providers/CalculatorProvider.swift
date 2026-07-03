import SwiftUI

struct CalculatorProvider: PocketProvider {
    static let pluginID = PluginID(rawValue: "calculator")

    let manifest = PluginManifest(
        id: CalculatorProvider.pluginID,
        title: "Calculator",
        symbolName: "function",
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
        AnyView(CalculatorView(actions: actions))
    }
}
