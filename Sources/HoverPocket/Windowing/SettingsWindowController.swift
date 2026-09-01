import AppKit
import Combine
import SwiftUI

enum SettingsWindowLayout {
    static let preferredContentSize = NSSize(width: 620, height: 700)
    static let minimumContentSize = NSSize(width: 520, height: 480)
    static let screenMargin: CGFloat = 24
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable]

    static func contentSize(limitedTo maximumContentSize: NSSize) -> NSSize {
        NSSize(
            width: min(preferredContentSize.width, max(1, maximumContentSize.width)),
            height: min(preferredContentSize.height, max(1, maximumContentSize.height))
        )
    }

    static func minimumContentSize(limitedTo contentSize: NSSize) -> NSSize {
        NSSize(
            width: min(minimumContentSize.width, contentSize.width),
            height: min(minimumContentSize.height, contentSize.height)
        )
    }
}

@MainActor
final class SettingsWindowController {
    private let settings: AppSettings
    private let providerStore: ProviderStore
    private var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings, providerStore: ProviderStore) {
        self.settings = settings
        self.providerStore = providerStore
        observeSettings()
    }

    func show() {
        if window == nil {
            window = makeWindow()
        } else if let window,
                  let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first {
            window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(origin: .zero, size: SettingsWindowLayout.preferredContentSize)
        let availableFrame = visibleFrame.insetBy(
            dx: SettingsWindowLayout.screenMargin,
            dy: SettingsWindowLayout.screenMargin
        )
        let maximumContentSize = NSWindow.contentRect(
            forFrameRect: availableFrame,
            styleMask: SettingsWindowLayout.styleMask
        ).size
        let contentSize = SettingsWindowLayout.contentSize(limitedTo: maximumContentSize)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: SettingsWindowLayout.styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = settings.text(.settingsWindowTitle)
        window.isReleasedWhenClosed = false
        window.contentMinSize = SettingsWindowLayout.minimumContentSize(limitedTo: contentSize)
        let hostingController = NSHostingController(
            rootView: SettingsView(settings: settings, providerStore: providerStore)
        )
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        window.setContentSize(contentSize)
        window.center()
        return window
    }

    private func observeSettings() {
        settings.$appLanguage
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.window?.title = self.settings.text(.settingsWindowTitle)
            }
            .store(in: &cancellables)
    }
}
