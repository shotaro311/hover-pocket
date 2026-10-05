import Combine

@MainActor
final class HoverMenuStore: ObservableObject {
    @Published var providerActive = false
    @Published var attachmentMetrics = PanelAttachmentMetrics(headerHeight: 0, notchWidth: 0)
    let settings: AppSettings
    let providerStore: ProviderStore

    var effectivePanelAttachmentStyle: PanelAttachmentStyle {
        settings.resolvedPanelAttachmentStyle(hasNotch: attachmentMetrics.notchWidth > 0)
    }

    init(settings: AppSettings, providerStore: ProviderStore? = nil) {
        self.settings = settings
        self.providerStore = providerStore ?? ProviderStore(registry: .builtIn, settings: settings)
    }
}
