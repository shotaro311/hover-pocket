import AppKit
import Carbon
import Combine

struct VoiceRuntimeSettingsConfiguration: Equatable {
    let featureEnabled: Bool
    let preferredLayout: VoiceLaneLayoutPreference
    let providerID: VoiceProviderID
}

@MainActor
func voiceRuntimeSettingsPublisher(
    settings: AppSettings
) -> AnyPublisher<VoiceRuntimeSettingsConfiguration, Never> {
    Publishers.CombineLatest3(
        settings.$voiceEnabled.removeDuplicates(),
        settings.$voiceLaneLayoutPreference.removeDuplicates(),
        settings.$voiceProvider.removeDuplicates()
    )
    .map { featureEnabled, preferredLayout, providerID in
        VoiceRuntimeSettingsConfiguration(
            featureEnabled: featureEnabled,
            preferredLayout: preferredLayout,
            providerID: providerID
        )
    }
    .eraseToAnyPublisher()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hoverWindowController = HoverWindowController()
    private var statusBarMenuController: StatusBarMenuController?
    private var settingsCancellables = Set<AnyCancellable>()
    private var voiceConfigurationTask: Task<Void, Never>?
    private var voiceTerminationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureAINativeRuntimeIfEnabled()
        observeAINativeRuntimeSetting()
        configureVoiceRuntime()
        observeVoiceRuntimeSettings()
        observeVoiceE2EReceipt()
        installMainMenu()
        if HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled {
            registerURLSchemeCallbackHandler()
        }
        statusBarMenuController = StatusBarMenuController(
            settings: hoverWindowController.appSettings,
            onOpenPanel: { [weak self] in
                self?.hoverWindowController.openPanelFromMenu()
            },
            onOpenSettings: { [weak self] in
                self?.hoverWindowController.openSettingsFromMenu()
            },
            onCheckForUpdates: {
                guard HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled else {
                    return
                }
                AppUpdater.shared.checkForUpdates()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
        if HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled {
            MirrorCameraModel.shared.prepareIfAuthorized()
            _ = AppUpdater.shared
        }
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

    private func configureAINativeRuntimeIfEnabled() {
        let runtimeEnvironment = HoverPocketRuntimeEnvironment.shared
        let savedGeneratedProviderIDs = hoverWindowController.appSettings.savedGeneratedProviderIDs
        do {
            let brokerRoot = runtimeEnvironment.storageDirectory("CapabilityBroker")
            let ledger = try CapabilityBrokerLedger(rootDirectory: brokerRoot)
            let auditLog = try CapabilityBrokerAuditLog(rootDirectory: brokerRoot)
            let governanceController = CapabilityDataGovernanceController(
                ledger: ledger,
                auditLog: auditLog
            )
            _ = try governanceController.applyRetention(
                hoverWindowController.appSettings.capabilityDataRetentionPeriod
            )
            let handlers = try ProviderCapabilityCompositionRoot.live(
                calendarDataSource: GoogleCalendarCapabilityDataSource()
            )
            let registry = try CapabilityRegistry(handlers: handlers)
            let broker = CapabilityBroker(
                registry: registry,
                ledger: ledger,
                auditLog: auditLog,
                approvalPresentationResolver: HostCapabilityApprovalPresentationResolver(
                    stickyStore: .shared
                )
            )
            let voiceCapabilityContext = VoiceCapabilityContext(
                registry: registry,
                broker: broker
            )
            guard hoverWindowController.appSettings.aiNativeEnabled,
                  runtimeEnvironment.externalIntegrationsEnabled else {
                AINativeRuntime.shared.configure(
                    adapter: nil,
                    capabilityDataGovernanceController: governanceController,
                    voiceCapabilityContext: voiceCapabilityContext,
                    preservingManagedGeneratedProviderIDs: savedGeneratedProviderIDs
                )
                return
            }
            guard let resources = Bundle.module.resourceURL else {
                throw PocketAppPackageError.invalid("$:resources")
            }
            let packageRoot = resources
                .appendingPathComponent("PocketApps", isDirectory: true)
                .appendingPathComponent("local.example.today-focus", isDirectory: true)
            let package = try PocketAppPackageRuntime().load(directory: packageRoot)
            let pocketAppsRoot = runtimeEnvironment.storageDirectory("PocketApps")
            let userDataRoot = pocketAppsRoot.appendingPathComponent("UserData", isDirectory: true)
            let userStateStore = try PocketAppUserStateStore(
                packageID: package.manifest.id,
                stateProperties: package.stateProperties,
                rootDirectory: userDataRoot
            )
            let builtInActivationLease = PocketAppActivationLease()
            let pocketAppRuntime = PocketAppExecutionRuntime(
                package: package,
                broker: broker,
                userID: "local-user",
                grantedPermissions: [
                    "calendar.events.read",
                    "sticky.read",
                    "sticky.write",
                    "timer.read",
                    "timer.write"
                ],
                userStateStore: userStateStore,
                activationLease: builtInActivationLease
            )
            let generationController: PocketAppGenerationController?
            let generatedActivationRegistry: PocketAppRuntimeActivationRegistry?
            do {
                let generationRoot = pocketAppsRoot.appendingPathComponent("Generation", isDirectory: true)
                let generatedHostRoot = pocketAppsRoot.appendingPathComponent("GeneratedHost", isDirectory: true)
                let activationRegistry = try PocketAppRuntimeActivationRegistry(
                    rootDirectory: generatedHostRoot,
                    userDataRoot: userDataRoot,
                    broker: broker,
                    userID: "local-user"
                )
                _ = activationRegistry.restoreEnabledApps()
                let generator: (any PocketAppGenerationAdapter)?
                if let executableURL = CodexPocketAppGenerationAdapter.resolveExecutable() {
                    let credentialStore = OpenAIRealtimeKeychainStore()
                    generator = try? CodexPocketAppGenerationAdapter(
                        executableURL: executableURL,
                        workspaceRoot: generationRoot.appendingPathComponent("CodexWorkspaces", isDirectory: true),
                        credentialProvider: {
                            guard let apiKey = try credentialStore.load() else {
                                throw PocketAppGenerationError.generatorUnavailable
                            }
                            return try apiKey.withUTF8Bytes { bytes in
                                guard let value = String(data: bytes, encoding: .utf8) else {
                                    throw PocketAppGenerationError.generatorUnavailable
                                }
                                return value
                            }
                        }
                    )
                } else {
                    generator = nil
                }
                let appSettings = hoverWindowController.appSettings
                generationController = try PocketAppGenerationController(
                    rootDirectory: generatedHostRoot,
                    userDataRoot: userDataRoot,
                    generationRoot: generationRoot.appendingPathComponent("Drafts", isDirectory: true),
                    generator: generator,
                    runtimeActivationReadback: { receipt in
                        let readback = try activationRegistry.synchronize(receipt)
                        if receipt.state == .removed {
                            let providerID = PocketSurfaceRegistry.generatedProviderID(
                                appID: receipt.packageID
                            )
                            appSettings.pruneProviderConfiguration(PluginID(rawValue: providerID))
                            AINativeRuntime.shared.forgetManagedGeneratedProviderID(providerID)
                        }
                        return readback
                    }
                )
                generatedActivationRegistry = activationRegistry
            } catch {
                generationController = nil
                generatedActivationRegistry = nil
            }
            AINativeRuntime.shared.configure(
                adapter: TodayFocusTextAdapter(
                    broker: broker,
                    activationLease: builtInActivationLease
                ),
                pocketAppExecutionRuntime: pocketAppRuntime,
                pocketAppGenerationController: generationController,
                generatedActivationRegistry: generatedActivationRegistry,
                builtInActivationLease: builtInActivationLease,
                capabilityDataGovernanceController: governanceController,
                voiceCapabilityContext: voiceCapabilityContext,
                preservingManagedGeneratedProviderIDs: savedGeneratedProviderIDs
            )
        } catch {
            AINativeRuntime.shared.configure(
                adapter: nil,
                preservingManagedGeneratedProviderIDs: savedGeneratedProviderIDs
            )
        }
    }

    private func observeAINativeRuntimeSetting() {
        hoverWindowController.appSettings.$aiNativeEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.configureAINativeRuntimeIfEnabled()
            }
            .store(in: &settingsCancellables)
    }

    private func configureVoiceRuntime(
        configuration: VoiceRuntimeSettingsConfiguration? = nil
    ) {
        let settings = hoverWindowController.appSettings
        let configuration = configuration ?? VoiceRuntimeSettingsConfiguration(
            featureEnabled: settings.voiceEnabled,
            preferredLayout: settings.voiceLaneLayoutPreference,
            providerID: settings.voiceProvider
        )
        VoiceLaneRuntime.shared.setContinueWhenPanelHidden(
            settings.voiceContinueWhenPanelHidden
        )
        voiceConfigurationTask = VoiceLaneRuntime.shared.configure(
            featureEnabled: configuration.featureEnabled,
            preferredLayout: configuration.preferredLayout,
            providerID: configuration.providerID,
            adapterFactory: VoiceProviderAdapterFactory.factory(
                providerID: configuration.providerID,
                settings: settings
            )
        )
    }

    private func observeVoiceRuntimeSettings() {
        let settings = hoverWindowController.appSettings
        voiceRuntimeSettingsPublisher(settings: settings)
            .dropFirst()
            .sink { [weak self] configuration in
                self?.configureVoiceRuntime(configuration: configuration)
            }
            .store(in: &settingsCancellables)
        settings.$voiceCalendarAccessEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { _ in
                VoiceLaneRuntime.shared.capabilityGrantsDidChange()
            }
            .store(in: &settingsCancellables)
        settings.$voiceContinueWhenPanelHidden
            .dropFirst()
            .removeDuplicates()
            .sink { enabled in
                VoiceLaneRuntime.shared.setContinueWhenPanelHidden(enabled)
            }
            .store(in: &settingsCancellables)
    }

    private func observeVoiceE2EReceipt() {
        guard let receiptStore = MacOSVoiceE2EReceiptStore.shared else { return }
        VoiceLaneRuntime.shared.$snapshot
            .sink { snapshot in
                let credentialCurrent = switch snapshot.providerID {
                case .off:
                    false
                case .openAIRealtimeBYOK:
                    (try? OpenAIRealtimeCredentialStoreFactory.shared.hasCredential()) ?? false
                case .codexAppServer:
                    CodexAppServerMacOSRuntime.host.snapshot.availability == .ready
                }
                receiptStore.recordVoiceSnapshot(
                    snapshot,
                    credentialCurrent: credentialCurrent
                )
            }
            .store(in: &settingsCancellables)
    }

    @objc private func screenParametersChanged() {
        hoverWindowController.recoverAfterSystemTransition()
    }

    @objc private func applicationBecameActive() {
        if HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled {
            MirrorCameraModel.shared.recheckPermissionAfterExternalChange()
        }
        hoverWindowController.ensureAccessWindowsAvailable()
    }

    @objc private func workspaceDidWake() {
        VoiceLaneRuntime.shared.recoverAfterSystemTransition()
        AINativeRuntime.shared.recoverAfterSystemTransition()
        hoverWindowController.recoverAfterSystemTransition()
    }

    @objc private func workspaceSessionDidBecomeActive() {
        VoiceLaneRuntime.shared.recoverAfterSystemTransition()
        AINativeRuntime.shared.recoverAfterSystemTransition()
        hoverWindowController.recoverAfterSystemTransition()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard voiceTerminationTask == nil else { return .terminateLater }
        voiceTerminationTask = Task { @MainActor [weak self] in
            await self?.voiceConfigurationTask?.value
            await CodexVoiceAccountLoginController.shared.shutdown()
            await VoiceLaneRuntime.shared.shutdown()
            if HoverPocketRuntimeEnvironment.shared.isIsolatedVoiceE2E {
                try? OpenAIRealtimeCredentialStoreFactory.shared.delete()
                MacOSVoiceE2EReceiptStore.shared?.recordCredentialCurrent(false)
                MacOSVoiceE2EReceiptStore.shared?.recordSafeClose(
                    performanceFlushSynchronously: true
                )
            }
            self?.voiceTerminationTask = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsFromMainMenu),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
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

    @objc private func openSettingsFromMainMenu() {
        hoverWindowController.openSettingsFromMenu()
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
