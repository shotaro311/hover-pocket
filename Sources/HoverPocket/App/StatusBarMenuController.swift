import AppKit
import Combine

@MainActor
final class StatusBarMenuController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settings: AppSettings
    private let onOpenPanel: () -> Void
    private let onOpenSettings: () -> Void
    private let onCheckForUpdates: () -> Void
    private let onQuit: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(
        settings: AppSettings,
        onOpenPanel: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.settings = settings
        self.onOpenPanel = onOpenPanel
        self.onOpenSettings = onOpenSettings
        self.onCheckForUpdates = onCheckForUpdates
        self.onQuit = onQuit
        super.init()

        configureButton()
        configureMenu()
        observeSettings()
        AssetCaptureController.shared.$recording.sink { [weak self] recording in
            self?.statusItem.button?.title = recording ? " ●" : ""
            self?.statusItem.button?.contentTintColor = recording ? .systemRed : nil
            self?.statusItem.button?.toolTip = recording ? "HoverPocket — 画面収録中（\(AssetCaptureController.shared.preferences.recordingShortcut)で停止）" : "HoverPocket"
        }.store(in: &cancellables)
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.menuBarImage()
        button.imagePosition = .imageOnly
        button.toolTip = "HoverPocket"
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.addItem(menuItem(title: settings.text(.openHoverPocket), action: #selector(openPanel)))
        menu.addItem(menuItem(title: "素材ライブラリを開く", action: #selector(openAssets)))
        menu.addItem(menuItem(title: "スクリーンショットを撮影", action: #selector(captureScreenshot)))
        menu.addItem(menuItem(title: "収録を開始／停止して保存", action: #selector(toggleRecording)))
        menu.addItem(menuItem(title: "撮影・収録の設定…", action: #selector(captureSettings)))
        menu.addItem(menuItem(title: settings.text(.settings), action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(menuItem(title: settings.text(.checkForUpdates), action: #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: settings.text(.quitHoverPocket), action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func observeSettings() {
        settings.$appLanguage
            .dropFirst()
            .sink { [weak self] _ in
                self?.configureMenu()
            }
            .store(in: &cancellables)
    }

    private func menuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private static func menuBarImage() -> NSImage? {
        let size = NSSize(width: 18, height: 18)
        guard let source = NSApp.applicationIconImage ?? NSImage(named: "AppIcon") else {
            return NSImage(systemSymbolName: "rectangle.inset.filled.and.person.filled", accessibilityDescription: "HoverPocket")
        }

        let image = NSImage(size: size)
        image.lockFocus()
        source.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: source.size),
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    @objc private func openPanel() {
        onOpenPanel()
    }

    @objc private func openAssets() { AssetLibraryRuntime.shared.showOrganizer() }
    @objc private func captureScreenshot() { Task { await AssetCaptureController.shared.screenshot(folder: nil) } }
    @objc private func toggleRecording() { Task { await AssetCaptureController.shared.toggleRecording(folder: nil) } }
    @objc private func captureSettings() { AssetCaptureController.shared.showSettings() }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates()
    }

    @objc private func quit() {
        onQuit()
    }
}
