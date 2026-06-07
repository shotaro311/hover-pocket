import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published var displayPlacementMode: DisplayPlacementMode {
        didSet {
            defaults.set(displayPlacementMode.rawValue, forKey: Self.displayPlacementModeKey)
        }
    }

    @Published var providerOrderRawValues: [String] {
        didSet {
            defaults.set(providerOrderRawValues, forKey: Self.providerOrderKey)
        }
    }

    @Published var hiddenProviderRawValues: Set<String> {
        didSet {
            defaults.set(Array(hiddenProviderRawValues).sorted(), forKey: Self.hiddenProvidersKey)
        }
    }

    @Published var rememberLastSelectedProvider: Bool {
        didSet {
            defaults.set(rememberLastSelectedProvider, forKey: Self.rememberLastSelectedProviderKey)
        }
    }

    @Published var preferredProviderRawValue: String? {
        didSet {
            setOptionalString(preferredProviderRawValue, forKey: Self.preferredProviderKey)
        }
    }

    @Published var lastSelectedProviderRawValue: String? {
        didSet {
            setOptionalString(lastSelectedProviderRawValue, forKey: Self.lastSelectedProviderKey)
        }
    }

    @Published var showMirrorMicrophoneCheck: Bool {
        didSet {
            defaults.set(showMirrorMicrophoneCheck, forKey: Self.showMirrorMicrophoneCheckKey)
        }
    }

    private let defaults: UserDefaults
    private static let displayPlacementModeKey = "displayPlacementMode"
    private static let providerOrderKey = "providerOrder"
    private static let hiddenProvidersKey = "hiddenProviders"
    private static let rememberLastSelectedProviderKey = "rememberLastSelectedProvider"
    private static let preferredProviderKey = "preferredProvider"
    private static let lastSelectedProviderKey = "lastSelectedProvider"
    private static let showMirrorMicrophoneCheckKey = "showMirrorMicrophoneCheck"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let rawValue = defaults.string(forKey: Self.displayPlacementModeKey)
        self.displayPlacementMode = rawValue.flatMap(DisplayPlacementMode.init(rawValue:)) ?? .automatic
        self.providerOrderRawValues = defaults.stringArray(forKey: Self.providerOrderKey) ?? []
        let hiddenValues = defaults.stringArray(forKey: Self.hiddenProvidersKey) ?? []
        self.hiddenProviderRawValues = Set(hiddenValues)
        if defaults.object(forKey: Self.rememberLastSelectedProviderKey) == nil {
            self.rememberLastSelectedProvider = true
        } else {
            self.rememberLastSelectedProvider = defaults.bool(forKey: Self.rememberLastSelectedProviderKey)
        }
        self.preferredProviderRawValue = defaults.string(forKey: Self.preferredProviderKey)
        self.lastSelectedProviderRawValue = defaults.string(forKey: Self.lastSelectedProviderKey)
        if defaults.object(forKey: Self.showMirrorMicrophoneCheckKey) == nil {
            self.showMirrorMicrophoneCheck = false
        } else {
            self.showMirrorMicrophoneCheck = defaults.bool(forKey: Self.showMirrorMicrophoneCheckKey)
        }
    }

    func orderedManifests(_ manifests: [PluginManifest]) -> [PluginManifest] {
        let byID = Dictionary(uniqueKeysWithValues: manifests.map { ($0.id.rawValue, $0) })
        let ordered = providerOrderRawValues.compactMap { byID[$0] }
        let orderedIDs = Set(ordered.map(\.id.rawValue))
        let missing = manifests.filter { !orderedIDs.contains($0.id.rawValue) }
        return ordered + missing
    }

    func visibleManifests(_ manifests: [PluginManifest]) -> [PluginManifest] {
        orderedManifests(manifests)
            .filter { !hiddenProviderRawValues.contains($0.id.rawValue) }
    }

    func isProviderVisible(_ id: PluginID) -> Bool {
        !hiddenProviderRawValues.contains(id.rawValue)
    }

    func setProvider(_ id: PluginID, isVisible: Bool, manifests: [PluginManifest]) {
        var hidden = hiddenProviderRawValues
        if isVisible {
            hidden.remove(id.rawValue)
        } else {
            let visibleCount = visibleManifests(manifests).count
            guard visibleCount > 1 else { return }
            hidden.insert(id.rawValue)
        }
        hiddenProviderRawValues = hidden

        let visibleIDs = Set(visibleManifests(manifests).map(\.id.rawValue))
        if let preferredProviderRawValue, !visibleIDs.contains(preferredProviderRawValue) {
            self.preferredProviderRawValue = visibleIDs.first
        }
        if let lastSelectedProviderRawValue, !visibleIDs.contains(lastSelectedProviderRawValue) {
            self.lastSelectedProviderRawValue = visibleIDs.first
        }
    }

    func moveProvider(_ id: PluginID, by offset: Int, manifests: [PluginManifest]) {
        let visibleIDs = visibleManifests(manifests).map(\.id.rawValue)
        guard let index = visibleIDs.firstIndex(of: id.rawValue) else { return }
        let destination = min(max(index + offset, 0), visibleIDs.count - 1)
        guard destination != index else { return }

        let targetID = visibleIDs[destination]
        var orderedIDs = orderedManifests(manifests).map(\.id.rawValue)
        orderedIDs.removeAll { $0 == id.rawValue }
        guard let targetIndex = orderedIDs.firstIndex(of: targetID) else { return }
        let insertionIndex = offset > 0 ? targetIndex + 1 : targetIndex
        orderedIDs.insert(id.rawValue, at: insertionIndex)
        providerOrderRawValues = orderedIDs
    }

    func providerSelectionForPanelOpen(manifests: [PluginManifest]) -> PluginID? {
        let visible = visibleManifests(manifests)
        let visibleIDs = Set(visible.map(\.id.rawValue))
        if rememberLastSelectedProvider,
           let lastSelectedProviderRawValue,
           visibleIDs.contains(lastSelectedProviderRawValue) {
            return PluginID(rawValue: lastSelectedProviderRawValue)
        }
        if let preferredProviderRawValue,
           visibleIDs.contains(preferredProviderRawValue) {
            return PluginID(rawValue: preferredProviderRawValue)
        }
        return visible.first?.id
    }

    func recordProviderSelection(_ id: PluginID) {
        lastSelectedProviderRawValue = id.rawValue
        if preferredProviderRawValue == nil {
            preferredProviderRawValue = id.rawValue
        }
    }

    private func setOptionalString(_ value: String?, forKey key: String) {
        if let value, !value.isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
