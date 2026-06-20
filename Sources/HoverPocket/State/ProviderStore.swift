import Combine
import Foundation

@MainActor
final class ProviderStore: ObservableObject {
    let registry: ProviderRegistry
    @Published var selectedPluginID: PluginID?
    @Published private(set) var states: [PluginID: ProviderState]
    @Published private(set) var isPanelOnSecondaryDisplay = false

    private let settings: AppSettings
    private var settingsCancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?

    init(registry: ProviderRegistry = .empty, settings: AppSettings = AppSettings()) {
        self.registry = registry
        self.settings = settings
        self.selectedPluginID = settings.providerSelectionForPanelOpen(manifests: registry.manifests)
        self.states = Dictionary(
            uniqueKeysWithValues: registry.manifests.map { ($0.id, ProviderState.idle) }
        )
        observeSettings()
        syncProviderSideEffects()
    }

    var visibleManifests: [PluginManifest] {
        let manifests = settings.visibleManifests(registry.manifests)
        guard isPanelOnSecondaryDisplay, !settings.showMirrorOnSecondaryDisplays else {
            return manifests
        }
        return manifests.filter { $0.id != MirrorProvider.pluginID }
    }

    var selectedProvider: (any PocketProvider)? {
        guard let selectedPluginID,
              visibleManifests.contains(where: { $0.id == selectedPluginID })
        else {
            return registry.provider(for: visibleManifests.first?.id)
        }
        return registry.provider(for: selectedPluginID)
    }

    func select(_ id: PluginID) {
        guard selectedPluginID != id else { return }
        guard visibleManifests.contains(where: { $0.id == id }) else { return }
        selectedPluginID = id
        settings.recordProviderSelection(id)
        refreshSelected(reason: .userRequested)
    }

    func prepareForPanelOpen(isSecondaryDisplay: Bool = false) {
        if isPanelOnSecondaryDisplay != isSecondaryDisplay {
            isPanelOnSecondaryDisplay = isSecondaryDisplay
        }

        guard let id = providerSelectionForCurrentPanel() else {
            selectedPluginID = nil
            return
        }
        if selectedPluginID != id {
            selectedPluginID = id
        }
    }

    func prepareForPanelClose() {
        guard isPanelOnSecondaryDisplay else { return }
        isPanelOnSecondaryDisplay = false
        settingsDidChange()
    }

    func moveProvider(_ id: PluginID, by offset: Int) {
        settings.moveProvider(id, by: offset, manifests: registry.manifests)
    }

    func moveProvider(_ id: PluginID, to targetID: PluginID) {
        settings.moveProvider(id, to: targetID, manifests: registry.manifests)
    }

    func canMoveProvider(_ id: PluginID, by offset: Int) -> Bool {
        let orderedIDs = visibleManifests.map(\.id)
        guard let index = orderedIDs.firstIndex(of: id) else { return false }
        let destination = index + offset
        return destination >= 0 && destination < orderedIDs.count
    }

    func state(for id: PluginID) -> ProviderState {
        states[id] ?? .idle
    }

    func snapshot(for id: PluginID) -> ProviderSnapshot? {
        states[id]?.snapshot
    }

    func refreshSelected(reason: RefreshReason) {
        guard let provider = selectedProvider else { return }
        guard shouldRefresh(provider: provider, reason: reason) else { return }

        refreshTask?.cancel()

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

    private func observeSettings() {
        settings.$providerOrderRawValues
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleSettingsDidChange()
            }
            .store(in: &settingsCancellables)

        settings.$hiddenProviderRawValues
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleSettingsDidChange()
            }
            .store(in: &settingsCancellables)

        settings.$showMirrorOnSecondaryDisplays
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleSettingsDidChange()
            }
            .store(in: &settingsCancellables)
    }

    private func scheduleSettingsDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.settingsDidChange()
        }
    }

    private func settingsDidChange() {
        syncSelectionWithSettings()
        syncProviderSideEffects()
        objectWillChange.send()
    }

    private func syncSelectionWithSettings() {
        let visibleIDs = Set(visibleManifests.map(\.id))
        if let selectedPluginID, visibleIDs.contains(selectedPluginID) {
            return
        }
        selectedPluginID = providerSelectionForCurrentPanel()
    }

    private func syncProviderSideEffects() {
        let clipboardVisible = visibleManifests.contains { $0.id == ClipboardProvider.pluginID }
        if clipboardVisible {
            ClipboardHistoryStore.shared.startMonitoring()
        } else {
            ClipboardHistoryStore.shared.stopMonitoring()
        }
    }

    private func providerSelectionForCurrentPanel() -> PluginID? {
        let visible = visibleManifests
        let visibleIDs = Set(visible.map(\.id.rawValue))
        if settings.rememberLastSelectedProvider,
           let lastSelectedProviderRawValue = settings.lastSelectedProviderRawValue,
           visibleIDs.contains(lastSelectedProviderRawValue) {
            return PluginID(rawValue: lastSelectedProviderRawValue)
        }
        if let preferredProviderRawValue = settings.preferredProviderRawValue,
           visibleIDs.contains(preferredProviderRawValue) {
            return PluginID(rawValue: preferredProviderRawValue)
        }
        return visible.first?.id
    }

    private func shouldRefresh(provider: any PocketProvider, reason: RefreshReason) -> Bool {
        switch reason {
        case .appLaunch:
            return provider.manifest.refreshPolicy != .manual
        case .panelOpened:
            return provider.manifest.refreshPolicy == .onPanelOpen
        case .timer:
            if case .interval = provider.manifest.refreshPolicy {
                return true
            }
            return false
        case .userRequested:
            return true
        case .dependencyChanged:
            return provider.manifest.refreshPolicy != .manual
        }
    }

    deinit {
        refreshTask?.cancel()
    }
}
