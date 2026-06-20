import SwiftUI
import UniformTypeIdentifiers

struct ProviderHeaderView: View {
    @ObservedObject var providerStore: ProviderStore
    @ObservedObject var settings: AppSettings
    @ObservedObject private var appUpdater = AppUpdater.shared
    let onOpenSettings: () -> Void
    @State private var draggingPluginID: PluginID?

    var body: some View {
        HStack(spacing: 10) {
            titleArea

            Spacer()

            if providerStore.visibleManifests.count > 1 {
                providerButtons

                HeaderIconDivider()
            }

            if appUpdater.hasAvailableUpdate {
                Button {
                    appUpdater.checkForUpdates()
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.28, green: 0.58, blue: 1.0))
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(red: 0.28, green: 0.58, blue: 1.0).opacity(0.14))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(settings.text(.updateAvailable))
                .disabled(!appUpdater.canCheckForUpdates)
            }

            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle(selected: false))
            .help(settings.text(.settings))
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    private var titleArea: some View {
        HStack(spacing: 8) {
            Text(providerStore.selectedProvider?.manifest.title(language: settings.appLanguage) ?? settings.text(.noProviders))
                .contentTransition(.opacity)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)

            PanelSizeCycleButton(settings: settings)
        }
    }

    private var providerButtons: some View {
        ForEach(providerStore.visibleManifests) { manifest in
            ProviderIconButton(
                manifest: manifest,
                language: settings.appLanguage,
                isSelected: providerStore.selectedPluginID == manifest.id,
                isDragging: draggingPluginID == manifest.id,
                isDropTarget: draggingPluginID != nil && draggingPluginID != manifest.id,
                switchingMode: settings.providerSwitchingMode,
                canMoveLeft: providerStore.canMoveProvider(manifest.id, by: -1),
                canMoveRight: providerStore.canMoveProvider(manifest.id, by: 1),
                moveLeftTitle: settings.text(.moveLeft),
                moveRightTitle: settings.text(.moveRight),
                onSelect: { providerStore.select(manifest.id) },
                onMoveLeft: { providerStore.moveProvider(manifest.id, by: -1) },
                onMoveRight: { providerStore.moveProvider(manifest.id, by: 1) }
            )
            .onDrag {
                draggingPluginID = manifest.id
                let dragID = manifest.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    if draggingPluginID == dragID {
                        draggingPluginID = nil
                    }
                }
                return NSItemProvider(object: manifest.id.rawValue as NSString)
            }
            .onDrop(
                of: [UTType.text],
                delegate: ProviderIconDropDelegate(
                    targetID: manifest.id,
                    draggingPluginID: $draggingPluginID,
                    providerStore: providerStore
                )
            )
        }
        .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.86), value: providerStore.visibleManifests)
    }
}

private struct ProviderIconButton: View {
    let manifest: PluginManifest
    let language: AppLanguage
    let isSelected: Bool
    let isDragging: Bool
    let isDropTarget: Bool
    let switchingMode: ProviderSwitchingMode
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let moveLeftTitle: String
    let moveRightTitle: String
    let onSelect: () -> Void
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void

    var body: some View {
        Button {
            selectIfClickMode()
        } label: {
            Image(systemName: manifest.symbolName)
        }
        .buttonStyle(IconButtonStyle(selected: isSelected))
        .help(manifest.title(language: language))
        .opacity(isDragging ? 0.46 : 1)
        .overlay(
            Circle()
                .stroke(Color.white.opacity(isDropTarget ? 0.18 : 0), lineWidth: 1)
        )
        .onHover { inside in
            guard inside else { return }
            selectIfHoverMode()
        }
        .contextMenu {
            Button(moveLeftTitle) {
                onMoveLeft()
            }
            .disabled(!canMoveLeft)

            Button(moveRightTitle) {
                onMoveRight()
            }
            .disabled(!canMoveRight)
        }
    }

    private func selectIfClickMode() {
        guard switchingMode == .click else { return }
        onSelect()
    }

    private func selectIfHoverMode() {
        guard switchingMode == .hover else { return }
        onSelect()
    }
}

private struct ProviderIconDropDelegate: DropDelegate {
    let targetID: PluginID
    @Binding var draggingPluginID: PluginID?
    let providerStore: ProviderStore

    func dropEntered(info: DropInfo) {
        guard let draggingPluginID, draggingPluginID != targetID else { return }
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.86)) {
            providerStore.moveProvider(draggingPluginID, to: targetID)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingPluginID = nil
        return true
    }

    func dropExited(info: DropInfo) {
        guard info.hasItemsConforming(to: [UTType.text]) else { return }
    }
}

private struct HeaderIconDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 2)
    }
}

private struct PanelSizeCycleButton: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Button {
            settings.panelSize = settings.panelSize.next
        } label: {
            Text(settings.panelSize.shortTitle(language: settings.appLanguage))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
                .frame(width: 22, height: 20)
                .contentTransition(.opacity)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.16), value: settings.panelSize)
        .accessibilityLabel("\(settings.text(.panelSizeAccessibility)) \(settings.panelSize.shortTitle(language: settings.appLanguage))")
        .help("\(settings.text(.panelSizeHelp)): \(settings.panelSize.title(language: settings.appLanguage))")
    }
}
