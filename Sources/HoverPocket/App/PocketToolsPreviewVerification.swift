import AppKit
import SwiftUI

/// Runs the production creation/settings and provider views against an isolated verification workspace.
@MainActor
enum PocketToolsPreviewVerification {
    private static var window: NSWindow?
    private static var panelController: HoverWindowController?

    private struct PanelContent: View {
        @ObservedObject var controller: PocketAppGenerationController
        @ObservedObject var settings: AppSettings
        @ObservedObject var surfaces: PocketSurfaceRegistry
        let open: (PluginID) -> Void
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("実際のホバーパネルで確認").font(.headline)
                    Picker("パネルの大きさ", selection: $settings.panelSize) {
                        ForEach(PanelSizeOption.allCases) { Text($0.title(language: .japanese)).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("文字の大きさ", selection: $settings.panelTextSize) {
                        ForEach(PanelTextSizeOption.allCases) { Text($0.title(language: .japanese)).tag($0) }
                    }.pickerStyle(.segmented)
                    ForEach(surfaces.routes, id: \.providerID) { route in
                        Button(route.title + "をパネルで開く") { open(PluginID(rawValue: route.providerID)) }
                    }
                    Divider()
                    PocketAppGenerationSettingsView(controller: controller, settings: settings, language: .japanese)
                }.padding(20)
            }.frame(minWidth: 600, minHeight: 600)
        }
    }

    /// Uses the real hover window, header, provider routing, model generator, and native stores.
    /// Only storage/defaults are redirected; no fixture replaces the generated UI or its actions.
    static func showPanel(root: URL, initialPackage: URL? = nil) async throws {
        AppDelegate.installMainMenu(settingsTarget: nil, settingsAction: nil)
        guard root.lastPathComponent.hasPrefix("PocketToolsPanel-"),
              root.deletingLastPathComponent().resolvingSymlinksInPath() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath() else {
            throw PocketAppGenerationError.invalidRequest
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let definitions = root.appendingPathComponent("Host")
        let data = root.appendingPathComponent("Data")
        let brokerRoot = root.appendingPathComponent("Broker")
        let timer = TimerStore(storageDirectory: root.appendingPathComponent("Timer"), observesWake: false)
        let sticky = StickyNotesStore(storageDirectory: root.appendingPathComponent("Sticky"))
        let handlers = try PocketCapabilityHandlerSet(handlers: [
            TimerCapabilityHandler(operation: .start, store: timer),
            TimerCapabilityHandler(operation: .get, store: timer),
            StickyCapabilityHandler(operation: .upsert, store: sticky),
            StickyCapabilityHandler(operation: .get, store: sticky)
        ])
        let broker = CapabilityBroker(registry: try CapabilityRegistry(handlers: handlers),
            ledger: try CapabilityBrokerLedger(rootDirectory: brokerRoot), auditLog: try CapabilityBrokerAuditLog(rootDirectory: brokerRoot),
            approvalPresentationResolver: HostCapabilityApprovalPresentationResolver(stickyStore: sticky))
        let registry = try PocketAppRuntimeActivationRegistry(rootDirectory: definitions, userDataRoot: data, broker: broker, userID: "verification")
        _ = registry.restoreEnabledApps()
        let panel = HoverWindowController(settingsDefaults: EphemeralAppSettingsDefaults(),
            providerRegistry: ProviderRegistry(providers: [CalculatorProvider()]))
        let settings = panel.appSettings
        settings.aiNativeEnabled = true
        settings.appLanguage = .japanese
        settings.panelSize = .small
        let generator: any PocketAppGenerationAdapter
        if let initialPackage { generator = CapturedPackage(files: try PocketAppFileSnapshot.capture(directory: initialPackage).files) }
        else { generator = try CodexAppServerPocketGenerator(workspaceRoot: root.appendingPathComponent("Generator")) }
        let controller = try PocketAppGenerationController(rootDirectory: definitions, userDataRoot: data,
            generationRoot: root.appendingPathComponent("Generation"), generator: generator,
            runtimeActivationReadback: { try registry.synchronize($0) }, generationSettings: settings,
            previewFactory: { package, previewRoot in
                var stores: [String: PocketCollectionStore] = [:]
                for (id, schema) in package.collections {
                    stores[id] = try PocketCollectionStore(packageID: package.manifest.id, collectionID: id, schema: schema,
                        rootDirectory: previewRoot.appendingPathComponent(String(package.stateSchemaDigest.dropFirst(7))))
                }
                let runtime = PocketAppExecutionRuntime(package: package, broker: broker, userID: "preview", grantedPermissions: [], collectionStores: stores)
                return try PocketSurfaceHostModel(runtime: runtime, surfaceID: package.surfaces["main"] == nil ? package.surfaces.keys.sorted().first! : "main")
            })
        AINativeRuntime.shared.configure(pocketAppGenerationController: controller, generatedActivationRegistry: registry)
        let window = NSWindow(contentRect: NSRect(x: 160, y: 80, width: 680, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "HoverPocket 本番パネル受入"
        window.contentView = NSHostingView(rootView: PanelContent(controller: controller, settings: settings,
            surfaces: registry.surfaceRegistry, open: { panel.openPanel(showing: $0) }))
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.window = window
        self.panelController = panel
        panel.connectAppController()
        if initialPackage != nil {
            window.orderOut(nil)
            settings.panelTextSize = .extraLarge
            let accepted = await PocketAppOSController.shared.execute(session: "isolated-ui-verification", callID: "preview-request",
                arguments: .object(["operation": .string("generate"), "request": .string("保存済みの実生成ツールを隔離パネルで検証")]))
            print("App OS preview request: " + accepted)
        }
        print("Panel verification workspace: \(root.path)")
    }

    private struct CapturedPackage: PocketAppGenerationAdapter {
        let files: [String: Data]
        let allowsActivation = true
        func generate(_ request: PocketAppGenerationRequest, cancellation: PocketAppGenerationCancellation) async throws -> PocketAppGenerationEnvelope {
            let result = try files.sorted { $0.key < $1.key }.map { path, bytes -> PocketAppGeneratedFile in
                var bytes = bytes
                if path == "manifest.json" {
                    var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                    object["id"] = request.appID
                    object["version"] = request.version
                    var state = object["state"] as! [String: Any]
                    state["store"] = "user-data://" + request.appID
                    object["state"] = state
                    bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                }
                guard let text = String(data: bytes, encoding: .utf8) else { throw PocketAppGenerationError.packageInvalid }
                return PocketAppGeneratedFile(path: path, utf8: text)
            }
            return PocketAppGenerationEnvelope(requestID: request.requestID, requestDigest: request.requestDigest,
                appID: request.appID, version: request.version, namespace: request.namespace, files: result)
        }
    }

    private struct Content: View {
        @ObservedObject var controller: PocketAppGenerationController
        @ObservedObject var settings: AppSettings
        @ObservedObject var surfaces: PocketSurfaceRegistry
        var body: some View {
            TabView {
                ScrollView { PocketAppGenerationSettingsView(controller: controller, settings: settings, language: .japanese).padding(20) }
                    .tabItem { Text("作成・履歴") }
                VStack {
                    ForEach(surfaces.routes, id: \.providerID) { route in
                        if let model = try? surfaces.model(appID: route.appID, surfaceID: route.surfaceID) {
                            PocketSurfaceHostView(model: model).id(model.runtimeIdentity)
                        }
                    }
                    if surfaces.routes.isEmpty { Text("導入後にここへ表示されます。") }
                }.tabItem { Text("導入後の画面") }
            }.frame(minWidth: 600, minHeight: 720)
        }
    }

    static func show(packageDirectory: URL) async throws {
        let files = try PocketAppFileSnapshot.capture(directory: packageDirectory).files
        _ = try PocketAppPackageRuntime().load(directory: packageDirectory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PocketToolsPreview-" + UUID().uuidString)
        let definitions = root.appendingPathComponent("Host")
        let data = root.appendingPathComponent("Data")
        let brokerRoot = root.appendingPathComponent("Broker")
        let broker = CapabilityBroker(registry: try CapabilityRegistry(handlers: PocketCapabilityHandlerSet()),
            ledger: try CapabilityBrokerLedger(rootDirectory: brokerRoot), auditLog: try CapabilityBrokerAuditLog(rootDirectory: brokerRoot))
        let registry = try PocketAppRuntimeActivationRegistry(rootDirectory: definitions, userDataRoot: data, broker: broker, userID: "verification")
        let settings = AppSettings(defaults: EphemeralAppSettingsDefaults())
        let controller = try PocketAppGenerationController(rootDirectory: definitions, userDataRoot: data,
            generationRoot: root.appendingPathComponent("Generation"), generator: CapturedPackage(files: files),
            runtimeActivationReadback: { try registry.synchronize($0) }, generationSettings: settings,
            previewFactory: { package, previewRoot in
                var stores: [String: PocketCollectionStore] = [:]
                for (id, schema) in package.collections {
                    stores[id] = try PocketCollectionStore(packageID: package.manifest.id, collectionID: id, schema: schema,
                        rootDirectory: previewRoot.appendingPathComponent(String(package.stateSchemaDigest.dropFirst(7))))
                }
                let runtime = PocketAppExecutionRuntime(package: package, broker: broker, userID: "preview", grantedPermissions: [], collectionStores: stores)
                return try PocketSurfaceHostModel(runtime: runtime, surfaceID: "main")
            })
        await controller.generate(userRequest: "実Astraが生成した本管理ツールの画面を検証")
        guard controller.phase == .awaitingApproval else { throw PocketAppGenerationError.packageInvalid }
        let window = NSWindow(contentRect: NSRect(x: 180, y: 140, width: 700, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "HoverPocket ツール受入検証"
        window.contentView = NSHostingView(rootView: Content(controller: controller, settings: settings, surfaces: registry.surfaceRegistry))
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.window = window
        print("Preview verification workspace: \(root.path)")
    }
}
