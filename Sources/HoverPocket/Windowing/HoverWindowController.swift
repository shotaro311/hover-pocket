import AppKit
import AVFoundation
import Combine
import OSLog
import QuartzCore
import SwiftUI

private final class HoverMenuPanel: NSPanel {
    var acceptsKeyboardFocus = false

    override var canBecomeKey: Bool {
        acceptsKeyboardFocus
    }

    override var canBecomeMain: Bool {
        acceptsKeyboardFocus
    }
}

@MainActor
final class HoverWindowController {
    private var accessWindows: [String: NSPanel] = [:]
    private var accessWindowStyles: [String: PanelAccessStyle] = [:]
    private var previewWindow: NSPanel?
    private var previewHost: NSHostingController<HoverPanelShell>?
    private var liquidSurface: LiquidPanelSurfaceView?
    private let liquidAnimator = LiquidPanelAnimator()
    private var previewIsClosing = false
    private var awaitingPointerAfterExplicitOpen = false
    private var activePreviewScreen: NSScreen?
    private var closeTask: DispatchWorkItem?
    private var resetTask: DispatchWorkItem?
    private var hoverMonitorTimer: Timer?
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var accessMonitorTimer: Timer?
    private var mouseEventsEnableTask: DispatchWorkItem?
    private var systemRecoveryTasks: [DispatchWorkItem] = []
    private var lastAccessWindowHealthCheck = Date.distantPast
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var previewAnimationToken = 0
    private let usesDirectHoverEvents = !CommandLine.arguments.contains("--verify-hover-recovery")
    private let isPanelSoakVerification = CommandLine.arguments.contains(
        "--verify-panel-soak"
    ) || CommandLine.arguments.contains("--verify-liquid-motion") || CommandLine.arguments.contains("--verify-asset-ui")
    private var panelSoakUsesImmediateTransitions = true
    private let logger = Logger(subsystem: "com.hoverpocket.app", category: "HoverWindowRecovery")
    private let stickyReminders: StickyReminderController
    private let settings: AppSettings
    private let menuStore: HoverMenuStore
    private let settingsWindowController: SettingsWindowController
    private var settingsCancellables = Set<AnyCancellable>()

    var appSettings: AppSettings {
        settings
    }

    init(
        settingsDefaults: any AppSettingsDefaultsStoring = HoverPocketRuntimeEnvironment.shared.settingsDefaults,
        providerRegistry: ProviderRegistry? = nil,
        stickyReminders: StickyReminderController = .shared
    ) {
        self.stickyReminders = stickyReminders
        let settings = AppSettings(defaults: settingsDefaults)
        HoverPocketRuntimeEnvironment.shared.applyVoiceE2EDefaults(to: settings)
        let providerStore = ProviderStore(
            registry: providerRegistry ?? HoverPocketRuntimeEnvironment.shared.providerRegistry,
            settings: settings
        )
        let menuStore = HoverMenuStore(settings: settings, providerStore: providerStore)
        self.settings = settings
        self.menuStore = menuStore
        self.settingsWindowController = SettingsWindowController(
            settings: settings,
            providerStore: menuStore.providerStore
        )

        syncAccessWindows(orderFront: false)
        configurePreviewWindow()
        settingsWindowController.onOpenProvider = { [weak self] in self?.openPanel(showing: $0) }
        observeSettings()
        observeTimerAlerts()
        observeStickyReminders()
    }

    func showPill() {
        syncAccessWindows(orderFront: true)
        startAccessMonitor()
    }

    func ensureAccessWindowsAvailable() {
        startAccessMonitor()
        repairAccessWindowsIfNeeded()
    }

