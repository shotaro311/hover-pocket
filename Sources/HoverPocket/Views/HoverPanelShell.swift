import SwiftUI

struct HoverPanelShell: View {
    let hoverState: HoverState
    @ObservedObject var store: HoverMenuStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var stickyReminders = StickyReminderController.shared
    @ObservedObject private var voiceRuntime = VoiceLaneRuntime.shared
    let onOpenSettings: () -> Void
    let onClosePanel: () -> Void
    let onExternalDragStarted: () -> Void

    var body: some View {
        let baseline = PanelLayout.panelTotalSize(for: settings.panelSize)
        let voiceHeight = VoiceLaneGeometry.height(
            panelSizeRawValue: settings.panelSize.rawValue,
            mode: voiceRuntime.snapshot.mode
        )

        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.02, green: 0.02, blue: 0.025))

            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    ProviderHeaderView(
                        providerStore: store.providerStore,
                        settings: settings,
                        onOpenSettings: onOpenSettings,
                        onClosePanel: {
                            voiceRuntime.detachPanel()
                            onClosePanel()
                        }
                    )

                    Divider()
                        .overlay(Color.white.opacity(0.08))

                    if let note = stickyReminders.activeNote {
                        StickyReminderAlertView(note: note, reminders: stickyReminders,
                            language: settings.appLanguage)
                            .id(note.id)
                    }

                    PluginHostView(
                        providerStore: store.providerStore,
                        settings: settings,
                        isPreviewActive: store.providerActive,
                        onExternalDragStarted: onExternalDragStarted,
                        onClosePanel: onClosePanel
                    )
                    .frame(maxHeight: .infinity)
                    .environment(\.panelTextSize, settings.panelTextSize)
                }
                .frame(width: baseline.width, height: baseline.height)

                VoiceLaneHostView(runtime: voiceRuntime, settings: settings)
            }
            .opacity(store.contentVisible ? 1 : 0)
            .scaleEffect(store.contentVisible ? 1 : 0.92, anchor: .top)
            .offset(y: store.contentVisible ? 0 : -14)
        }
        .frame(
            width: baseline.width,
            height: baseline.height + CGFloat(voiceHeight)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .onDisappear {
            voiceRuntime.detachPanel()
        }
        .onHover { inside in
            inside ? hoverState.onEnter() : hoverState.onExit()
        }
    }
}

private struct StickyReminderAlertView: View {
    let note: StickyNoteItem
    @ObservedObject var reminders: StickyReminderController
    let language: AppLanguage
    @State private var couldNotStop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(note.color.color)
                Text(note.displayTitle(language: language))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button(language == .japanese ? "通知を停止" : "Stop reminder") {
                    couldNotStop = !reminders.acknowledge()
                }
                .controlSize(.small)
                .accessibilityLabel(language == .japanese ? "付箋の通知を停止" : "Stop sticky note reminder")
            }
            .panelTextFont(size: 11, weight: .semibold)
            if !note.body.isEmpty {
                Text(note.body)
                    .panelTextFont(size: 10, weight: .regular)
                    .lineLimit(2)
                    .foregroundStyle(.white.opacity(0.8))
            }
            if couldNotStop {
                Text(language == .japanese
                    ? "確認状態を保存できませんでした。もう一度お試しください。"
                    : "Could not save the acknowledgement. Please try again.")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(note.color.color.opacity(0.14))
        .accessibilityElement(children: .contain)
    }
}
