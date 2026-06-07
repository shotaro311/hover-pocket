struct ProviderRegistry: Sendable {
    let providers: [any NotchProvider]

    init(providers: [any NotchProvider] = []) {
        self.providers = providers
    }

    static let empty = ProviderRegistry()
    static let builtIn = ProviderRegistry(
        providers: [
            MirrorProvider(),
            GoogleCalendarProvider(),
            ClipboardProvider()
        ]
    )

    var manifests: [PluginManifest] {
        providers.map(\.manifest)
    }

    func provider(for id: PluginID?) -> (any NotchProvider)? {
        guard let id else { return providers.first }
        return providers.first { $0.manifest.id == id }
    }
}