    func recoverAfterSystemTransition() {
        systemRecoveryTasks.forEach { $0.cancel() }
        systemRecoveryTasks.removeAll()

        for delay in [0.0, 0.45, 1.4] {
            let task = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.performSystemRecovery()
                }
            }
            systemRecoveryTasks.append(task)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
        }
    }

    func positionWindows() {
        syncAccessWindows(orderFront: false)
        guard let screen = activePreviewScreen ?? screenSelection.target else { return }

        applyResolvedVoiceLaneLayout(on: screen)
        let frames = panelFrames(on: screen)

        guard let previewWindow else { return }
        previewAnimationToken += 1
        resetTask?.cancel()
        resetTask = nil
        let visible = previewWindow.isVisible && !previewIsClosing
        if previewIsClosing { resetClosedPreviewWindow(previewWindow, frame: frames.preview) }
        configureSurfaceFrame(frames.preview, originWidth: frames.surfaceOriginWidth, progress: visible ? 1 : 0)
        if visible { finishPreviewOpen(token: previewAnimationToken) }
    }

    func openPanelFromMenu() {
        showPreview(on: screenSelection.target)
        awaitingPointerAfterExplicitOpen = true
    }

    /// Opens the panel and switches to the given provider. `select` must run
    /// after `showPreview` because panel opening restores the settings-based
    /// provider selection.
    func openPanel(showing pluginID: PluginID) {
        showPreview(on: screenSelection.target)
        menuStore.providerStore.select(pluginID)
        awaitingPointerAfterExplicitOpen = true
    }

    func connectAppController() {
        let chat = CodexChatController.shared
        chat.configure(settings: settings)
        chat.openPanel = { [weak self] in
            guard let self else { return }
            if self.previewWindow?.isVisible != true { self.openPanelFromMenu() }
            else { self.cancelClose(); self.awaitingPointerAfterExplicitOpen = true }
        }
        chat.closePanel = { [weak self] in self?.closePreview() }
        let assets = AssetLibraryRuntime.shared
        assets.onLayout = { [weak self] in self?.resizePreviewForPanelSizeChange() }
        assets.baselineSize = { [weak self] in PanelLayout.panelTotalSize(for: self?.settings.panelSize ?? .medium) }
        assets.closePanel = { [weak self] in self?.closePreview() }
        assets.openPanel = { [weak self] in self?.openPanel(showing: AssetsProvider.pluginID) }
        assets.canAcceptDrop = { [weak self] in self?.menuStore.providerStore.visibleManifests.contains { $0.id == AssetsProvider.pluginID } == true }
        assets.openForDrop = { [weak self] in
            guard let self, assets.canAcceptDrop?() == true, assets.holdCount == 0, assets.editing == nil else { return }
            assets.incomingDrag = true; assets.dropReceived = false
            self.showPreview(on: NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) })
            self.menuStore.providerStore.selectTemporaryAssets()
        }
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                guard let self, self.menuStore.providerStore.selectedPluginID == AssetsProvider.pluginID else { return }
                assets.textInput = false
                if !assets.holdsPanel && !CodexChatController.shared.holdsPanel { self.closePreview() }
            }.store(in: &settingsCancellables)
        menuStore.providerStore.$selectedPluginID.dropFirst().sink { id in
            if id != AssetsProvider.pluginID { assets.endPreview(); assets.onLayout?() }
        }.store(in: &settingsCancellables)
        let controller = PocketAppOSController.shared
        controller.providerStore = menuStore.providerStore
        controller.actionConfirmationEnabled = { [weak self] in self?.settings.voiceActionConfirmationEnabled ?? true }
        controller.destructiveConfirmationEnabled = { [weak self] in self?.settings.voiceDestructiveConfirmationEnabled ?? true }
        controller.readWeather = { [weak self] in
            guard let self, HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled else {
                throw WeatherForecastServiceError.invalidRequest
            }
            return try await WeatherVoiceReader.read(store: .shared, location: self.settings.weatherLocation,
                temperatureUnit: self.settings.weatherTemperatureUnit)
        }
        controller.calendarAccessGranted = { [weak self] in self?.settings.voiceCalendarAccessEnabled == true }
        PocketCodexLibrary.host.preferredVoice = { [weak self] in self?.settings.codexVoiceSelection ?? "" }
        controller.notifySession = { session, text in
            await PocketCodexLibrary.host.appendHostNotice(sessionID: session, text: text)
        }
        controller.openScreen = { [weak self] id in
            guard let self else { return false }
            self.openPanel(showing: id)
            return self.previewWindow?.isVisible == true && self.menuStore.providerStore.selectedPluginID == id
        }
        controller.openTools = { [weak self] in
            self?.menuStore.providerStore.objectWillChange.send()
            self?.openPanel(showing: PocketDraftProvider.pluginID)
        }
    }

    func openSettingsFromMenu() {
        showSettings()
    }

    func runAssetPanelVerification(evidence: URL) async throws {
        guard CommandLine.arguments.contains("--verify-asset-ui"), let screen = NSScreen.main, let previewWindow else { throw LibraryError.message("asset panel verification precondition") }
        let runtime = AssetLibraryRuntime.shared
        connectAppController()
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw LibraryError.message("FAIL " + message) }
        }
        func settle() async throws {
            let deadline = Date().addingTimeInterval(2)
            while !liquidAnimator.isIdle, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try check(liquidAnimator.isIdle, "asset panel animation settled")
        }
        defer {
            runtime.endPreview(); runtime.incomingDrag = false
            runtime.onLayout = nil; runtime.openPanel = nil; runtime.closePanel = nil; runtime.openForDrop = nil; runtime.canAcceptDrop = nil
            orderOutPreviewWindow(previewWindow); accessWindows.values.forEach { $0.orderOut(nil) }; stopHoverMonitor()
        }
        menuStore.providerStore.select(TimerProvider.pluginID)
        let previous = settings.lastSelectedProviderRawValue
        showPreview(on: screen); menuStore.providerStore.selectTemporaryAssets()
        try check(settings.lastSelectedProviderRawValue == previous, "temporary drop provider leaves preference unchanged")
        menuStore.providerStore.restoreTemporarySelection()
        try check(menuStore.providerStore.selectedPluginID == TimerProvider.pluginID, "cancelled drop restores previous provider")
        closePreview()
        panelSoakUsesImmediateTransitions = false
        for index in 0..<20 {
            showPreview(on: screen); menuStore.providerStore.selectTemporaryAssets(); awaitingPointerAfterExplicitOpen = true
            try await settle()
            runtime.setLayout(media: CGSize(width: index % 2 == 0 ? 360 : 3840, height: 2160), fullscreen: false, screen: screen, baseline: PanelLayout.panelTotalSize(for: settings.panelSize))
            try await settle()
            try check(previewWindow.frame.width <= screen.visibleFrame.width * 0.9 + 1 && previewWindow.frame.height <= screen.visibleFrame.height * 0.85 + 1, "asset preview stays within display bounds")
            if index == 0 {
                func assetWeb(in view: NSView?) -> AssetNativeWebView? {
                    guard let view else { return nil }
                    if let web = view as? AssetNativeWebView { return web }
                    return view.subviews.lazy.compactMap { assetWeb(in: $0) }.first
                }
                try await Task.sleep(for: .milliseconds(600))
                guard let web = assetWeb(in: previewWindow.contentView) else { throw LibraryError.message("asset panel web view missing") }
                let store = try await runtime.store()
                let id = try await store.query(LibraryQuery()).items.first { $0.kind == "image" }!.id
                _ = try await web.callAsyncJavaScript("await window.assetPane.refresh();document.querySelector('[data-asset-id=\"'+id+'\"] img').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));", arguments: ["id": id], in: nil, contentWorld: .page)
                try await Task.sleep(for: .milliseconds(400)); try await settle()
                try check(try await web.evaluateJavaScript("document.querySelector('.assets-root').classList.contains('has-preview')") as? Bool == true, "image preview uses the notch panel")
                try await AssetMediaVerification.snapshot(window: previewWindow, to: evidence.appendingPathComponent("notch-expanded.png"))
                runtime.setLayout(media: CGSize(width: 1920, height: 1080), fullscreen: true, screen: screen, baseline: .zero)
                try await settle()
                try check(previewWindow.frame == screen.frame, "notch fullscreen uses original display")
                positionWindows(); try check(previewWindow.frame == screen.frame, "screen recovery preserves asset fullscreen")
            }
            closePreview(); try await settle()
            try check(!previewWindow.isVisible && runtime.panelSize == nil && !runtime.fullscreen && menuStore.providerStore.selectedPluginID == TimerProvider.pluginID, "asset close restores size and provider")
        }
        panelSoakUsesImmediateTransitions = true
        try Data("20 animated cycles; bounds; fullscreen; recovery; temporary provider\n".utf8).write(to: evidence.appendingPathComponent("panel-result.txt"))
    }

    func runLiquidMotionVerification(evidenceDirectory: URL) async throws {
        guard isPanelSoakVerification, let previewWindow, let surface = liquidSurface else {
            throw PanelSoakVerificationError.failed("liquid_verifier_precondition")
        }
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        panelSoakUsesImmediateTransitions = false
        defer { panelSoakUsesImmediateTransitions = true }

        func check(_ condition: Bool, _ code: String) throws {
            guard condition else { throw PanelSoakVerificationError.failed("liquid_runtime_" + code) }
        }
        func capture(_ name: String) throws {
            guard let rep = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else {
                throw PanelSoakVerificationError.failed("liquid_capture_rep")
            }
            surface.cacheDisplay(in: surface.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                throw PanelSoakVerificationError.failed("liquid_capture_png")
            }
            try data.write(to: evidenceDirectory.appendingPathComponent(name + ".png"))
        }
        func open(on screen: NSScreen?) {
            showPreview(on: screen)
            awaitingPointerAfterExplicitOpen = true
        }
        func awaitIdle() async throws {
            let deadline = Date().addingTimeInterval(2)
            repeat { await settlePanelSoakRunLoop(milliseconds: 10) }
            while !liquidAnimator.isIdle && Date() < deadline
            try check(liquidAnimator.isIdle, "display_link_timeout")
        }
        for style in PanelAttachmentStyle.allCases {
            settings.panelAttachmentStyle = style
            for (index, screen) in NSScreen.screens.enumerated() {
                try check(previewWindow.animationBehavior == .none
                          && accessWindows.values.allSatisfy { $0.animationBehavior == .none }, "native_ordering_animation_disabled")
                settings.panelSize = .medium
                func openAtOrigin() {
                    open(on: screen)
                    liquidAnimator.snap(progress: 0, frame: panelFrames(on: screen).preview)
                }
                func animateFromOrigin() async throws {
                    // Hold the initial shape only in the capture test so it appears in recorded frames.
                    await settlePanelSoakRunLoop(milliseconds: 60)
                    liquidAnimator.setReveal(1)
                    try await awaitIdle()
                }
                if style == .coverMenu && index == 0 && CGPreflightScreenCaptureAccess() {
                    previewWindow.animationBehavior = .default
                    defer { previewWindow.animationBehavior = .none }
                    try await LiquidScreenEdgeVerification.run(screen: screen, frame: panelFrames(on: screen).preview,
                        attachment: panelFrames(on: screen).attachment, style: style, evidenceDirectory: evidenceDirectory,
                        expectsDisplacement: true, open: { openAtOrigin() }, settle: { try await animateFromOrigin() },
                        close: { previewWindow.animationBehavior = .none; closePreview(); try await awaitIdle() })
                }
                try await LiquidScreenEdgeVerification.run(screen: screen, frame: panelFrames(on: screen).preview,
                    attachment: panelFrames(on: screen).attachment, style: style, evidenceDirectory: evidenceDirectory,
                    open: { openAtOrigin() }, settle: { try await animateFromOrigin() },
                    close: { closePreview(); try await awaitIdle() })
                open(on: screen)
                let frame = panelFrames(on: screen).preview
                await settlePanelSoakRunLoop(milliseconds: 50)
                try check(previewWindow.frame == frame, "opening_fixed_window")
                let metrics = panelFrames(on: screen).attachment
                try check(surface.currentShape.rect.height < frame.height, "opening_height")
                if style == .preserveMenu {
                    try check(surface.currentShape.rect.minY == metrics.contentTop
                              && surface.currentShape.fillOpacity == 1
                              && surface.currentShape.path.boundingBoxOfPath.minY >= metrics.preservedNeckTop
                              && surface.currentShape.path.boundingBoxOfPath.minY <= metrics.contentTop
                              && surface.currentShape.joinRadius > 0,
                              "opening_compact_liquid_join")
                } else {
                    try check(surface.currentShape.path.boundingBoxOfPath.minY == 0
                              && surface.currentShape.rect.minY <= metrics.contentTop
                              && surface.currentShape.contentOffset == 0, "opening_screen_top")
                }
                let neckPoint = NSPoint(x: frame.width / 2, y: surface.currentShape.rect.midY)
                try check(surface.hitTest(surface.convert(neckPoint, to: surface.superview)) === surface, "invisible_content_hit_test")
                try capture("\(style.rawValue)-display-\(index)-open-050ms")
                await settlePanelSoakRunLoop(milliseconds: 60)
                try capture("\(style.rawValue)-display-\(index)-open-110ms")
                try await awaitIdle()
                try check(surface.currentShape.contentOpacity == 1 && !previewWindow.hasShadow, "open_complete")
                try capture("\(style.rawValue)-display-\(index)-open-settled")

                for size in PanelSizeOption.allCases {
                    settings.panelSize = size
                    await settlePanelSoakRunLoop(milliseconds: 30)
                    try await awaitIdle()
                    let frames = panelFrames(on: screen)
                    let expected = frames.preview
                    let expectedBody = NSSize(width: expected.width - PanelLayout.surfaceSidePadding * 2,
                                              height: expected.height - frames.attachment.contentTop)
                    if previewWindow.frame != expected || surface.currentShape.rect.size != expectedBody {
                        print("liquid_resize_readback actual=\(previewWindow.frame) expected=\(expected) shape=\(surface.currentShape.rect) target=\(liquidAnimator.rect.target) closing=\(previewIsClosing) visible=\(previewWindow.isVisible)")
                    }
                    try check(previewWindow.frame == expected && surface.currentShape.rect.size == expectedBody, "resize_\(size.rawValue)")
                    try capture("\(style.rawValue)-display-\(index)-size-\(size.rawValue)")
                }
                let menuLocal = NSPoint(x: 20, y: panelFrames(on: screen).attachment.headerHeight / 2)
                let menuScreen = NSPoint(x: previewWindow.frame.minX + menuLocal.x,
                                         y: previewWindow.frame.maxY - menuLocal.y)
                updatePreviewMouseRouting(at: menuScreen)
                try check(previewWindow.ignoresMouseEvents == (style == .preserveMenu), "menu_mouse_routing")
                let bodyScreen = NSPoint(x: previewWindow.frame.midX, y: previewWindow.frame.minY + 100)
                updatePreviewMouseRouting(at: bodyScreen)
                try check(!previewWindow.ignoresMouseEvents, "body_mouse_routing")
                try check(accessWindows[PanelScreenSelection.key(screen)]?.isVisible == false, "access_hidden_while_open")
                // Exercise the production close decision with a stationary pointer, without explicit-open pinning.
                awaitingPointerAfterExplicitOpen = false
                let frames = panelFrames(on: screen)
                let centerX = frames.access.midX
                let notchHalfWidth = frames.attachment.notchWidth / 2
                let originPoints = [
                    NSPoint(x: centerX, y: screen.frame.maxY - 1),
                    NSPoint(x: centerX, y: screen.frame.maxY - frames.attachment.headerHeight * 0.75),
                    NSPoint(x: centerX - notchHalfWidth - 2, y: screen.frame.maxY - frames.attachment.headerHeight + 2),
                    NSPoint(x: centerX + notchHalfWidth + 2, y: screen.frame.maxY - frames.attachment.headerHeight + 2),
                    NSPoint(x: frames.access.minX + 2, y: frames.access.midY)
                ]
                let heldToken = previewAnimationToken
                for point in originPoints {
                    for _ in 0..<30 {
                        closeIfMouseLeftHoverRegion(at: point)
                        await settlePanelSoakRunLoop(milliseconds: 20)
                        try check(previewWindow.isVisible && !previewIsClosing && closeTask == nil
                                  && previewAnimationToken == heldToken, "stationary_notch_hover")
                    }
                }
                updatePreviewMouseRouting(at: originPoints[0])
                try check(previewWindow.ignoresMouseEvents == (style == .preserveMenu && frames.attachment.notchWidth > 0),
                          "notch_transparent_mouse_routing")
                let outside = NSPoint(x: screen.frame.minX + 20, y: screen.frame.minY + 20)
                closeIfMouseLeftHoverRegion(at: outside)
                try check(closeTask != nil, "hover_leave_schedules_close")
                await settlePanelSoakRunLoop(milliseconds: 20)
                closeIfMouseLeftHoverRegion(at: originPoints[0])
                await settlePanelSoakRunLoop(milliseconds: 100)
                try check(previewWindow.isVisible && !previewIsClosing && closeTask == nil
                          && previewAnimationToken == heldToken, "hover_reentry_cancels_close")
                if let other = NSScreen.screens.first(where: { !PanelScreenSelection.isSameDisplay($0, screen) }) {
                    let otherAccess = panelFrames(on: other).access
                    try check(!isMouseInsideHoverRegion(at: NSPoint(x: otherAccess.midX, y: otherAccess.midY)),
                              "other_display_does_not_hold_panel")
                }
                closeIfMouseLeftHoverRegion(at: outside)
                await settlePanelSoakRunLoop(milliseconds: 100)
                try await awaitIdle()
                try check(!previewWindow.isVisible && accessWindows[PanelScreenSelection.key(screen)]?.isVisible == true,
                          "hover_leave_auto_closes")
                open(on: screen)
                try await awaitIdle()
                try check(previewWindow.isVisible && !previewIsClosing, "hover_reopens_after_leave")
                print("liquid_notch_hover=ok style=\(style.rawValue) display=\(index) held_points=\(originPoints.count) checks=150 held_ms_per_point=600 reentry_cancel=ok auto_close=ok notch_click_routing=ok other_display=\(NSScreen.screens.count > 1 ? "ok" : "skipped_single_display")")
                closePreview()
                await settlePanelSoakRunLoop(milliseconds: 60)
                try capture("\(style.rawValue)-display-\(index)-close-060ms")
                try await awaitIdle()
                try check(!previewWindow.isVisible && globalPointerMonitor == nil && localPointerMonitor == nil, "close_complete")
                try check(accessWindows[PanelScreenSelection.key(screen)]?.isVisible == true, "access_restored")
                print("liquid_display_\(index)=ok style=\(style.rawValue) sizes=4 origin=\(panelFrames(on: screen).surfaceOriginWidth) header=\(panelFrames(on: screen).attachment.headerHeight)")
            }
        }
        open(on: screenSelection.target)
        try await awaitIdle()
        let unchangedFrame = previewWindow.frame
        for _ in 0..<5 {
            for style in PanelAttachmentStyle.allCases {
                let value = liquidAnimator.attachmentReveal.value
                let velocity = liquidAnimator.attachmentReveal.velocity
                settings.panelAttachmentStyle = style
                try check(liquidAnimator.attachmentReveal.value == value
                          && liquidAnimator.attachmentReveal.velocity == velocity, "attachment_retarget_continuity")
                await settlePanelSoakRunLoop(milliseconds: 30)
                try await awaitIdle()
                try check(previewWindow.frame == unchangedFrame, "attachment_stable_frame")
                try check(liquidAnimator.attachmentReveal.value == style.blend, "attachment_settled")
            }
        }
        closePreview()
        try await awaitIdle()
        print("liquid_attachment=ok live_switches=10 menu_routing=ok access_restored=ok")
        settings.panelAttachmentStyle = .preserveMenu
        open(on: screenSelection.target)
        try await awaitIdle()
        let automaticFrame = previewWindow.frame
        for automatic in [true, false, true, false] {
            settings.automaticallyCoverMenuOnNoNotchDisplays = automatic
            await settlePanelSoakRunLoop(milliseconds: 30)
            try await awaitIdle()
            let hasNotch = menuStore.attachmentMetrics.notchWidth > 0
            let expected: PanelAttachmentStyle = automatic && !hasNotch ? .coverMenu : .preserveMenu
            try check(settings.panelAttachmentStyle == .preserveMenu
                      && menuStore.effectivePanelAttachmentStyle == expected
                      && liquidAnimator.attachmentReveal.value == expected.blend,
                      "automatic_attachment_preserves_manual_selection")
            try check(previewWindow.frame == automaticFrame, "automatic_attachment_stable_frame")
            try capture("automatic-attachment-\(automatic ? "on" : "off")")
        }
        closePreview()
        try await awaitIdle()
        print("liquid_automatic_attachment=ok toggles=4 manual_selection=preserved resolved_screen_has_notch=\(menuStore.attachmentMetrics.notchWidth > 0) frame=stable")
        for milliseconds: UInt64 in [30, 80, 150] {
            for iteration in 0..<5 {
                settings.panelAttachmentStyle = iteration.isMultiple(of: 2) ? .preserveMenu : .coverMenu
                open(on: screenSelection.target)
                await settlePanelSoakRunLoop(milliseconds: milliseconds)
                let progress = liquidAnimator.reveal.value, speed = liquidAnimator.reveal.velocity
                closePreview()
                try check(liquidAnimator.reveal.value == progress && liquidAnimator.reveal.velocity == speed, "closing_preserves_velocity")
                await settlePanelSoakRunLoop(milliseconds: 30)
                let reversedProgress = liquidAnimator.reveal.value, reversedSpeed = liquidAnimator.reveal.velocity
                open(on: screenSelection.target)
                try check(liquidAnimator.reveal.value == reversedProgress && liquidAnimator.reveal.velocity == reversedSpeed, "reopening_preserves_velocity")
                try await awaitIdle()
                closePreview()
                try await awaitIdle()
            }
        }
        open(on: screenSelection.target)
        try await awaitIdle()
        hidePreviewForExternalDrag()
        try check(!previewWindow.isVisible && liquidAnimator.isIdle && liquidAnimator.reveal.value == 0, "external_drag_reset")
        open(on: screenSelection.target)
        try check(liquidAnimator.reveal.value == 0, "open_after_drag_origin")
        try await awaitIdle()
        positionWindows()
        try check(liquidAnimator.isIdle && surface.currentShape.contentOpacity == 1, "recovery_snap")
        closePreview()
        try await awaitIdle()
        print("liquid_interruptions=ok reversals=30 external_drag=ok recovery=ok idle_display_link=stopped")
    }

    private func verifyInlineChatPanel() async throws {
        guard let screen = screenSelection.target, let window = previewWindow else { return }
        let chat = CodexChatController.shared
        let originalSize = settings.panelSize, originalDraft = chat.draft
        defer {
            chat.composerFocused = false; chat.panelExpanded = false; chat.draft = originalDraft
            settings.panelSize = originalSize
            resizePreviewForPanelSizeChange()
        }
        openPanel(showing: TimerProvider.pluginID)
        await settlePanelSoakRunLoop(milliseconds: 50)
        let panelID = ObjectIdentifier(window)
        for size in PanelSizeOption.allCases {
            settings.panelSize = size
            chat.panelExpanded = false
            openPanel(showing: TimerProvider.pluginID)
            resizePreviewForPanelSizeChange()
            await settlePanelSoakRunLoop(milliseconds: 30)
            guard chat.panelHeight == CodexChatPanelLayout.composerHeight else {
                throw PanelSoakVerificationError.failed("chat_composer_missing_\(size)")
            }
            chat.panelExpanded = true
            resizePreviewForPanelSizeChange()
            await settlePanelSoakRunLoop(milliseconds: 30)
            guard window.frame.minY >= screen.visibleFrame.minY - 1,
                  chat.panelHeight > CodexChatPanelLayout.composerHeight,
                  ObjectIdentifier(previewWindow!) == panelID,
                  !NSApp.windows.contains(where: { $0.title == "Codex チャット" }) else {
                throw PanelSoakVerificationError.failed("chat_history_outside_panel_\(size) minY=\(window.frame.minY) screenMinY=\(screen.visibleFrame.minY) lane=\(chat.panelHeight)")
            }
            chat.draft = "未送信の下書き"
            func composer(in view: NSView) -> ChatInputTextView? {
                if let editor = view as? ChatInputTextView { return editor }
                return view.subviews.lazy.compactMap { composer(in: $0) }.first
            }
            guard let content = window.contentView, let editor = composer(in: content) else {
                throw PanelSoakVerificationError.failed("chat_native_composer_missing")
            }
            window.makeFirstResponder(nil)
            AssetLibraryRuntime.shared.textInput = true
            window.makeFirstResponder(editor)
            guard chat.composerFocused, !AssetLibraryRuntime.shared.textInput else {
                throw PanelSoakVerificationError.failed("chat_focus_did_not_release_web_input_hold")
            }
            awaitingPointerAfterExplicitOpen = false
            scheduleClose(at: NSPoint(x: screen.frame.maxX + 100, y: screen.frame.minY - 100))
            await settlePanelSoakRunLoop(milliseconds: UInt64(PanelAnimationTiming.previewCloseDelay * 1000) + 80)
            guard window.isVisible else { throw PanelSoakVerificationError.failed("chat_closed_while_editing") }
            closePreview()
            guard !window.isVisible, chat.draft == "未送信の下書き", !chat.composerFocused else {
                throw PanelSoakVerificationError.failed("chat_manual_close_lost_draft")
            }
            print("PASS chat panel: \(size) inline resize, editing hold, manual hide, draft retained, no extra window")
        }
    }

    func runNonPhysicalSoakVerification(
        iterations: Int,
        providerIDs: [PluginID]
    ) async throws -> PanelSoakVerificationResult {
        guard isPanelSoakVerification,
              iterations >= 1,
              providerIDs.count >= 2,
              settings.voiceProvider == .off,
              !settings.voiceEnabled,
              VoiceLaneRuntime.shared.snapshot.mode == .disabled
        else {
            throw PanelSoakVerificationError.failed("panel_soak_precondition_failed")
        }
        guard let screen = screenSelection.target, let previewWindow else {
            throw PanelSoakVerificationError.failed("panel_soak_screen_unavailable")
        }

        try await verifyInlineChatPanel()
        let microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        showPill()
        let baselinePreviewIdentifier = ObjectIdentifier(previewWindow)
        let baselineAccessWindowCount = accessWindows.count
        let expectedFrame = PanelGeometry.frames(
            on: screen,
            panelSize: settings.panelSize,
            additionalPreviewHeight: CodexChatPanelLayout.composerHeight,
            showsNotchSideHandleArea: showsVisibleNotchSideHandle,
            showsVoiceConversation: VoiceActivityPresentation(snapshot: VoiceLaneRuntime.shared.snapshot).showsConversation
        ).preview

        func verifyAnimatedCycle(providerID: PluginID) async throws {
            let wasImmediate = panelSoakUsesImmediateTransitions
            panelSoakUsesImmediateTransitions = false
            defer { panelSoakUsesImmediateTransitions = wasImmediate }
            openPanel(showing: providerID)
            let openDeadline = Date().addingTimeInterval(2)
            repeat { await settlePanelSoakRunLoop(milliseconds: 20) }
            while (!liquidAnimator.isIdle || previewWindow.ignoresMouseEvents || previewWindow.frame != expectedFrame) && Date() < openDeadline
            guard previewWindow.isVisible,
                  !previewWindow.ignoresMouseEvents,
                  liquidAnimator.isIdle,
                  menuStore.providerStore.selectedPluginID == providerID,
                  VoiceLaneRuntime.shared.snapshot.mode == .disabled,
                  voiceLaneHeight(on: screen) == CodexChatPanelLayout.composerHeight
            else {
                throw PanelSoakVerificationError.failed("panel_soak_animated_open_readback_failed")
            }

            closePreview()
            let closeDeadline = Date().addingTimeInterval(2)
            repeat { await settlePanelSoakRunLoop(milliseconds: 20) }
            while previewWindow.isVisible && Date() < closeDeadline
            guard !previewWindow.isVisible,
                  resetTask == nil,
                  hoverMonitorTimer == nil,
                  accessMonitorTimer != nil,
                  ObjectIdentifier(previewWindow) == baselinePreviewIdentifier,
                  accessWindows.count == baselineAccessWindowCount
            else {
                throw PanelSoakVerificationError.failed("panel_soak_animated_close_readback_failed")
            }
        }

        // Warm the same display-link path that the final resource measurement exercises.
        for providerID in providerIDs.prefix(2) {
            try await verifyAnimatedCycle(providerID: providerID)
        }
        await settlePanelSoakRunLoop(milliseconds: 500)

        let baselineWindowCount = NSApp.windows.count
        let baselineTask = try PanelProcessMetrics.processTaskSnapshot()
        let baselineThreadCount = baselineTask.threadCount
        let baselineResidentMiB = baselineTask.residentMiB
        let baselineSocketCount = try PanelProcessMetrics.processSocketCount()
        let baselineChildProcessCount = try PanelProcessMetrics.childProcessCount()
        var maximumThreadCount = baselineThreadCount
        var maximumOpenMilliseconds = 0.0
        var providerSwitches = 0
        var recoveryCycles = 0
        var animatedTransitionCycles = 0

        for index in 0..<iterations {
            let providerID = providerIDs[index % providerIDs.count]
            let startedAt = CFAbsoluteTimeGetCurrent()
            openPanel(showing: providerID)
            await Task.yield()
            maximumOpenMilliseconds = max(
                maximumOpenMilliseconds,
                (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
            )
            guard previewWindow.isVisible,
                  menuStore.providerStore.selectedPluginID == providerID,
                  VoiceLaneRuntime.shared.snapshot.mode == .disabled,
                  voiceLaneHeight(on: screen) == CodexChatPanelLayout.composerHeight
            else {
                throw PanelSoakVerificationError.failed("panel_soak_open_readback_failed iteration=\(index) visible=\(previewWindow.isVisible) selected=\(menuStore.providerStore.selectedPluginID == providerID) voice_off=\(VoiceLaneRuntime.shared.snapshot.mode == .disabled) voice_height=\(voiceLaneHeight(on: screen)) app_active=\(NSApp.isActive) key=\(previewWindow.isKeyWindow)")
            }
            providerSwitches += 1

            closePreview()
            await settlePanelSoakRunLoop()
            guard !previewWindow.isVisible,
                  hoverMonitorTimer == nil,
                  accessMonitorTimer != nil,
                  ObjectIdentifier(previewWindow) == baselinePreviewIdentifier,
                  accessWindows.count == baselineAccessWindowCount
            else {
                throw PanelSoakVerificationError.failed("panel_soak_close_readback_failed")
            }

            if (index + 1).isMultiple(of: 20) {
                performSystemRecovery()
                await settlePanelSoakRunLoop()
                recoveryCycles += 1
            }
            if (index + 1).isMultiple(of: 25) {
                maximumThreadCount = max(
                    maximumThreadCount,
                    try PanelProcessMetrics.processTaskSnapshot().threadCount
                )
            }
        }

        for index in 0..<3 {
            let providerID = providerIDs[index % providerIDs.count]
            try await verifyAnimatedCycle(providerID: providerID)
            animatedTransitionCycles += 1
        }

        await settlePanelSoakRunLoop(milliseconds: 500)
        let finalTask = try PanelProcessMetrics.processTaskSnapshot()
        maximumThreadCount = max(maximumThreadCount, finalTask.threadCount)
        let finalWindowCount = NSApp.windows.count
        let finalSocketCount = try PanelProcessMetrics.processSocketCount()
        let finalChildProcessCount = try PanelProcessMetrics.childProcessCount()

        let resourceInvariants = [
            (liquidAnimator.isIdle, "liquid_display_link_stopped"),
            (finalWindowCount <= baselineWindowCount, "window_count"),
            (accessWindows.count == baselineAccessWindowCount, "access_window_count"),
            (ObjectIdentifier(previewWindow) == baselinePreviewIdentifier, "preview_identity"),
            (previewWindow.frame.isApproximatelyEqual(to: expectedFrame), "preview_frame"),
            (finalTask.threadCount <= baselineThreadCount + 8, "final_thread_count:\(baselineThreadCount)->\(finalTask.threadCount)"),
            (maximumThreadCount <= baselineThreadCount + 12, "maximum_thread_count:\(baselineThreadCount)->\(maximumThreadCount)"),
            (finalTask.residentMiB <= baselineResidentMiB + 64, "resident_memory"),
            (
                finalSocketCount <= baselineSocketCount + 1,
                "socket_count:\(baselineSocketCount)->\(finalSocketCount)"
            ),
            (finalChildProcessCount == baselineChildProcessCount, "child_process_count"),
            (AVCaptureDevice.authorizationStatus(for: .audio) == microphoneAuthorization, "microphone_authorization"),
            (settings.voiceProvider == .off, "voice_provider"),
            (!settings.voiceEnabled, "voice_enabled"),
            (VoiceLaneRuntime.shared.snapshot.mode == .disabled, "voice_lane_mode")
        ]
        let failedResourceInvariants = resourceInvariants.compactMap { passed, name in
            passed ? nil : name
        }
        if !failedResourceInvariants.isEmpty {
            throw PanelSoakVerificationError.failed(
                "panel_soak_resource_invariant_failed:\(failedResourceInvariants.joined(separator: ","))"
            )
        }

        return PanelSoakVerificationResult(
            iterations: iterations,
            providerSwitches: providerSwitches,
            recoveryCycles: recoveryCycles,
            animatedTransitionCycles: animatedTransitionCycles,
            warmOpenMaximumMilliseconds: maximumOpenMilliseconds,
            baselineWindowCount: baselineWindowCount,
            finalWindowCount: finalWindowCount,
            baselineThreadCount: baselineThreadCount,
            finalThreadCount: finalTask.threadCount,
            maximumThreadCount: maximumThreadCount,
            baselineResidentMiB: baselineResidentMiB,
            finalResidentMiB: finalTask.residentMiB,
            baselineSocketCount: baselineSocketCount,
            finalSocketCount: finalSocketCount,
            baselineChildProcessCount: baselineChildProcessCount,
            finalChildProcessCount: finalChildProcessCount
        )
    }

    private func panelFrames(on screen: NSScreen) -> PanelFrames {
        let normal = PanelGeometry.frames(
            on: screen,
            panelSize: settings.panelSize,
            additionalPreviewHeight: voiceLaneHeight(on: screen),
            showsNotchSideHandleArea: showsVisibleNotchSideHandle,
            showsVoiceConversation: VoiceActivityPresentation(snapshot: VoiceLaneRuntime.shared.snapshot).showsConversation
        )
        guard let size = AssetLibraryRuntime.shared.panelSize else { return normal }
        let fullscreen = AssetLibraryRuntime.shared.fullscreen
        let frame = fullscreen ? screen.frame : NSRect(x: min(screen.visibleFrame.maxX - size.width,
            max(screen.visibleFrame.minX, normal.preview.midX - size.width / 2)),
            y: normal.preview.maxY - size.height, width: size.width, height: size.height)
        return PanelFrames(access: normal.access, preview: frame, surfaceOriginWidth: normal.surfaceOriginWidth,
            accessStyle: normal.accessStyle, attachment: normal.attachment)
    }

    private func resolvedVoiceLaneLayout(on screen: NSScreen) -> VoiceLaneLayoutPreference {
        guard settings.voiceEnabled else { return .compact }
        let baseline = PanelGeometry.frames(
            on: screen,
            panelSize: settings.panelSize,
            showsNotchSideHandleArea: showsVisibleNotchSideHandle,
            showsVoiceConversation: VoiceActivityPresentation(snapshot: VoiceLaneRuntime.shared.snapshot).showsConversation
        )
        let availableExtraHeight = max(0, baseline.preview.minY - screen.visibleFrame.minY)
        return VoiceLaneGeometry.resolvedPreference(
            requested: settings.voiceLaneLayoutPreference,
            availableExtraHeight: Double(availableExtraHeight),
            panelSizeRawValue: settings.panelSize.rawValue
        )
    }

    private func voiceLaneHeight(on _: NSScreen) -> CGFloat {
        CodexChatController.shared.panelHeight
    }

    private func applyResolvedVoiceLaneLayout(on screen: NSScreen) {
        VoiceLaneRuntime.shared.setResolvedLayout(
            requested: settings.voiceLaneLayoutPreference,
            resolved: resolvedVoiceLaneLayout(on: screen)
        )
        let baseline = PanelGeometry.frames(on: screen, panelSize: settings.panelSize,
            showsNotchSideHandleArea: showsVisibleNotchSideHandle,
            showsVoiceConversation: VoiceActivityPresentation(snapshot: VoiceLaneRuntime.shared.snapshot).showsConversation)
        CodexChatController.shared.resolvePanelHeight(panelSize: settings.panelSize.rawValue,
            voiceMode: VoiceLaneRuntime.shared.snapshot.mode,
            availableHeight: max(0, baseline.preview.minY - screen.visibleFrame.minY))
    }

    private var showsVisibleNotchSideHandle: Bool {
        settings.showNotchSideHandleArea && settings.pillHandleIconStyle != .none
    }

    private func configureAccessWindow(for screen: NSScreen) -> NSPanel {
        let frames = panelFrames(on: screen)
        let panel = makePanel(
            size: frames.access.size,
            acceptsKeyboardFocus: false
        )
        panel.hasShadow = false
        let destination = AssetDropTargetView(content: NSHostingView(rootView: accessView(for: screen, style: frames.accessStyle)))
        panel.contentView = destination
        panel.setFrame(frames.access, display: false)
        return panel
    }

    private func accessView(for screen: NSScreen, style: PanelAccessStyle) -> AnyView {
        switch style {
        case .notchPill:
            return AnyView(
                HoverPillView(
                    settings: settings,
                    stickyReminders: stickyReminders,
                    onEnter: { [weak self] in self?.handleDirectHover(on: screen) },
                    onExit: { [weak self] in self?.scheduleClose() },
                    onTap: { [weak self] in self?.togglePreview(on: screen) }
                )
            )
        case .miniBar:
            return AnyView(
                HoverMiniBarView(
                    settings: settings,
                    stickyReminders: stickyReminders,
                    onBarEnter: { [weak self] in self?.handleDirectHover(on: screen) },
                    onBarExit: { [weak self] in self?.scheduleClose() },
                    onTap: { [weak self] in self?.togglePreview(on: screen) }
                )
            )
        }
    }

    private func configurePreviewWindow() {
        let hoverState = HoverState(
            onEnter: { [weak self] in self?.cancelClose() },
            onExit: { [weak self] in self?.scheduleClose() }
        )

        let panel = makePanel(
            size: PanelGeometry.previewSize(
                panelSize: settings.panelSize,
                additionalHeight: screenSelection.target.map { voiceLaneHeight(on: $0) } ?? 0
            ),
            acceptsKeyboardFocus: true
        )
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        let hostingController = NSHostingController(
            rootView: HoverPanelShell(
                hoverState: hoverState,
                store: menuStore,
                settings: settings,
                stickyReminders: stickyReminders,
                onOpenSettings: { [weak self] in self?.showSettings() },
                onClosePanel: { [weak self] in self?.closePreview() },
                onExternalDragStarted: { [weak self] in self?.prepareForExternalDrag() }
            )
        )
        hostingController.sizingOptions = []
        let surface = LiquidPanelSurfaceView(hostingView: hostingController.view)
        panel.contentView = surface
        previewHost = hostingController
        liquidSurface = surface
        liquidAnimator.view = surface
        previewWindow = panel
        if let screen = screenSelection.target {
            let frames = panelFrames(on: screen)
            configureSurfaceFrame(frames.preview, originWidth: frames.surfaceOriginWidth, progress: 0)
        }
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in
                // The nonphysical soak drives open/close itself; desktop focus is checked in UI acceptance.
                guard let self, !self.isPanelSoakVerification, self.awaitingPointerAfterExplicitOpen,
                      self.previewWindow?.attachedSheet == nil else { return }
                self.awaitingPointerAfterExplicitOpen = false
                self.closePreview()
            }
            .store(in: &settingsCancellables)
    }

    private func makePanel(size: NSSize, acceptsKeyboardFocus: Bool) -> NSPanel {
        let panel = HoverMenuPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.acceptsKeyboardFocus = acceptsKeyboardFocus
        // AppKit's window ordering animation scales the whole surface away from the screen edge.
        panel.animationBehavior = .none
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        return panel
    }

    private func togglePreview(on screen: NSScreen?) {
        if previewWindow?.isVisible == true {
            closePreview()
        } else {
            showPreview(on: screen)
        }
    }

    private func handleDirectHover(on screen: NSScreen) {
        guard !isPanelSoakVerification, usesDirectHoverEvents, !isVoiceControlLocation(on: screen) else { return }
        if previewWindow?.isVisible == true, !previewIsClosing,
           let activePreviewScreen, PanelScreenSelection.isSameDisplay(activePreviewScreen, screen) {
            cancelClose()
            return
        }
        showPreview(on: screen)
    }

    private func showSettings() {
        cancelClose()
        settingsWindowController.show()
        closePreview()
    }

    private func prepareForExternalDrag() {
        cancelClose()
        stopHoverMonitor()
        let token = previewAnimationToken + 1
        previewAnimationToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            Task { @MainActor in
                guard let self, self.previewAnimationToken == token else { return }
                self.hidePreviewForExternalDrag()
            }
        }
    }

    private func hidePreviewForExternalDrag() {
        guard let previewWindow, previewWindow.isVisible else { return }
        resetTask?.cancel()
        resetTask = nil
        setProviderActive(false)
        previewWindow.alphaValue = 1
        previewWindow.hasShadow = false
        previewWindow.invalidateShadow()
        previewWindow.ignoresMouseEvents = false
        if let screen = previewWindow.screen ?? activePreviewScreen ?? screenSelection.target {
            previewWindow.setFrame(panelFrames(on: screen).preview, display: false)
        }
        liquidAnimator.snap(progress: 0, frame: previewWindow.frame)
        previewIsClosing = false
        orderOutPreviewWindow(previewWindow)
        menuStore.providerStore.prepareForPanelClose()
    }

    private func showPreview(on requestedScreen: NSScreen?) {
        cancelClose()
        resetTask?.cancel()
        resetTask = nil
        mouseEventsEnableTask?.cancel()
        mouseEventsEnableTask = nil
        guard let screen = requestedScreen ?? screenSelection.target, let previewWindow else { return }
        let changedScreen = activePreviewScreen.map { !PanelScreenSelection.isSameDisplay($0, screen) } ?? false
        let wasVisible = previewWindow.isVisible && !changedScreen
        if changedScreen { orderOutPreviewWindow(previewWindow) }
        activePreviewScreen = screen
        previewIsClosing = false
        applyResolvedVoiceLaneLayout(on: screen)
        VoiceLaneRuntime.shared.attachPanel()
        let frames = panelFrames(on: screen)
        menuStore.providerStore.prepareForPanelOpen(isSecondaryDisplay: screenSelection.isSecondaryDisplay(screen))
        setProviderActive(true)
        menuStore.providerStore.refreshSelected(reason: .panelOpened)
        previewAnimationToken += 1
        let token = previewAnimationToken

        if !wasVisible {
            configureSurfaceFrame(frames.preview, originWidth: frames.surfaceOriginWidth, progress: 0)
        } else if liquidAnimator.rect.target != frames.preview {
            resizeSurface(to: frames.preview, originWidth: frames.surfaceOriginWidth)
        }
        previewWindow.alphaValue = 1
        previewWindow.hasShadow = false
        previewWindow.ignoresMouseEvents = true
        previewWindow.orderFrontRegardless()
        accessWindows[PanelScreenSelection.key(screen)]?.orderOut(nil)
        previewWindow.makeKey()
        startPointerMonitors()
        liquidAnimator.onSettled = { [weak self] in self?.finishPreviewOpen(token: token) }

        if shouldReduceMotion {
            configureSurfaceFrame(frames.preview, originWidth: frames.surfaceOriginWidth, progress: 1)
            if isPanelSoakVerification {
                finishPreviewOpen(token: token)
            } else {
                previewWindow.alphaValue = wasVisible ? previewWindow.alphaValue : 0
                fadePreviewWindow(to: 1, duration: 0.12, token: token) { [weak self] in
                    self?.finishPreviewOpen(token: token)
                }
            }
            return
        }
        enablePreviewMouseEventsSoon(for: previewWindow, token: token)
        liquidAnimator.setReveal(1)
    }

    private func finishPreviewOpen(token: Int) {
        guard previewAnimationToken == token, !previewIsClosing,
              let previewWindow, previewWindow.isVisible else { return }
        let frame = liquidAnimator.rect.target
        configureSurfaceFrame(frame, originWidth: liquidAnimator.originWidth, progress: 1)
        previewWindow.alphaValue = 1
        previewWindow.hasShadow = false
        previewWindow.invalidateShadow()
        previewWindow.ignoresMouseEvents = false
        updatePreviewMouseRouting()
        startHoverMonitor()
    }

    private func fadePreviewWindow(to alpha: CGFloat, duration: TimeInterval, token: Int,
                                   completion: @escaping @MainActor () -> Void) {
        guard let previewWindow else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            previewWindow.animator().alphaValue = alpha
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.previewAnimationToken == token else { return }
                completion()
            }
        }
    }

    private func configureSurfaceFrame(_ frame: NSRect, originWidth: CGFloat, progress: Double) {
        guard let previewWindow else { return }
        updateAttachment(animated: false)
        previewWindow.disableScreenUpdatesUntilFlush()
        previewWindow.setFrame(frame, display: true)
        liquidSurface?.layoutContent(size: frame.size)
        liquidAnimator.originWidth = originWidth
        liquidAnimator.snap(progress: progress, frame: frame)
    }

    private func enablePreviewMouseEventsSoon(for previewWindow: NSPanel, token: Int) {
        let task = DispatchWorkItem { [weak self, weak previewWindow] in
            Task { @MainActor in
                guard let self,
                      let previewWindow,
                      self.previewAnimationToken == token,
                      previewWindow.isVisible
                else {
                    return
                }

                if self.isPanelSoakVerification {
                    previewWindow.ignoresMouseEvents = false
                } else {
                    self.updatePreviewMouseRouting()
                }
            }
        }
        mouseEventsEnableTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: task)
    }

    private func scheduleClose(at location: NSPoint? = nil) {
        guard !isPanelSoakVerification || location != nil else { return }
        closeTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeTask = nil
            guard !self.isMouseInsideHoverRegion(at: location), self.previewWindow?.attachedSheet == nil,
                  !AssetLibraryRuntime.shared.holdsPanel,
                  !CodexChatController.shared.holdsPanel,
                  !self.awaitingPointerAfterExplicitOpen,
                  TimerStore.shared.activeAlert == nil,
                  self.stickyReminders.activeNote == nil else { return }
            self.closePreview()
        }
        closeTask = task
        DispatchQueue.main.asyncAfter(
            deadline: .now() + PanelAnimationTiming.previewCloseDelay,
            execute: task
        )
    }

    private func cancelClose() {
        closeTask?.cancel()
        closeTask = nil
    }

    private func closePreview() {
        guard !AssetLibraryRuntime.shared.holdsPanel else { return }
        AssetLibraryRuntime.shared.endPreview()
        CodexChatController.shared.composerFocused = false
        previewWindow?.makeFirstResponder(nil)
        awaitingPointerAfterExplicitOpen = false
        guard let previewWindow, previewWindow.isVisible else {
            menuStore.providerStore.prepareForPanelClose()
            return
        }

        stopHoverMonitor()
        mouseEventsEnableTask?.cancel()
        mouseEventsEnableTask = nil
        previewAnimationToken += 1
        let token = previewAnimationToken
        resetTask?.cancel()
        resetTask = nil
        setProviderActive(false)

        previewIsClosing = true
        let frame = liquidAnimator.rect.target
        guard !shouldReduceMotion else {
            liquidAnimator.snap(progress: 1, frame: frame)
            previewWindow.ignoresMouseEvents = true
            if isPanelSoakVerification {
                resetClosedPreviewWindow(previewWindow, frame: frame)
            } else {
                fadePreviewWindow(to: 0, duration: 0.09, token: token) { [weak self, weak previewWindow] in
                    guard let self, let previewWindow else { return }
                    self.resetClosedPreviewWindow(previewWindow, frame: frame)
                }
            }
            return
        }
        previewWindow.hasShadow = false
        previewWindow.ignoresMouseEvents = true
        liquidAnimator.onSettled = { [weak self, weak previewWindow] in
            guard let self, let previewWindow, self.previewAnimationToken == token else { return }
            self.resetClosedPreviewWindow(previewWindow, frame: self.liquidAnimator.rect.target)
        }
        liquidAnimator.setReveal(0)
        let task = DispatchWorkItem { [weak self, weak previewWindow] in
            guard let self, let previewWindow, self.previewAnimationToken == token else { return }
            self.resetClosedPreviewWindow(previewWindow, frame: self.liquidAnimator.rect.target)
        }
        resetTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelAnimationTiming.closeFallbackDuration, execute: task)
    }

    private func resetClosedPreviewWindow(_ previewWindow: NSPanel, frame: NSRect) {
        resetTask?.cancel()
        resetTask = nil
        stopHoverMonitor()
        mouseEventsEnableTask?.cancel()
        mouseEventsEnableTask = nil
        orderOutPreviewWindow(previewWindow)
        setProviderActive(false)
        activePreviewScreen = nil
        menuStore.providerStore.prepareForPanelClose()
        liquidAnimator.snap(progress: 0, frame: frame)
        liquidAnimator.onSettled = nil
        previewIsClosing = false
        previewWindow.alphaValue = 1
        previewWindow.hasShadow = false
        previewWindow.invalidateShadow()
        previewWindow.ignoresMouseEvents = false
        previewWindow.setFrame(frame, display: false)
    }

    private func orderOutPreviewWindow(_ previewWindow: NSPanel) {
        VoiceLaneRuntime.shared.detachPanel()
        previewWindow.orderOut(nil)
        syncAccessWindows(orderFront: true)
    }

    private func isMouseInsideHoverRegion(at location: NSPoint? = nil) -> Bool {
        let location = location ?? NSEvent.mouseLocation
        let previewContainsMouse = previewWindow?.isVisible == true
            && (liquidSurface?.contains(screenPoint: location, tolerance: 4) ?? false)
        // The notch remains the hover origin even while its access window is hidden.
        if previewWindow?.isVisible == true, let activePreviewScreen {
            return panelFrames(on: activePreviewScreen).access.insetBy(dx: -4, dy: -4).contains(location)
                || previewContainsMouse
        }
        return accessWindows.values.contains {
            $0.isVisible && $0.frame.insetBy(dx: -4, dy: -4).contains(location)
        } || previewContainsMouse
    }

    /// Voice controls on the closed access surface must receive the click
    /// without opening the panel first. The center gap keeps the normal panel
    /// hover/click entry available, including on the no-notch 108pt bar.
    private func isVoiceControlLocation(on screen: NSScreen) -> Bool {
        guard VoiceActivityPresentation(snapshot: VoiceLaneRuntime.shared.snapshot).showsConversation,
              let accessWindow = accessWindows[PanelScreenSelection.key(screen)],
              let style = accessWindowStyles[PanelScreenSelection.key(screen)] else {
            return false
        }

        let sideWidth = style == .notchPill
            ? PanelLayout.notchHandleWidth
            : VoiceAccessIndicator.noNotchSideControlWidth
        let frame = accessWindow.frame
        let location = NSEvent.mouseLocation
        let leftControl = NSRect(
            x: frame.minX,
            y: frame.minY,
            width: sideWidth,
            height: frame.height
        )
        let rightControl = NSRect(
            x: frame.maxX - sideWidth,
            y: frame.minY,
            width: sideWidth,
            height: frame.height
        )
        return leftControl.contains(location) || rightControl.contains(location)
    }

    private func startHoverMonitor() {
        guard hoverMonitorTimer == nil else { return }

        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updatePreviewMouseRouting()
                self.closeIfMouseLeftHoverRegion()
            }
        }
        timer.tolerance = 0.04
        hoverMonitorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startPointerMonitors() {
        guard globalPointerMonitor == nil, localPointerMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            Task { @MainActor in self?.updatePreviewMouseRouting() }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.updatePreviewMouseRouting() }
            return event
        }
    }

    private func stopHoverMonitor() {
        hoverMonitorTimer?.invalidate()
        hoverMonitorTimer = nil
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        globalPointerMonitor = nil
        localPointerMonitor = nil
    }

    private func updatePreviewMouseRouting(at location: NSPoint? = nil) {
        guard (!isPanelSoakVerification || location != nil), !previewIsClosing, let previewWindow, previewWindow.isVisible else { return }
        // The transparent menu areas must route to the windows below this panel.
        previewWindow.ignoresMouseEvents = !(liquidSurface?.contains(screenPoint: location ?? NSEvent.mouseLocation) ?? false)
    }

    private func closeIfMouseLeftHoverRegion(at location: NSPoint? = nil) {
        guard !isPanelSoakVerification || location != nil else { return }
        if isMouseInsideHoverRegion(at: location) {
            awaitingPointerAfterExplicitOpen = false
            cancelClose()
            return
        }
        guard previewWindow?.isVisible == true,
              closeTask == nil,
              previewWindow?.attachedSheet == nil,
              !awaitingPointerAfterExplicitOpen,
              TimerStore.shared.activeAlert == nil,
              stickyReminders.activeNote == nil,
              !isMouseInsideHoverRegion(at: location)
        else {
            return
        }

        scheduleClose(at: location)
    }

    private func startAccessMonitor() {
        guard accessMonitorTimer == nil else { return }

        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.monitorAccessWindows()
            }
        }
        timer.tolerance = 0.04
        accessMonitorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func monitorAccessWindows() {
        let assets = AssetLibraryRuntime.shared
        let dragBoard = NSPasteboard(name: .drag)
        AssetDropOverlay.shared.track(board: dragBoard, dragging: NSEvent.pressedMouseButtons != 0 && dragBoard.changeCount != dragChangeCount,
                                      allowed: assets.canAcceptDrop?() == true && assets.editing == nil)
        if NSEvent.pressedMouseButtons == 0 {
            dragChangeCount = dragBoard.changeCount
            if assets.incomingDrag {
                assets.incomingDrag = false
                if !assets.dropReceived { menuStore.providerStore.restoreTemporarySelection(); closePreview() }
                else { awaitingPointerAfterExplicitOpen = true }
            }
        } else if !AssetDropOverlay.shared.isPresented, !assets.incomingDrag, dragBoard.changeCount != dragChangeCount,
                  AssetIncomingDrop.accepts(dragBoard), assets.canAcceptDrop?() == true,
                  screenSelection.access.contains(where: { panelFrames(on: $0).access.insetBy(dx: -12, dy: -6).contains(NSEvent.mouseLocation) }) {
            assets.openForDrop?()
        }
        let now = Date()
        if now.timeIntervalSince(lastAccessWindowHealthCheck) >= 2 {
            lastAccessWindowHealthCheck = now
            repairAccessWindowsIfNeeded()
        }

        guard !isPanelSoakVerification, !AssetDropOverlay.shared.isPresented, previewWindow?.isVisible != true else { return }

        let mouseLocation = NSEvent.mouseLocation
        for screen in screenSelection.access {
            guard let accessWindow = accessWindows[PanelScreenSelection.key(screen)],
                  accessWindow.isVisible == !suppressesAccessWindow(on: screen),
                  accessWindow.frame.contains(mouseLocation),
                  !isVoiceControlLocation(on: screen)
            else {
                continue
            }

            showPreview(on: screen)
            return
        }
    }

    private func repairAccessWindowsIfNeeded() {
        guard !accessWindowsAreHealthy() else { return }
        logger.notice("Rebuilding unavailable hover access windows")
        rebuildAccessWindows(orderFront: true)
    }

    private func accessWindowsAreHealthy() -> Bool {
        let screens = screenSelection.access
        guard screens.count == accessWindows.count else { return false }

        for screen in screens {
            let key = PanelScreenSelection.key(screen)
            let expected = panelFrames(on: screen)
            guard let accessWindow = accessWindows[key],
                  accessWindowStyles[key] == expected.accessStyle,
                  accessWindow.isVisible == !suppressesAccessWindow(on: screen),
                  accessWindow.frame.isApproximatelyEqual(to: expected.access)
            else {
                return false
            }
        }

        return true
    }

    private func rebuildAccessWindows(orderFront: Bool) {
        accessWindows.values.forEach { $0.orderOut(nil) }
        accessWindows.removeAll()
        accessWindowStyles.removeAll()
        syncAccessWindows(orderFront: orderFront)
    }

    private func performSystemRecovery() {
        logger.notice("Recovering hover access windows after a system transition")
        rebuildAccessWindows(orderFront: true)
        positionWindows()
        startAccessMonitor()
    }

    private func syncAccessWindows(orderFront: Bool) {
        let screens = screenSelection.access
        let desiredKeys = Set(screens.map(PanelScreenSelection.key))

        let obsoleteKeys = accessWindows.keys.filter { !desiredKeys.contains($0) }
        for key in obsoleteKeys {
            accessWindows[key]?.orderOut(nil)
            accessWindows.removeValue(forKey: key)
            accessWindowStyles.removeValue(forKey: key)
        }

        for screen in screens {
            let key = PanelScreenSelection.key(screen)
            let frames = panelFrames(on: screen)

            if accessWindows[key] == nil || accessWindowStyles[key] != frames.accessStyle {
                accessWindows[key]?.orderOut(nil)
                accessWindows[key] = configureAccessWindow(for: screen)
                accessWindowStyles[key] = frames.accessStyle
            }

            accessWindows[key]?.setFrame(frames.access, display: true)
            if suppressesAccessWindow(on: screen) {
                accessWindows[key]?.orderOut(nil)
            } else if orderFront {
                accessWindows[key]?.orderFrontRegardless()
            }
        }
    }

    private var screenSelection: PanelScreenSelection {
        PanelScreenSelection(mode: settings.displayPlacementMode)
    }

    private func suppressesAccessWindow(on screen: NSScreen) -> Bool {
        previewWindow?.isVisible == true && activePreviewScreen.map { PanelScreenSelection.isSameDisplay($0, screen) } == true
    }

    private var shouldReduceMotion: Bool {
        if isPanelSoakVerification {
            return panelSoakUsesImmediateTransitions
        }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func settlePanelSoakRunLoop(milliseconds: UInt64 = 2) async {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    private func setProviderActive(_ isActive: Bool) {
        guard menuStore.providerActive != isActive else { return }
        menuStore.providerActive = isActive
    }

    private func observeSettings() {
        settings.$displayPlacementMode
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                closePreview()
                showPill()
                positionWindows()
            }
            .store(in: &settingsCancellables)

        settings.$panelSize
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.resizePreviewForPanelSizeChange()
                }
            }
            .store(in: &settingsCancellables)

        settings.$panelAttachmentStyle
            .combineLatest(settings.$automaticallyCoverMenuOnNoNotchDisplays)
            .dropFirst()
            .removeDuplicates { previous, current in previous.0 == current.0 && previous.1 == current.1 }
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.resizePreviewForPanelSizeChange() }
            }
            .store(in: &settingsCancellables)

        CodexChatController.shared.$panelExpanded
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.resizePreviewForPanelSizeChange() }
            }
            .store(in: &settingsCancellables)

        settings.$voiceEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.resizePreviewForPanelSizeChange()
                }
            }
            .store(in: &settingsCancellables)

        VoiceLaneRuntime.shared.$snapshot
            .map(\.mode)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.resizePreviewForPanelSizeChange()
                }
            }
            .store(in: &settingsCancellables)

        VoiceLaneRuntime.shared.$snapshot
            .map { VoiceActivityPresentation(snapshot: $0).showsConversation }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.resizePreviewForPanelSizeChange()
                }
            }
            .store(in: &settingsCancellables)

        settings.$voiceLaneLayoutPreference
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.resizePreviewForPanelSizeChange()
                }
            }
            .store(in: &settingsCancellables)

        settings.$showNotchSideHandleArea
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.syncAccessWindows(orderFront: false)
                    self?.resizePreviewForPanelSizeChange()
                    self?.showPill()
                }
            }
            .store(in: &settingsCancellables)

        settings.$pillHandleIconStyle
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.syncAccessWindows(orderFront: false)
                    self?.resizePreviewForPanelSizeChange()
                    self?.showPill()
                }
            }
            .store(in: &settingsCancellables)
    }

    private func observeTimerAlerts() {
        TimerStore.shared.$activeAlert
            .removeDuplicates()
            .sink { [weak self] alert in
                guard let self, alert != nil else { return }
                guard AssetLibraryRuntime.shared.panelSize == nil else { return }
                openPanel(showing: TimerProvider.pluginID)
            }
            .store(in: &settingsCancellables)
    }

    private func observeStickyReminders() {
        stickyReminders.$activeNote
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] noteID in
                guard noteID != nil else { return }
                self?.openPanel(showing: StickyNotesProvider.pluginID)
            }
            .store(in: &settingsCancellables)
    }

    private func resizePreviewForPanelSizeChange() {
        syncAccessWindows(orderFront: false)
        guard let screen = activePreviewScreen ?? previewWindow?.screen ?? screenSelection.target else { return }
        applyResolvedVoiceLaneLayout(on: screen)
        let frames = panelFrames(on: screen)
        guard let previewWindow else { return }
        if !previewWindow.isVisible {
            configureSurfaceFrame(frames.preview, originWidth: frames.surfaceOriginWidth, progress: 0)
            return
        }
        if previewIsClosing {
            // Preserve closing completion and its generation when the voice lane changes.
            configureSurfaceFrame(frames.preview, originWidth: frames.surfaceOriginWidth, progress: 0)
            resetClosedPreviewWindow(previewWindow, frame: frames.preview)
            return
        }
        if shouldReduceMotion {
            configureSurfaceFrame(frames.preview, originWidth: frames.surfaceOriginWidth, progress: 1)
            finishPreviewOpen(token: previewAnimationToken)
            return
        }
        resizeSurface(to: frames.preview, originWidth: frames.surfaceOriginWidth)
        let token = previewAnimationToken
        liquidAnimator.onSettled = { [weak self] in self?.finishPreviewOpen(token: token) }
    }

    private func resizeSurface(to frame: NSRect, originWidth: CGFloat) {
        guard let previewWindow else { return }
        updateAttachment(animated: true)
        previewWindow.disableScreenUpdatesUntilFlush()
        previewWindow.hasShadow = false
        previewWindow.setFrame(previewWindow.frame.union(frame), display: true)
        liquidSurface?.layoutContent(size: frame.size)
        liquidAnimator.originWidth = originWidth
        liquidAnimator.retargetFrame(frame, animated: true)
        liquidAnimator.apply()
    }

    private func updateAttachment(animated: Bool) {
        guard let screen = activePreviewScreen ?? screenSelection.target else { return }
        let metrics = panelFrames(on: screen).attachment
        if menuStore.attachmentMetrics != metrics { menuStore.attachmentMetrics = metrics }
        liquidAnimator.setAttachment(metrics, style: menuStore.effectivePanelAttachmentStyle, animated: animated)
    }
}
