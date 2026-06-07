import Foundation
import SwiftUI

struct ProviderContext: Sendable {
    static let empty = ProviderContext()
}

struct ProviderActions {
    let isPreviewActive: Bool
    let refresh: @MainActor () -> Void
    let beginExternalDrag: @MainActor () -> Void

    init(
        isPreviewActive: Bool = false,
        refresh: @escaping @MainActor () -> Void = {},
        beginExternalDrag: @escaping @MainActor () -> Void = {}
    ) {
        self.isPreviewActive = isPreviewActive
        self.refresh = refresh
        self.beginExternalDrag = beginExternalDrag
    }
}

protocol NotchProvider: Sendable {
    var manifest: PluginManifest { get }

    func refresh(context: ProviderContext, reason: RefreshReason) async throws -> ProviderSnapshot

    @MainActor
    func makePreview(
        snapshot: ProviderSnapshot?,
        state: ProviderState,
        actions: ProviderActions
    ) -> AnyView
}

extension NotchProvider {
    func refresh(context: ProviderContext, reason: RefreshReason) async throws -> ProviderSnapshot {
        ProviderSnapshot.empty
    }
}
