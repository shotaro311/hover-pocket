import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hoverWindowController = HoverWindowController()
    private var statusBarMenuController: StatusBarMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
    }

    @objc private func screenParametersChanged() {
        hoverWindowController.positionWindows()
        hoverWindowController.showPill()
    }

    @objc private func applicationBecameActive() {
        MirrorCameraModel.shared.recheckPermissionAfterExternalChange()
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
}
