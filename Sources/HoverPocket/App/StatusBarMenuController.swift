import AppKit

@MainActor
final class StatusBarMenuController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let onOpenPanel: () -> Void
    private let onOpenSettings: () -> Void
    private let onCheckForUpdates: () -> Void
    private let onQuit: () -> Void

    init(
        onOpenPanel: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onOpenPanel = onOpenPanel
        self.onOpenSettings = onOpenSettings
        self.onCheckForUpdates = onCheckForUpdates
        self.onQuit = onQuit
        super.init()

        configureButton()
        configureMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.menuBarImage()
        button.imagePosition = .imageOnly
        button.toolTip = "HoverPocket"
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.addItem(menuItem(title: "Open HoverPocket", action: #selector(openPanel)))
        menu.addItem(menuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(menuItem(title: "Check for Updates", action: #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit HoverPocket", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
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
