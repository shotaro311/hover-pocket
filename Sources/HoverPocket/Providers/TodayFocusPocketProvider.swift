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

private struct TodayFocusPocketView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var aiRuntime = AINativeRuntime.shared

    var body: some View {
        Group {
            if !settings.aiNativeEnabled {
                unavailable("AIネイティブ機能はオフです。")
            } else if let runtime = aiRuntime.pocketAppExecutionRuntime,
                      let model = try? PocketSurfaceHostModel(runtime: runtime, surfaceID: "main") {
                PocketSurfaceHostView(model: model)
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
