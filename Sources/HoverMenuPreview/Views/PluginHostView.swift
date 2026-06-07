import SwiftUI

struct PluginHostView: View {
    @ObservedObject var providerStore: ProviderStore
    let isPreviewActive: Bool
    let onExternalDragStarted: () -> Void

    var body: some View {
        Group {
            if let provider = providerStore.selectedProvider {
                let id = provider.manifest.id
                provider.makePreview(
                    snapshot: providerStore.snapshot(for: id),
                    state: providerStore.state(for: id),
                    actions: ProviderActions(
                        isPreviewActive: isPreviewActive,
                        refresh: {
                            providerStore.refreshSelected(reason: .userRequested)
                        },
                        beginExternalDrag: {
                            onExternalDragStarted()
                        }
                    )
                )
            } else {
                EmptyProviderView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyProviderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.32))

            Text("No providers")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))

            Text("Provider registry is ready.")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.38))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
