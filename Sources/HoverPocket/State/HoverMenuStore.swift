import Combine

@MainActor
final class HoverMenuStore: ObservableObject {
    @Published var contentVisible = false
    @Published var providerActive = false
    let settings: AppSettings
    let providerStore: ProviderStore

    init(settings: AppSettings, providerStore: ProviderStore? = nil) {
        self.settings = settings
        self.providerStore = providerStore ?? ProviderStore(registry: .builtIn, settings: settings)
    }
}
