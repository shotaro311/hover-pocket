import Combine

@MainActor
final class HoverMenuStore: ObservableObject {
    @Published var contentVisible = false
    let settings: AppSettings
    let providerStore: ProviderStore

    init(settings: AppSettings, providerStore: ProviderStore = ProviderStore()) {
        self.settings = settings
        self.providerStore = providerStore
    }
}
