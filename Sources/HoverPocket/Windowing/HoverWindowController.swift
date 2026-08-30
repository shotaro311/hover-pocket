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
    private var activePreviewScreen: NSScreen?
    private var closeTask: DispatchWorkItem?
    private var resetTask: DispatchWorkItem?
    private var hoverMonitorTimer: Timer?
    private var accessMonitorTimer: Timer?
    private var mouseEventsEnableTask: DispatchWorkItem?
    private var systemRecoveryTasks: [DispatchWorkItem] = []
    private var lastAccessWindowHealthCheck = Date.distantPast
    private var previewAnimationToken = 0
    private let usesDirectHoverEvents = !CommandLine.arguments.contains("--verify-hover-recovery")
    private let isPanelSoakVerification = CommandLine.arguments.contains(
        "--verify-panel-soak"
    )
    private var panelSoakUsesImmediateTransitions = true
    private let logger = Logger(subsystem: "com.hoverpocket.app", category: "HoverWindowRecovery")
    private let settings: AppSettings
    private let menuStore: HoverMenuStore
    private let settingsWindowController: SettingsWindowController
    private var settingsCancellables = Set<AnyCancellable>()

    var appSettings: AppSettings {
        settings
    }

    init(
        settingsDefaults: any AppSettingsDefaultsStoring = HoverPocketRuntimeEnvironment.shared.settingsDefaults,
        providerRegistry: ProviderRegistry? = nil
    ) {
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
        observeSettings()
        observeTimerAlerts()
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
        guard let screen = activePreviewScreen ?? targetScreen() else { return }

        applyResolvedVoiceLaneLayout(on: screen)
        let frames = panelFrames(on: screen)

        if previewWindow?.isVisible == true {
            previewWindow?.setFrame(frames.preview, display: true)
        } else {
            previewWindow?.setFrame(frames.preview, display: false)
        }
    }

    func openPanelFromMenu() {
        showPreview(on: targetScreen())
    }

    /// Opens the panel and switches to the given provider. `select` must run
    /// after `showPreview` because panel opening restores the settings-based
    /// provider selection.
    func openPanel(showing pluginID: PluginID) {
        showPreview(on: targetScreen())
        menuStore.providerStore.select(pluginID)
    }

    func openSettingsFromMenu() {
        showSettings()
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
        guard let screen = targetScreen(), let previewWindow else {
            throw PanelSoakVerificationError.failed("panel_soak_screen_unavailable")
        }

        let microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        showPill()
        openPanel(showing: providerIDs[0])
        closePreview()
        await settlePanelSoakRunLoop()

        let baselinePreviewIdentifier = ObjectIdentifier(previewWindow)
        let baselineAccessWindowCount = accessWindows.count
        let baselineWindowCount = NSApp.windows.count
        let baselineTask = try processTaskSnapshot()
        let baselineThreadCount = baselineTask.threadCount
        let baselineResidentMiB = baselineTask.residentMiB
        let baselineSocketCount = try processSocketCount()
        let baselineChildProcessCount = try childProcessCount()
        let expectedFrame = PanelGeometry.frames(
            on: screen,
            panelSize: settings.panelSize,
            additionalPreviewHeight: 0,
            showsNotchSideHandleArea: showsVisibleNotchSideHandle
        ).preview
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
                  voiceLaneHeight(on: screen) == 0
            else {
                throw PanelSoakVerificationError.failed("panel_soak_open_readback_failed")
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
                    try processTaskSnapshot().threadCount
                )
            }
        }

        panelSoakUsesImmediateTransitions = false
        defer { panelSoakUsesImmediateTransitions = true }
        for index in 0..<3 {
            let providerID = providerIDs[index % providerIDs.count]
            openPanel(showing: providerID)
            await settlePanelSoakRunLoop(milliseconds: 300)
            guard previewWindow.isVisible,
                  !previewWindow.ignoresMouseEvents,
                  menuStore.providerStore.selectedPluginID == providerID,
                  VoiceLaneRuntime.shared.snapshot.mode == .disabled,
                  voiceLaneHeight(on: screen) == 0
            else {
                throw PanelSoakVerificationError.failed("panel_soak_animated_open_readback_failed")
            }

            closePreview()
            await settlePanelSoakRunLoop(milliseconds: 300)
            guard !previewWindow.isVisible,
                  resetTask == nil,
                  hoverMonitorTimer == nil,
                  accessMonitorTimer != nil,
                  ObjectIdentifier(previewWindow) == baselinePreviewIdentifier,
                  accessWindows.count == baselineAccessWindowCount
            else {
                throw PanelSoakVerificationError.failed("panel_soak_animated_close_readback_failed")
            }
            animatedTransitionCycles += 1
        }

        await settlePanelSoakRunLoop(milliseconds: 100)
        let finalTask = try processTaskSnapshot()
        maximumThreadCount = max(maximumThreadCount, finalTask.threadCount)
        let finalWindowCount = NSApp.windows.count
        let finalSocketCount = try processSocketCount()
        let finalChildProcessCount = try childProcessCount()

        guard finalWindowCount == baselineWindowCount,
              accessWindows.count == baselineAccessWindowCount,
              ObjectIdentifier(previewWindow) == baselinePreviewIdentifier,
              previewWindow.frame.isApproximatelyEqual(to: expectedFrame),
              finalTask.threadCount <= baselineThreadCount + 8,
              maximumThreadCount <= baselineThreadCount + 12,
              finalTask.residentMiB <= baselineResidentMiB + 64,
              finalSocketCount == baselineSocketCount,
              finalChildProcessCount == baselineChildProcessCount,
              AVCaptureDevice.authorizationStatus(for: .audio) == microphoneAuthorization,
              settings.voiceProvider == .off,
              !settings.voiceEnabled,
              VoiceLaneRuntime.shared.snapshot.mode == .disabled
        else {
            throw PanelSoakVerificationError.failed("panel_soak_resource_invariant_failed")
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
        PanelGeometry.frames(
            on: screen,
            panelSize: settings.panelSize,
            additionalPreviewHeight: voiceLaneHeight(on: screen),
            showsNotchSideHandleArea: showsVisibleNotchSideHandle
        )
    }

    private func resolvedVoiceLaneLayout(on screen: NSScreen) -> VoiceLaneLayoutPreference {
        guard settings.voiceEnabled else { return .compact }
        let baseline = PanelGeometry.frames(
            on: screen,
            panelSize: settings.panelSize,
            showsNotchSideHandleArea: showsVisibleNotchSideHandle
        )
        let availableExtraHeight = max(0, baseline.preview.minY - screen.visibleFrame.minY)
        return VoiceLaneGeometry.resolvedPreference(
            requested: settings.voiceLaneLayoutPreference,
            availableExtraHeight: Double(availableExtraHeight),
            panelSizeRawValue: settings.panelSize.rawValue
        )
    }

    private func voiceLaneHeight(on _: NSScreen) -> CGFloat {
        CGFloat(VoiceLaneGeometry.height(
            panelSizeRawValue: settings.panelSize.rawValue,
            mode: VoiceLaneRuntime.shared.snapshot.mode
        ))
    }

    private func applyResolvedVoiceLaneLayout(on screen: NSScreen) {
        VoiceLaneRuntime.shared.setResolvedLayout(
            requested: settings.voiceLaneLayoutPreference,
            resolved: resolvedVoiceLaneLayout(on: screen)
        )
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
        let hostingController = NSHostingController(rootView: accessView(for: screen, style: frames.accessStyle))
        hostingController.sizingOptions = []
        panel.contentViewController = hostingController
        panel.setFrame(frames.access, display: false)
        return panel
    }

    private func accessView(for screen: NSScreen, style: PanelAccessStyle) -> AnyView {
        switch style {
        case .notchPill:
            return AnyView(
                HoverPillView(
                    settings: settings,
                    onEnter: { [weak self] in self?.handleDirectHover(on: screen) },
                    onExit: { [weak self] in self?.scheduleClose() },
                    onTap: { [weak self] in self?.togglePreview(on: screen) }
                )
            )
        case .miniBar:
            return AnyView(
                HoverMiniBarView(
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
                additionalHeight: targetScreen().map { voiceLaneHeight(on: $0) } ?? 0
            ),
            acceptsKeyboardFocus: true
        )
        panel.hasShadow = true
        let hostingController = NSHostingController(
            rootView: HoverPanelShell(
                hoverState: hoverState,
                store: menuStore,
                settings: settings,
                onOpenSettings: { [weak self] in self?.showSettings() },
                onClosePanel: { [weak self] in self?.closePreview() },
                onExternalDragStarted: { [weak self] in self?.prepareForExternalDrag() }
            )
        )
        // 既定の`sizingOptions`だと、HoverPanelShellの固定frameがウィンドウの
        // min/maxサイズとして確定し、開くアニメーションの開始フレーム
        // (collapsedPreview 72x12)が左上を起点に全幅へ引き伸ばされる。パネルが
        // 中央ではなく右寄りから現れて左へスライドする原因になるため無効化する。
        hostingController.sizingOptions = []
        panel.contentViewController = hostingController
        previewWindow = panel
    }

    private func makePanel(size: NSSize, acceptsKeyboardFocus: Bool) -> NSPanel {
        let panel = HoverMenuPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.acceptsKeyboardFocus = acceptsKeyboardFocus
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
        guard usesDirectHoverEvents else { return }
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
        setPreviewContentVisible(false, animated: false)
        previewWindow.alphaValue = 1
        previewWindow.hasShadow = true
        previewWindow.invalidateShadow()
        previewWindow.ignoresMouseEvents = false
        if let screen = previewWindow.screen ?? activePreviewScreen ?? targetScreen() {
            previewWindow.setFrame(panelFrames(on: screen).preview, display: false)
        }
        orderOutPreviewWindow(previewWindow)
        menuStore.providerStore.prepareForPanelClose()
    }

    private func showPreview(on requestedScreen: NSScreen?) {
        cancelClose()
        resetTask?.cancel()
        resetTask = nil
        mouseEventsEnableTask?.cancel()
        mouseEventsEnableTask = nil

        guard let screen = requestedScreen ?? targetScreen(), let previewWindow else { return }
        activePreviewScreen = screen
        applyResolvedVoiceLaneLayout(on: screen)
        VoiceLaneRuntime.shared.attachPanel()
        let frames = panelFrames(on: screen)
        menuStore.providerStore.prepareForPanelOpen(isSecondaryDisplay: isSecondaryDisplay(screen))
        setProviderActive(true)
        menuStore.providerStore.refreshSelected(reason: .panelOpened)

        previewAnimationToken += 1
        let token = previewAnimationToken

        let wasVisible = previewWindow.isVisible
        if !wasVisible {
            setPreviewContentVisible(false, animated: false)
            previewWindow.alphaValue = shouldReduceMotion ? 1 : 0.9
            previewWindow.setFrame(shouldReduceMotion ? frames.preview : frames.collapsedPreview, display: true)
        }

        previewWindow.hasShadow = false
        previewWindow.ignoresMouseEvents = true
        previewWindow.orderFrontRegardless()
        previewWindow.makeKey()
        enablePreviewMouseEventsSoon(for: previewWindow, token: token)

        if shouldReduceMotion {
            mouseEventsEnableTask?.cancel()
            mouseEventsEnableTask = nil
            previewWindow.hasShadow = true
            previewWindow.invalidateShadow()
            previewWindow.ignoresMouseEvents = false
            setPreviewContentVisible(true, animated: false)
            startHoverMonitor()
            return
        }

        setPreviewContentVisible(true, animated: false)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = PanelAnimationTiming.previewOpenDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.96, 0.28, 1.0)
            previewWindow.animator().setFrame(frames.preview, display: true)
            previewWindow.animator().alphaValue = 1
        } completionHandler: { [weak self, weak previewWindow] in
            Task { @MainActor in
                guard let self, let previewWindow, self.previewAnimationToken == token else { return }
                previewWindow.setFrame(frames.preview, display: true)
                previewWindow.alphaValue = 1
                previewWindow.hasShadow = true
                previewWindow.invalidateShadow()
                previewWindow.ignoresMouseEvents = false
                self.startHoverMonitor()
            }
        }
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

                previewWindow.ignoresMouseEvents = false
            }
        }
        mouseEventsEnableTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: task)
    }

    private func scheduleClose() {
        closeTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeTask = nil
            guard !self.isMouseInsideHoverRegion() else { return }
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

        guard !shouldReduceMotion, let screen = previewWindow.screen ?? activePreviewScreen ?? targetScreen() else {
            orderOutPreviewWindow(previewWindow)
            setPreviewContentVisible(false, animated: false)
            previewWindow.alphaValue = 1
            previewWindow.hasShadow = true
            activePreviewScreen = nil
            menuStore.providerStore.prepareForPanelClose()
            return
        }

        let frames = panelFrames(on: screen)
        previewWindow.hasShadow = false
        previewWindow.ignoresMouseEvents = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = PanelAnimationTiming.previewCloseDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.72, 0.0, 0.82, 0.04)
            previewWindow.animator().setFrame(frames.collapsedPreview, display: true)
            previewWindow.animator().alphaValue = 0
        } completionHandler: { [weak self, weak previewWindow] in
            Task { @MainActor in
                guard let self, let previewWindow, self.previewAnimationToken == token else { return }
                self.resetTask?.cancel()
                self.resetTask = nil
                self.resetClosedPreviewWindow(previewWindow, frame: frames.preview)
            }
        }

        let task = DispatchWorkItem { [weak self, weak previewWindow] in
            Task { @MainActor in
                guard let self, let previewWindow, self.previewAnimationToken == token else { return }
                self.resetClosedPreviewWindow(previewWindow, frame: frames.preview)
            }
        }
        resetTask?.cancel()
        resetTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelAnimationTiming.previewCloseDuration + 0.03, execute: task)
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
        setPreviewContentVisible(false, animated: false)
        previewWindow.alphaValue = 1
        previewWindow.hasShadow = true
        previewWindow.invalidateShadow()
        previewWindow.ignoresMouseEvents = false
        previewWindow.setFrame(frame, display: false)
    }

    private func orderOutPreviewWindow(_ previewWindow: NSPanel) {
        VoiceLaneRuntime.shared.detachPanel()
        previewWindow.orderOut(nil)
    }

    private func isMouseInsideHoverRegion() -> Bool {
        let location = NSEvent.mouseLocation
        let accessContainsMouse = accessWindows.values.contains { $0.frame.insetBy(dx: -4, dy: -4).contains(location) }
        let previewContainsMouse = previewWindow?.frame.insetBy(dx: -4, dy: -4).contains(location) ?? false
        return accessContainsMouse || previewContainsMouse
    }

    private func startHoverMonitor() {
        guard hoverMonitorTimer == nil else { return }

        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.closeIfMouseLeftHoverRegion()
            }
        }
        timer.tolerance = 0.04
        hoverMonitorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopHoverMonitor() {
        hoverMonitorTimer?.invalidate()
        hoverMonitorTimer = nil
    }

    private func closeIfMouseLeftHoverRegion() {
        guard previewWindow?.isVisible == true,
              closeTask == nil,
              TimerStore.shared.activeAlert == nil,
              !isMouseInsideHoverRegion()
        else {
            return
        }

        scheduleClose()
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
        let now = Date()
        if now.timeIntervalSince(lastAccessWindowHealthCheck) >= 2 {
            lastAccessWindowHealthCheck = now
            repairAccessWindowsIfNeeded()
        }

        guard previewWindow?.isVisible != true else { return }

        let mouseLocation = NSEvent.mouseLocation
        for screen in accessScreens() {
            guard let accessWindow = accessWindows[screenKey(screen)],
                  accessWindow.isVisible,
                  accessWindow.frame.contains(mouseLocation)
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
        let screens = accessScreens()
        guard screens.count == accessWindows.count else { return false }

        for screen in screens {
            let key = screenKey(screen)
            let expected = panelFrames(on: screen)
            guard let accessWindow = accessWindows[key],
                  accessWindowStyles[key] == expected.accessStyle,
                  accessWindow.isVisible,
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
        let screens = accessScreens()
        let desiredKeys = Set(screens.map(screenKey))

        let obsoleteKeys = accessWindows.keys.filter { !desiredKeys.contains($0) }
        for key in obsoleteKeys {
            accessWindows[key]?.orderOut(nil)
            accessWindows.removeValue(forKey: key)
            accessWindowStyles.removeValue(forKey: key)
        }

        for screen in screens {
            let key = screenKey(screen)
            let frames = panelFrames(on: screen)

            if accessWindows[key] == nil || accessWindowStyles[key] != frames.accessStyle {
                accessWindows[key]?.orderOut(nil)
                accessWindows[key] = configureAccessWindow(for: screen)
                accessWindowStyles[key] = frames.accessStyle
            }

            accessWindows[key]?.setFrame(frames.access, display: true)
            if orderFront {
                accessWindows[key]?.orderFrontRegardless()
            }
        }
    }

    private func accessScreens() -> [NSScreen] {
        switch settings.displayPlacementMode {
        case .allDisplays:
            return NSScreen.screens.sorted { lhs, rhs in
                if lhs.frame.minX == rhs.frame.minX {
                    return lhs.frame.minY < rhs.frame.minY
                }
                return lhs.frame.minX < rhs.frame.minX
            }
        case .mainDisplay, .secondaryDisplay:
            return targetScreen().map { [$0] } ?? []
        }
    }

    private func screenKey(_ screen: NSScreen) -> String {
        if let displayID = screen.displayID {
            return String(displayID)
        }

        return "\(screen.frame.origin.x),\(screen.frame.origin.y),\(screen.frame.width),\(screen.frame.height)"
    }

    private func targetScreen() -> NSScreen? {
        switch settings.displayPlacementMode {
        case .mainDisplay:
            return mainDisplay()
        case .secondaryDisplay:
            return secondaryDisplay() ?? mainDisplay()
        case .allDisplays:
            return screenContainingMouse() ?? mainDisplay()
        }
    }

    private func screenContainingMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
    }

    private func mainDisplay() -> NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func secondaryDisplay() -> NSScreen? {
        guard let mainDisplay = mainDisplay() else { return NSScreen.screens.first }

        let secondaryScreens = NSScreen.screens.filter { !isSameDisplay($0, mainDisplay) }
        guard !secondaryScreens.isEmpty else { return nil }

        if let mouseScreen = screenContainingMouse(),
           secondaryScreens.contains(where: { isSameDisplay($0, mouseScreen) }) {
            return mouseScreen
        }

        return secondaryScreens.sorted { lhs, rhs in
            if lhs.frame.minX == rhs.frame.minX {
                return lhs.frame.minY < rhs.frame.minY
            }
            return lhs.frame.minX < rhs.frame.minX
        }.first
    }

    private func isSameDisplay(_ lhs: NSScreen, _ rhs: NSScreen) -> Bool {
        if let lhsID = lhs.displayID, let rhsID = rhs.displayID {
            return lhsID == rhsID
        }

        return lhs === rhs
    }

    private func isSecondaryDisplay(_ screen: NSScreen) -> Bool {
        guard let mainDisplay = mainDisplay() else { return false }
        return !isSameDisplay(screen, mainDisplay)
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

    private func processTaskSnapshot() throws -> (threadCount: Int, residentMiB: Double) {
        var info = proc_taskinfo()
        let expectedSize = MemoryLayout<proc_taskinfo>.size
        let readSize = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                getpid(),
                PROC_PIDTASKINFO,
                0,
                pointer,
                Int32(expectedSize)
            )
        }
        guard readSize == expectedSize else {
            throw PanelSoakVerificationError.failed("panel_soak_task_readback_failed")
        }
        return (
            Int(info.pti_threadnum),
            Double(info.pti_resident_size) / 1_048_576
        )
    }

    private func processSocketCount() throws -> Int {
        errno = 0
        let requiredSize = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard requiredSize >= 0, requiredSize > 0 || errno == 0 else {
            throw PanelSoakVerificationError.failed("panel_soak_socket_readback_failed")
        }
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: max(1, Int(requiredSize) / MemoryLayout<proc_fdinfo>.size)
        )
        errno = 0
        let readSize = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(
                getpid(),
                PROC_PIDLISTFDS,
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard readSize >= 0, readSize > 0 || errno == 0 else {
            throw PanelSoakVerificationError.failed("panel_soak_socket_readback_failed")
        }
        let count = Int(readSize) / MemoryLayout<proc_fdinfo>.size
        return descriptors.prefix(count).filter { $0.proc_fdtype == PROX_FDTYPE_SOCKET }.count
    }

    private func childProcessCount() throws -> Int {
        errno = 0
        let requiredSize = proc_listpids(
            UInt32(PROC_PPID_ONLY),
            UInt32(getpid()),
            nil,
            0
        )
        guard requiredSize >= 0, requiredSize > 0 || errno == 0 else {
            throw PanelSoakVerificationError.failed("panel_soak_child_readback_failed")
        }
        var processIdentifiers = [pid_t](
            repeating: 0,
            count: max(1, Int(requiredSize) / MemoryLayout<pid_t>.size)
        )
        errno = 0
        let readSize = processIdentifiers.withUnsafeMutableBytes { buffer in
            proc_listpids(
                UInt32(PROC_PPID_ONLY),
                UInt32(getpid()),
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard readSize >= 0, readSize > 0 || errno == 0 else {
            throw PanelSoakVerificationError.failed("panel_soak_child_readback_failed")
        }
        let count = Int(readSize) / MemoryLayout<pid_t>.size
        return processIdentifiers.prefix(count).filter { $0 > 0 }.count
    }

    private func setPreviewContentVisible(_ isVisible: Bool, animated: Bool) {
        guard menuStore.contentVisible != isVisible else { return }

        guard animated else {
            menuStore.contentVisible = isVisible
            return
        }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            menuStore.contentVisible = isVisible
        }
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
                openPanel(showing: TimerProvider.pluginID)
            }
            .store(in: &settingsCancellables)
    }

    private func resizePreviewForPanelSizeChange() {
        syncAccessWindows(orderFront: false)
        guard let screen = activePreviewScreen ?? previewWindow?.screen ?? targetScreen() else { return }
        applyResolvedVoiceLaneLayout(on: screen)
        let frames = panelFrames(on: screen)

        guard let previewWindow else { return }
        guard previewWindow.isVisible else {
            previewWindow.setFrame(frames.preview, display: false)
            return
        }

        resetTask?.cancel()
        resetTask = nil
        previewAnimationToken += 1
        let token = previewAnimationToken

        guard !shouldReduceMotion else {
            previewWindow.setFrame(frames.preview, display: true)
            return
        }

        previewWindow.hasShadow = false
        previewWindow.invalidateShadow()

        animatePreviewResize(
            previewWindow,
            from: previewWindow.frame,
            to: frames.preview,
            token: token
        )
    }

    private func animatePreviewResize(
        _ previewWindow: NSPanel,
        from _: NSRect,
        to targetFrame: NSRect,
        token: Int
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.34
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.92, 0.28, 1.0)
            previewWindow.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self, weak previewWindow] in
            Task { @MainActor in
                guard let self,
                      let previewWindow,
                      self.previewAnimationToken == token
                else {
                    return
                }

                previewWindow.setFrame(targetFrame, display: true)
                previewWindow.hasShadow = true
                previewWindow.invalidateShadow()
            }
        }
    }
}
