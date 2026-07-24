import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hoverWindowController = HoverWindowController()
    private var statusBarMenuController: StatusBarMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        registerURLSchemeCallbackHandler()
        statusBarMenuController = StatusBarMenuController(
            settings: hoverWindowController.appSettings,
            onOpenPanel: { [weak self] in
                self?.hoverWindowController.openPanelFromMenu()
            },
            onOpenSettings: { [weak self] in
                self?.hoverWindowController.openSettingsFromMenu()
            },
            onCheckForUpdates: {
                AppUpdater.shared.checkForUpdates()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
        MirrorCameraModel.shared.prepareIfAuthorized()
        _ = AppUpdater.shared
        hoverWindowController.positionWindows()
        hoverWindowController.showPill()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceSessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged() {
        hoverWindowController.recoverAfterSystemTransition()
    }

    @objc private func applicationBecameActive() {
        MirrorCameraModel.shared.recheckPermissionAfterExternalChange()
        hoverWindowController.ensureAccessWindowsAvailable()
    }

    @objc private func workspaceDidWake() {
        hoverWindowController.recoverAfterSystemTransition()
    }

    @objc private func workspaceSessionDidBecomeActive() {
        hoverWindowController.recoverAfterSystemTransition()
    }

    private func registerURLSchemeCallbackHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard
            let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: urlString)
        else {
            return
        }

        OAuthURLCallbackCoordinator.shared.handle(url)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "HoverPocket")
        appMenu.addItem(NSMenuItem(title: "Quit HoverPocket", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(menuItem("Undo", action: "undo:", key: "z"))
        editMenu.addItem(menuItem("Redo", action: "redo:", key: "Z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem("Cut", action: "cut:", key: "x"))
        editMenu.addItem(menuItem("Copy", action: "copy:", key: "c"))
        editMenu.addItem(menuItem("Paste", action: "paste:", key: "v"))
        editMenu.addItem(menuItem("Paste and Match Style", action: "pasteAsPlainText:", key: "V", modifiers: [.command, .option, .shift]))
        editMenu.addItem(menuItem("Delete", action: "delete:", key: ""))
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem("Select All", action: "selectAll:", key: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func menuItem(
        _ title: String,
        action: String,
        key: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = nil
        return item
    }
}
