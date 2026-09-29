import SwiftUI

struct PocketDraftProvider: PocketProvider {
    static let pluginID = PluginID(rawValue: "host-tool-preview")
    let manifest = PluginManifest(id: Self.pluginID, title: "試作プレビュー", symbolName: "sparkles.rectangle.stack",
                                  defaultEnabled: true, requestedPermissions: [], refreshPolicy: .manual)

    @MainActor
    func makePreview(snapshot: ProviderSnapshot?, state: ProviderState, actions: ProviderActions) -> AnyView {
        if let model = AINativeRuntime.shared.pocketAppGenerationController?.previewModel {
            return AnyView(PocketSurfaceHostView(model: model))
        }
        return AnyView(Text("試作はありません。"))
    }
}
