import Foundation
import SwiftUI

struct ProviderContext: Sendable {
    static let empty = ProviderContext()
}

struct ProviderActions {
    let refresh: @MainActor () -> Void

    init(refresh: @escaping @MainActor () -> Void = {}) {
        self.refresh = refresh
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
