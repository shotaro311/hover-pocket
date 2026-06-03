import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class HoverWindowController {
    private var pillWindow: NSPanel?
    private var previewWindow: NSPanel?
    private var closeTask: DispatchWorkItem?
    private var revealTask: DispatchWorkItem?
    private var previewAnimationToken = 0
    private let settings: AppSettings
    private let menuStore: HoverMenuStore
    private let settingsWindowController: SettingsWindowController
    private var settingsCancellable: AnyCancellable?

    init() {
        let settings = AppSettings()
        self.settings = settings
        self.menuStore = HoverMenuStore(settings: settings)
        self.settingsWindowController = SettingsWindowController(settings: settings)

        configurePillWindow()
        configurePreviewWindow()
        observeSettings()
    }

    func showPill() {
        pillWindow?.orderFrontRegardless()
    }

    func positionWindows() {
        guard let screen = targetScreen() else { return }

        let frames = PanelGeometry.frames(on: screen)
        pillWindow?.setFrame(frames.pill, display: true)

        if previewWindow?.isVisible == true {
            previewWindow?.setFrame(frames.preview, display: true)
        } else {
            previewWindow?.setFrame(frames.preview, display: false)
        }
    }

    private func configurePillWindow() {
        let panel = makePanel(size: NSSize(width: PanelLayout.defaultPillWidth, height: PanelLayout.pillHeight))
        panel.hasShadow = false
        panel.contentViewController = NSHostingController(
            rootView: HoverPillView(
                onEnter: { [weak self] in self?.showPreview() },
                onExit: { [weak self] in self?.scheduleClose() },
                onTap: { [weak self] in self?.togglePreview() }
            )
        )
        pillWindow = panel
    }

    private func configurePreviewWindow() {
        let hoverState = HoverState(
            onEnter: { [weak self] in self?.cancelClose() },
            onExit: { [weak self] in self?.scheduleClose() }
        )

        let panel = makePanel(size: PanelLayout.previewSize)
        panel.hasShadow = true
        panel.contentViewController = NSHostingController(
            rootView: HoverPanelShell(
                hoverState: hoverState,
                store: menuStore,
                onOpenSettings: { [weak self] in self?.showSettings() }
            )
        )
        previewWindow = panel
    }

    private func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        return panel
    }

    private func togglePreview() {
        if previewWindow?.isVisible == true {
            closePreview()
        } else {
            showPreview()
        }
    }

    private func showSettings() {
        cancelClose()
        settingsWindowController.show()
        closePreview()
    }

    private func showPreview() {
        cancelClose()

        guard let screen = targetScreen(), let previewWindow else { return }
        let frames = PanelGeometry.frames(on: screen)
        pillWindow?.setFrame(frames.pill, display: true)
        menuStore.providerStore.refreshSelected(reason: .panelOpened)

        previewAnimationToken += 1
        let token = previewAnimationToken
        revealTask?.cancel()

        if previewWindow.isVisible, previewWindow.alphaValue > 0.98 {
            previewWindow.ignoresMouseEvents = false
            previewWindow.setFrame(frames.preview, display: true)
            setPreviewContentVisible(true, animated: true)
            return
        }

        setPreviewContentVisible(false, animated: false)
        previewWindow.alphaValue = shouldReduceMotion ? 1 : 0.9
        previewWindow.ignoresMouseEvents = true
        previewWindow.setFrame(shouldReduceMotion ? frames.preview : frames.collapsedPreview, display: true)
        previewWindow.orderFrontRegardless()

        if shouldReduceMotion {
            previewWindow.ignoresMouseEvents = false
            setPreviewContentVisible(true, animated: false)
            return
        }

        revealPreviewContent(after: PanelAnimationTiming.contentRevealDelay)

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
                previewWindow.ignoresMouseEvents = false
            }
        }
    }

    private func scheduleClose() {
        closeTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, !self.isMouseInsideHoverRegion() else { return }
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
        revealTask?.cancel()
        guard let previewWindow, previewWindow.isVisible else { return }

        previewAnimationToken += 1
        let token = previewAnimationToken

        guard !shouldReduceMotion, let screen = previewWindow.screen ?? targetScreen() else {
            setPreviewContentVisible(false, animated: false)
            previewWindow.orderOut(nil)
            previewWindow.alphaValue = 1
            return
        }

        let frames = PanelGeometry.frames(on: screen)
        previewWindow.ignoresMouseEvents = true
        hidePreviewContent(
            after: PanelAnimationTiming.previewCloseDuration - PanelAnimationTiming.contentHideLeadTime,
            token: token
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = PanelAnimationTiming.previewCloseDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.72, 0.0, 0.82, 0.04)
            previewWindow.animator().setFrame(frames.collapsedPreview, display: true)
            previewWindow.animator().alphaValue = 0
        } completionHandler: { [weak self, weak previewWindow] in
            Task { @MainActor in
                guard let self, let previewWindow, self.previewAnimationToken == token else { return }
                self.resetClosedPreviewWindow(previewWindow, frame: frames.preview)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + PanelAnimationTiming.previewCloseDuration + 0.03) { [weak self, weak previewWindow] in
            Task { @MainActor in
                guard let self, let previewWindow, self.previewAnimationToken == token else { return }
                self.resetClosedPreviewWindow(previewWindow, frame: frames.preview)
            }
        }
    }

    private func resetClosedPreviewWindow(_ previewWindow: NSPanel, frame: NSRect) {
        setPreviewContentVisible(false, animated: false)
        previewWindow.orderOut(nil)
        previewWindow.alphaValue = 1
        previewWindow.ignoresMouseEvents = false
        previewWindow.setFrame(frame, display: false)
    }

    private func isMouseInsideHoverRegion() -> Bool {
        let location = NSEvent.mouseLocation
        let pillContainsMouse = pillWindow?.frame.insetBy(dx: -4, dy: -4).contains(location) ?? false
        let previewContainsMouse = previewWindow?.frame.insetBy(dx: -4, dy: -4).contains(location) ?? false
        return pillContainsMouse || previewContainsMouse
    }

    private func targetScreen() -> NSScreen? {
        switch settings.displayPlacementMode {
        case .automatic:
            return screenContainingMouse() ?? mainDisplay()
        case .mainDisplay:
            return mainDisplay()
        case .secondaryDisplay:
            return secondaryDisplay() ?? mainDisplay()
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

    private var shouldReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func revealPreviewContent(after delay: TimeInterval) {
        let task = DispatchWorkItem { [weak self] in
            self?.setPreviewContentVisible(true, animated: true)
        }
        revealTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func hidePreviewContent(after delay: TimeInterval, token: Int) {
        let task = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.previewAnimationToken == token else { return }
                self.setPreviewContentVisible(false, animated: true)
            }
        }
        revealTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func setPreviewContentVisible(_ isVisible: Bool, animated: Bool) {
        guard animated else {
            menuStore.contentVisible = isVisible
            return
        }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            menuStore.contentVisible = isVisible
        }
    }

    private func observeSettings() {
        settingsCancellable = settings.$displayPlacementMode
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                closePreview()
                positionWindows()
            }
    }
}
