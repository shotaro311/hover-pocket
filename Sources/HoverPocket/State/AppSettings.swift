import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: Self.appLanguageKey)
        }
    }

    @Published var displayPlacementMode: DisplayPlacementMode {
        didSet {
            defaults.set(displayPlacementMode.rawValue, forKey: Self.displayPlacementModeKey)
        }
    }

    @Published var panelSize: PanelSizeOption {
        didSet {
            defaults.set(panelSize.rawValue, forKey: Self.panelSizeKey)
        }
    }

    @Published var panelTextSize: PanelTextSizeOption {
        didSet {
            defaults.set(panelTextSize.rawValue, forKey: Self.panelTextSizeKey)
        }
    }

    @Published var weatherLocation: WeatherLocation {
        didSet {
            if let data = try? JSONEncoder().encode(weatherLocation) {
                defaults.set(data, forKey: Self.weatherLocationKey)
            }
            if let legacyRegionID = weatherLocation.legacyRegionID {
                defaults.set(legacyRegionID, forKey: Self.weatherRegionIDKey)
            }
        }
    }

    @Published var weatherTemperatureUnit: WeatherTemperatureUnitOption {
        didSet {
            defaults.set(weatherTemperatureUnit.rawValue, forKey: Self.weatherTemperatureUnitKey)
        }
    }

    @Published var providerSwitchingMode: ProviderSwitchingMode {
        didSet {
            defaults.set(providerSwitchingMode.rawValue, forKey: Self.providerSwitchingModeKey)
        }
    }

    @Published var pillHandleIconStyle: PillHandleIconStyle {
        didSet {
            defaults.set(pillHandleIconStyle.rawValue, forKey: Self.pillHandleIconStyleKey)
        }
    }

    @Published var showNotchSideHandleArea: Bool {
        didSet {
            defaults.set(showNotchSideHandleArea, forKey: Self.showNotchSideHandleAreaKey)
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

    @Published var showMirrorOnSecondaryDisplays: Bool {
        didSet {
            defaults.set(showMirrorOnSecondaryDisplays, forKey: Self.showMirrorOnSecondaryDisplaysKey)
        }
    }

    @Published var showStickyNoteUndoToast: Bool {
        didSet {
            defaults.set(showStickyNoteUndoToast, forKey: Self.showStickyNoteUndoToastKey)
        }
    }

    @Published var stickyNoteGridSize: StickyNoteGridSize {
        didSet {
            defaults.set(stickyNoteGridSize.rawValue, forKey: Self.stickyNoteGridSizeKey)
        }
    }

    @Published var aiNativeEnabled: Bool {
        didSet {
            defaults.set(aiNativeEnabled, forKey: Self.aiNativeEnabledKey)
        }
    }

    @Published var capabilityDataRetentionPeriod: CapabilityDataRetentionPeriod {
        didSet {
            defaults.set(capabilityDataRetentionPeriod.rawValue, forKey: Self.capabilityDataRetentionPeriodKey)
        }
    }

    @Published var voiceEnabled: Bool {
        didSet {
            defaults.set(voiceEnabled, forKey: Self.voiceEnabledKey)
        }
    }

    @Published var voiceLaneLayoutPreference: VoiceLaneLayoutPreference {
        didSet {
            defaults.set(voiceLaneLayoutPreference.rawValue, forKey: Self.voiceLaneLayoutPreferenceKey)
        }
    }

    private let defaults: UserDefaults
    private static let appLanguageKey = "appLanguage"
    private static let displayPlacementModeKey = "displayPlacementMode"
    private static let panelSizeKey = "panelSize"
    private static let panelTextSizeKey = "panelTextSize"
    private static let weatherLocationKey = "weatherLocation"
    private static let weatherRegionIDKey = "weatherRegionID"
    private static let weatherTemperatureUnitKey = "weatherTemperatureUnit"
    private static let providerSwitchingModeKey = "providerSwitchingMode"
    private static let pillHandleIconStyleKey = "pillHandleIconStyle"
    private static let showNotchSideHandleAreaKey = "showNotchSideHandleArea"
    private static let providerOrderKey = "providerOrder"
    private static let hiddenProvidersKey = "hiddenProviders"
    private static let rememberLastSelectedProviderKey = "rememberLastSelectedProvider"
    private static let preferredProviderKey = "preferredProvider"
    private static let lastSelectedProviderKey = "lastSelectedProvider"
    private static let showMirrorMicrophoneCheckKey = "showMirrorMicrophoneCheck"
    private static let showMirrorOnSecondaryDisplaysKey = "showMirrorOnSecondaryDisplays"
    private static let showStickyNoteUndoToastKey = "showStickyNoteUndoToast"
    private static let stickyNoteGridSizeKey = "stickyNoteGridSize"
    private static let aiNativeEnabledKey = "aiNativeEnabled"
    private static let capabilityDataRetentionPeriodKey = "capabilityDataRetentionPeriod"
    private static let voiceEnabledKey = "voiceEnabled"
    private static let voiceLaneLayoutPreferenceKey = "voiceLaneLayoutPreference"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let languageRawValue = defaults.string(forKey: Self.appLanguageKey)
        self.appLanguage = languageRawValue.flatMap(AppLanguage.init(rawValue:)) ?? .japanese
        let rawValue = defaults.string(forKey: Self.displayPlacementModeKey)
        self.displayPlacementMode = rawValue.flatMap(DisplayPlacementMode.init(rawValue:)) ?? .mainDisplay
        let panelSizeRawValue = defaults.string(forKey: Self.panelSizeKey)
        self.panelSize = panelSizeRawValue.flatMap(PanelSizeOption.init(rawValue:)) ?? .medium
        let panelTextSizeRawValue = defaults.string(forKey: Self.panelTextSizeKey)
        self.panelTextSize = panelTextSizeRawValue.flatMap(PanelTextSizeOption.init(rawValue:)) ?? .small
        if let weatherLocationData = defaults.data(forKey: Self.weatherLocationKey),
           let weatherLocation = try? JSONDecoder().decode(
               WeatherLocation.self,
               from: weatherLocationData
           ) {
            self.weatherLocation = weatherLocation
        } else {
            let weatherRegionID = defaults.string(forKey: Self.weatherRegionIDKey)
            let weatherRegion = weatherRegionID.flatMap(WeatherRegion.region(id:))
                ?? .defaultRegion
            self.weatherLocation = WeatherLocation.from(region: weatherRegion)
        }
        let weatherTemperatureUnitRawValue = defaults.string(
            forKey: Self.weatherTemperatureUnitKey
        )
        self.weatherTemperatureUnit = weatherTemperatureUnitRawValue
            .flatMap(WeatherTemperatureUnitOption.init(rawValue:)) ?? .automatic
        let providerSwitchingModeRawValue = defaults.string(forKey: Self.providerSwitchingModeKey)
        self.providerSwitchingMode = providerSwitchingModeRawValue.flatMap(ProviderSwitchingMode.init(rawValue:)) ?? .click
        let pillHandleIconStyleRawValue = defaults.string(forKey: Self.pillHandleIconStyleKey)
        self.pillHandleIconStyle = pillHandleIconStyleRawValue.flatMap(PillHandleIconStyle.init(rawValue:)) ?? .chevron
        if defaults.object(forKey: Self.showNotchSideHandleAreaKey) == nil {
            self.showNotchSideHandleArea = true
        } else {
            self.showNotchSideHandleArea = defaults.bool(forKey: Self.showNotchSideHandleAreaKey)
        }
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
        if defaults.object(forKey: Self.showMirrorOnSecondaryDisplaysKey) == nil {
            self.showMirrorOnSecondaryDisplays = false
        } else {
            self.showMirrorOnSecondaryDisplays = defaults.bool(forKey: Self.showMirrorOnSecondaryDisplaysKey)
        }
        if defaults.object(forKey: Self.showStickyNoteUndoToastKey) == nil {
            self.showStickyNoteUndoToast = true
        } else {
            self.showStickyNoteUndoToast = defaults.bool(forKey: Self.showStickyNoteUndoToastKey)
        }
        let stickyNoteGridSizeRawValue = defaults.string(forKey: Self.stickyNoteGridSizeKey)
        self.stickyNoteGridSize = stickyNoteGridSizeRawValue.flatMap(StickyNoteGridSize.init(rawValue:)) ?? .medium
        self.aiNativeEnabled = defaults.object(forKey: Self.aiNativeEnabledKey) == nil
            ? false
            : defaults.bool(forKey: Self.aiNativeEnabledKey)
        self.capabilityDataRetentionPeriod = defaults.string(forKey: Self.capabilityDataRetentionPeriodKey)
            .flatMap(CapabilityDataRetentionPeriod.init(rawValue:)) ?? .ninetyDays
        self.voiceEnabled = defaults.object(forKey: Self.voiceEnabledKey) == nil
            ? false
            : defaults.bool(forKey: Self.voiceEnabledKey)
        self.voiceLaneLayoutPreference = defaults.string(forKey: Self.voiceLaneLayoutPreferenceKey)
            .flatMap(VoiceLaneLayoutPreference.init(rawValue:)) ?? .compact

        if defaults.data(forKey: Self.weatherLocationKey) == nil,
           let weatherLocationData = try? JSONEncoder().encode(weatherLocation) {
            defaults.set(weatherLocationData, forKey: Self.weatherLocationKey)
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

    var savedGeneratedProviderIDs: Set<String> {
        var configured = Set(providerOrderRawValues).union(hiddenProviderRawValues)
        if let preferredProviderRawValue {
            configured.insert(preferredProviderRawValue)
        }
        if let lastSelectedProviderRawValue {
            configured.insert(lastSelectedProviderRawValue)
        }
        return Set(configured.compactMap { providerID in
            guard let appID = PocketSurfaceRegistry.generatedAppID(providerID: providerID) else {
                return nil
            }
            return PocketSurfaceRegistry.generatedProviderID(appID: appID)
        })
    }

    func setProvider(
        _ id: PluginID,
        isVisible: Bool,
        manifests: [PluginManifest],
        preservingProviderIDs: Set<String> = []
    ) {
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
        let validSelectionIDs = visibleIDs.union(preservingProviderIDs)
        if let preferredProviderRawValue, !validSelectionIDs.contains(preferredProviderRawValue) {
            self.preferredProviderRawValue = visibleIDs.first
        }
        if let lastSelectedProviderRawValue, !validSelectionIDs.contains(lastSelectedProviderRawValue) {
            self.lastSelectedProviderRawValue = visibleIDs.first
        }
    }

    func moveProvider(
        _ id: PluginID,
        by offset: Int,
        manifests: [PluginManifest],
        preservingProviderIDs: Set<String> = []
    ) {
        let visibleIDs = visibleManifests(manifests).map(\.id.rawValue)
        guard let index = visibleIDs.firstIndex(of: id.rawValue) else { return }
        let destination = min(max(index + offset, 0), visibleIDs.count - 1)
        guard destination != index else { return }

        let targetID = visibleIDs[destination]
        var orderedIDs = orderedProviderIDs(
            manifests,
            preservingProviderIDs: preservingProviderIDs
        )
        orderedIDs.removeAll { $0 == id.rawValue }
        guard let targetIndex = orderedIDs.firstIndex(of: targetID) else { return }
        let insertionIndex = offset > 0 ? targetIndex + 1 : targetIndex
        orderedIDs.insert(id.rawValue, at: insertionIndex)
        providerOrderRawValues = orderedIDs
    }

    func moveProvider(
        _ id: PluginID,
        to targetID: PluginID,
        manifests: [PluginManifest],
        preservingProviderIDs: Set<String> = []
    ) {
        guard id != targetID else { return }
        let visibleIDs = visibleManifests(manifests).map(\.id.rawValue)
        guard let sourceIndex = visibleIDs.firstIndex(of: id.rawValue),
              let targetIndex = visibleIDs.firstIndex(of: targetID.rawValue) else { return }

        var orderedIDs = orderedProviderIDs(
            manifests,
            preservingProviderIDs: preservingProviderIDs
        )
        orderedIDs.removeAll { $0 == id.rawValue }
        guard let adjustedTargetIndex = orderedIDs.firstIndex(of: targetID.rawValue) else { return }
        let insertionIndex = sourceIndex < targetIndex ? adjustedTargetIndex + 1 : adjustedTargetIndex
        orderedIDs.insert(id.rawValue, at: min(insertionIndex, orderedIDs.count))
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

    func pruneProviderConfiguration(_ id: PluginID) {
        providerOrderRawValues.removeAll { $0 == id.rawValue }
        hiddenProviderRawValues.remove(id.rawValue)
        if preferredProviderRawValue == id.rawValue {
            preferredProviderRawValue = nil
        }
        if lastSelectedProviderRawValue == id.rawValue {
            lastSelectedProviderRawValue = nil
        }
    }

    private func orderedProviderIDs(
        _ manifests: [PluginManifest],
        preservingProviderIDs: Set<String>
    ) -> [String] {
        let availableIDs = Set(manifests.map(\.id.rawValue))
        let retainedIDs = availableIDs.union(preservingProviderIDs)
        var seen = Set<String>()
        let retainedOrder = providerOrderRawValues.filter {
            retainedIDs.contains($0) && seen.insert($0).inserted
        }
        return retainedOrder + manifests.map(\.id.rawValue).filter { seen.insert($0).inserted }
    }

    private func setOptionalString(_ value: String?, forKey key: String) {
        if let value, !value.isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
