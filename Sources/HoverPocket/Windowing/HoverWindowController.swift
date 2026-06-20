import AppKit
import Combine
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
    private var mouseEventsEnableTask: DispatchWorkItem?
    private var previewAnimationToken = 0
    private let settings: AppSettings
    private let menuStore: HoverMenuStore
    private let settingsWindowController: SettingsWindowController
    private var settingsCancellables = Set<AnyCancellable>()

    var appSettings: AppSettings {
        settings
    }

    init() {
        let settings = AppSettings()
        let menuStore = HoverMenuStore(settings: settings)
        self.settings = settings
        self.menuStore = menuStore
        self.settingsWindowController = SettingsWindowController(
            settings: settings,
            providerStore: menuStore.providerStore
        )

        syncAccessWindows(orderFront: false)
        configurePreviewWindow()
        observeSettings()
    }

    func showPill() {
        syncAccessWindows(orderFront: true)
    }

    func positionWindows() {
        syncAccessWindows(orderFront: false)
        guard let screen = activePreviewScreen ?? targetScreen() else { return }

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

    func openSettingsFromMenu() {
        showSettings()
    }

    private func panelFrames(on screen: NSScreen) -> PanelFrames {
        PanelGeometry.frames(
            on: screen,
            panelSize: settings.panelSize,
            showsNotchSideHandleArea: settings.showNotchSideHandleArea
        )
    }

    private func configureAccessWindow(for screen: NSScreen) -> NSPanel {
        let frames = panelFrames(on: screen)
        let panel = makePanel(
            size: frames.access.size,
            acceptsKeyboardFocus: false
        )
        panel.hasShadow = false
        panel.contentViewController = NSHostingController(rootView: accessView(for: screen, style: frames.accessStyle))
        panel.setFrame(frames.access, display: false)
        return panel
    }

    private func accessView(for screen: NSScreen, style: PanelAccessStyle) -> AnyView {
        switch style {
        case .notchPill:
            return AnyView(
                HoverPillView(
                    settings: settings,
                    onEnter: { [weak self] in self?.showPreview(on: screen) },
                    onExit: { [weak self] in self?.scheduleClose() },
                    onTap: { [weak self] in self?.togglePreview(on: screen) }
                )
            )
        case .miniBar:
            return AnyView(
                HoverMiniBarView(
                    onBarEnter: { [weak self] in self?.showPreview(on: screen) },
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

        let panel = makePanel(size: PanelLayout.previewSize(for: settings.panelSize), acceptsKeyboardFocus: true)
        panel.hasShadow = true
        panel.contentViewController = NSHostingController(
            rootView: HoverPanelShell(
                hoverState: hoverState,
                store: menuStore,
                settings: settings,
                onOpenSettings: { [weak self] in self?.showSettings() },
                onExternalDragStarted: { [weak self] in self?.prepareForExternalDrag() }
            )
        )
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
        previewWindow.orderOut(nil)
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
            previewWindow.orderOut(nil)
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
        previewWindow.orderOut(nil)
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

    private func isMouseInsideHoverRegion() -> Bool {
        let location = NSEvent.mouseLocation
        let accessContainsMouse = accessWindows.values.contains { $0.frame.insetBy(dx: -4, dy: -4).contains(location) }
        let previewContainsMouse = previewWindow?.frame.insetBy(dx: -4, dy: -4).contains(location) ?? false
        return accessContainsMouse || previewContainsMouse
    }

    private func startHoverMonitor() {
        guard hoverMonitorTimer == nil else { return }

        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.closeIfMouseLeftHoverRegion()
            }
        }
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
              !isMouseInsideHoverRegion()
        else {
            return
        }

        scheduleClose()
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
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
    }

    private func resizePreviewForPanelSizeChange() {
        syncAccessWindows(orderFront: false)
        guard let screen = activePreviewScreen ?? previewWindow?.screen ?? targetScreen() else { return }
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
