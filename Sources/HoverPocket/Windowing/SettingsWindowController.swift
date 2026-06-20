import AppKit
import Combine
import SwiftUI

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
        window.title = settings.text(.settingsWindowTitle)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: SettingsView(settings: settings, providerStore: providerStore)
        )
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
