import SwiftUI

struct GeneratedPocketAppProvider: PocketProvider {
    let appID: String
    let surfaceID: String
    let title: String

    var manifest: PluginManifest {
        PluginManifest(
            id: PluginID(rawValue: PocketSurfaceRegistry.generatedProviderID(appID: appID)),
            title: title,
            symbolName: "sparkles.rectangle.stack",
            defaultEnabled: true,
            requestedPermissions: [],
            refreshPolicy: .eventDriven
        )
    }

    @MainActor
    func makePreview(
        snapshot: ProviderSnapshot?,
        state: ProviderState,
        actions: ProviderActions
    ) -> AnyView {
        _ = snapshot
        _ = state
        _ = actions
        AINativeRuntime.shared.recordGeneratedAppUse(appID: appID)
        guard let registry = AINativeRuntime.shared.generatedSurfaceRegistry,
              let model = try? registry.model(appID: appID, surfaceID: surfaceID) else {
            return AnyView(GeneratedPocketAppUnavailableView())
        }
        return AnyView(PocketSurfaceHostView(model: model).id(model.runtimeIdentity))
    }
}

private struct GeneratedPocketAppUnavailableView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.34))
            Text("このPocket Appは現在利用できません。")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.56))
        }
    }
}

