import SwiftUI
import AppKit

struct HoverPanelShell: View {
    let hoverState: HoverState
    @ObservedObject var store: HoverMenuStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var stickyReminders = StickyReminderController.shared
    @ObservedObject private var voiceRuntime = VoiceLaneRuntime.shared
    @ObservedObject private var chat = CodexChatController.shared
    @ObservedObject private var assets = AssetLibraryRuntime.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onOpenSettings: () -> Void
    let onClosePanel: () -> Void
    let onExternalDragStarted: () -> Void

    @State private var splitStart: CGFloat?
    @State private var splitRatio: Double?
    @State private var resizeStart: CGSize?

    var body: some View {
        GeometryReader { viewport in
        let normal = PanelLayout.panelTotalSize(for: settings.panelSize)
        let voiceHeight = assets.fullscreen ? 0 : chat.panelHeight
        let custom = settings.customPanelSize.map { PanelLayout.clampManualSize($0,
            additionalHeight: CGFloat(voiceHeight) + store.attachmentMetrics.contentTop, available: viewport.size) }
        let selectedSize = assets.fullscreen ? assets.panelSize : (custom ?? assets.panelSize)
        let effectiveSize = selectedSize.map { CGSize(width: min($0.width, viewport.size.width),
            height: min(max($0.height, CGFloat(voiceHeight) + store.attachmentMetrics.contentTop + 200), viewport.size.height)) }
        let baseline = effectiveSize.map { CGSize(width: $0.width,
            height: max(200, $0.height - CGFloat(voiceHeight) - store.attachmentMetrics.contentTop)) } ?? normal

        let contentHeight = baseline.height + CGFloat(voiceHeight)
        let chatHeight = assets.fullscreen ? 0 : min(max(CodexChatPanelLayout.composerHeight, contentHeight * CGFloat(splitRatio ?? settings.chatSplitRatio ?? Double(CGFloat(voiceHeight) / max(1, contentHeight)))), max(CodexChatPanelLayout.composerHeight, contentHeight - 180))
        Group {
            VStack(spacing: 0) {
                ZStack {
                    if store.effectivePanelAttachmentStyle == .coverMenu && store.providerActive {
                        PanelTopBarView(providerStore: store.providerStore, settings: settings,
                                        metrics: store.attachmentMetrics)
                            .transition(.opacity)
                    }
                }
                .frame(height: store.attachmentMetrics.headerHeight)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: store.effectivePanelAttachmentStyle)

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
                .frame(width: baseline.width, height: contentHeight - chatHeight)

                if !assets.fullscreen {
                    VoiceLaneHostView(runtime: voiceRuntime, settings: settings, height: chatHeight, onOpenSettings: onOpenSettings)
                        .overlay(alignment: .top) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.6))
                                .frame(width: 40, height: 2).frame(maxWidth: .infinity).frame(height: 8)
                                .contentShape(Rectangle()).offset(y: -4)
                                .help(settings.appLanguage == .japanese ? "ドラッグして素材とチャットの高さを調整" : "Drag to resize tools and chat")
                                .accessibilityLabel("Resize tools and chat")
                                .accessibilityIdentifier("chat-splitter")
                                .accessibilityAdjustableAction { direction in
                                    let delta = direction == .increment ? 0.03 : -0.03
                                    settings.chatSplitRatio = min(0.9, max(0.1, Double(chatHeight / contentHeight) + delta))
                                }
                                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                    .onChanged { value in
                                        if splitStart == nil { splitStart = chatHeight; settings.panelResizing = true }
                                        splitRatio = min(0.9, max(0.1, Double(((splitStart ?? chatHeight) - value.translation.height) / contentHeight)))
                                    }
                                    .onEnded { _ in
                                        if let splitRatio { settings.chatSplitRatio = splitRatio }
                                        splitStart = nil; splitRatio = nil; settings.panelResizing = false
                                    })
                        }
                }
            }
        }
        .frame(
            width: baseline.width,
            height: baseline.height + CGFloat(voiceHeight) + store.attachmentMetrics.contentTop
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottomTrailing) {
            if !assets.fullscreen {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11)).rotationEffect(.degrees(-45))
                    .foregroundStyle(.secondary).frame(width: 22, height: 22).contentShape(Rectangle())
                    .help(settings.appLanguage == .japanese ? "ドラッグしてサイズを変更" : "Drag to resize")
                    .accessibilityLabel(settings.appLanguage == .japanese ? "パネルのサイズを変更" : "Resize panel")
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            if resizeStart == nil {
                                resizeStart = CGSize(width: baseline.width, height: baseline.height + CGFloat(voiceHeight) + store.attachmentMetrics.contentTop)
                                settings.panelResizing = true
                            }
                            guard let start = resizeStart else { return }
                            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
                            let work = screen?.visibleFrame.size
                            settings.customPanelSize = PanelLayout.clampManualSize(
                                CGSize(width: start.width + value.translation.width * 2, height: start.height + value.translation.height),
                                additionalHeight: CGFloat(voiceHeight) + store.attachmentMetrics.contentTop, available: work)
                        }.onEnded { _ in
                            settings.panelResizing = false; settings.persistPanelSize(); resizeStart = nil
                            hoverState.onExit()
                        })
                    .padding(3)
            }
        }
        .onDisappear {
            if splitStart != nil || resizeStart != nil { settings.panelResizing = false; splitStart = nil; splitRatio = nil; resizeStart = nil }
            voiceRuntime.detachPanel()
        }
        .onHover { inside in
            inside ? hoverState.onEnter() : hoverState.onExit()
        }
        }
    }
}

private struct StickyReminderAlertView: View {
    let note: StickyNoteItem
    @ObservedObject var reminders: StickyReminderController
    let language: AppLanguage
    @State private var couldNotStop = false

    @State private var splitStart: CGFloat?
    @State private var resizeStart: CGSize?

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
