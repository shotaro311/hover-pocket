import SwiftUI

struct TodayFocusPocketProvider: PocketProvider {
    static let pluginID = PluginID(rawValue: "today-focus")

    let manifest = PluginManifest(
        id: TodayFocusPocketProvider.pluginID,
        title: "Today Focus",
        symbolName: "target",
        defaultEnabled: false,
        requestedPermissions: [
            .calendarRead
        ],
        refreshPolicy: .eventDriven
    )

    @MainActor
    func makePreview(
        snapshot: ProviderSnapshot?,
        state: ProviderState,
        actions: ProviderActions
    ) -> AnyView {
        _ = snapshot
        _ = state
        return AnyView(TodayFocusPocketView(settings: actions.settings))
    }
}

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

private struct TodayFocusPocketView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var aiRuntime = AINativeRuntime.shared

    var body: some View {
        Group {
            if !settings.aiNativeEnabled {
                unavailable("AIネイティブ機能はオフです。")
            } else if let runtime = aiRuntime.pocketAppExecutionRuntime,
                      let model = try? PocketSurfaceHostModel(runtime: runtime, surfaceID: "main") {
                PocketSurfaceHostView(model: model).id(model.runtimeIdentity)
            } else {
                unavailable("Today Focusを準備できませんでした。")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailable(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "target")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.34))
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.56))
        }
    }
}
