struct ProviderRegistry: Sendable {
    let providers: [any PocketProvider]

    init(providers: [any PocketProvider] = []) {
        self.providers = providers
    }

    static let empty = ProviderRegistry()
    static let builtIn = ProviderRegistry(
        providers: [
            MirrorProvider(),
            GoogleCalendarProvider(),
            ClipboardProvider(),
            StickyNotesProvider()
        ]
    )

    var manifests: [PluginManifest] {
        providers.map(\.manifest)
    }

    func provider(for id: PluginID?) -> (any PocketProvider)? {
        guard let id else { return providers.first }
        return providers.first { $0.manifest.id == id }
    }
}
