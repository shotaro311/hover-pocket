import Foundation
import SwiftUI

struct ProviderContext: Sendable {
    static let empty = ProviderContext()
}

struct ProviderActions {
    let isPreviewActive: Bool
    let settings: AppSettings
    let refresh: @MainActor () -> Void
    let beginExternalDrag: @MainActor () -> Void
    let closePanel: @MainActor () -> Void
    let openAISettings: @MainActor () -> Void

    init(
        isPreviewActive: Bool = false,
        settings: AppSettings,
        refresh: @escaping @MainActor () -> Void = {},
        beginExternalDrag: @escaping @MainActor () -> Void = {},
        closePanel: @escaping @MainActor () -> Void = {},
        openAISettings: @escaping @MainActor () -> Void = {}
    ) {
        self.isPreviewActive = isPreviewActive
        self.settings = settings
        self.refresh = refresh
        self.beginExternalDrag = beginExternalDrag
        self.closePanel = closePanel
        self.openAISettings = openAISettings
    }
}

protocol PocketProvider: Sendable {
    var manifest: PluginManifest { get }

    func refresh(context: ProviderContext, reason: RefreshReason) async throws -> ProviderSnapshot

    @MainActor
    func makePreview(
        snapshot: ProviderSnapshot?,
        state: ProviderState,
        actions: ProviderActions
    ) -> AnyView
}

extension PocketProvider {
    func refresh(context: ProviderContext, reason: RefreshReason) async throws -> ProviderSnapshot {
        ProviderSnapshot.empty
    }
}
