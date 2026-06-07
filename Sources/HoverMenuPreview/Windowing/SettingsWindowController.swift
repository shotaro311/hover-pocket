import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let settings: AppSettings
    private let providerStore: ProviderStore
    private var window: NSWindow?

    init(settings: AppSettings, providerStore: ProviderStore) {
        self.settings = settings
        self.providerStore = providerStore
    }

    func show() {
        if window == nil {
            window = makeWindow()
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: SettingsView(settings: settings, providerStore: providerStore)
        )
        return window
    }
}
