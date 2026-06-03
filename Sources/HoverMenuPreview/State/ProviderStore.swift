import Combine
import Foundation

@MainActor
final class ProviderStore: ObservableObject {
    let registry: ProviderRegistry
    @Published var selectedPluginID: PluginID?
    @Published private(set) var states: [PluginID: ProviderState]

    private var refreshTask: Task<Void, Never>?

    init(registry: ProviderRegistry = .empty) {
        self.registry = registry
        self.selectedPluginID = registry.manifests.first?.id
        self.states = Dictionary(
            uniqueKeysWithValues: registry.manifests.map { ($0.id, ProviderState.idle) }
        )
    }

    var selectedProvider: (any NotchProvider)? {
        registry.provider(for: selectedPluginID)
    }

    func select(_ id: PluginID) {
        selectedPluginID = id
        refreshSelected(reason: .userRequested)
    }

    func state(for id: PluginID) -> ProviderState {
        states[id] ?? .idle
    }

    func snapshot(for id: PluginID) -> ProviderSnapshot? {
        states[id]?.snapshot
    }

    func refreshSelected(reason: RefreshReason) {
        refreshTask?.cancel()

        guard let provider = selectedProvider else { return }

        let id = provider.manifest.id
        let previous = states[id]?.snapshot
        states[id] = ProviderState(phase: .loading, snapshot: previous)

        refreshTask = Task { [weak self, provider] in
            do {
                let snapshot = try await provider.refresh(context: .empty, reason: reason)
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.states[id] = ProviderState(phase: .ready, snapshot: snapshot)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.states[id] = ProviderState(
                        phase: .failed(error.localizedDescription),
                        snapshot: previous
                    )
                }
            }
        }
    }

    deinit {
        refreshTask?.cancel()
    }
}
