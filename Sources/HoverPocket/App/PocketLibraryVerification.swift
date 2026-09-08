import AppKit
import Foundation
import SwiftUI

@MainActor
enum PocketLibraryVerification {
    static func runLive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PocketLibrariesLive-" + UUID().uuidString)
        let generator = try CodexAppServerPocketGenerator(workspaceRoot: root.appendingPathComponent("Generator"),
            diagnostic: { print("CHECK libraries " + $0) })
        let cases: [(String, Set<String>, String, Set<String>)] = [
            ("reading", ["pocket.html", "pocket.declarative", "pocket.calendar", "pocket.sticky", "pocket.timer", "pocket.calculator", "pocket.controls"],
             "読書メモを作ってください。書名と感想を記録し、追加・編集・検索ができる標準の一覧画面にしてください。", ["pocket.collections"]),
            ("work", ["pocket.collections", "pocket.declarative", "pocket.calendar", "pocket.calculator", "pocket.controls"],
             "作業名を入力して作業開始ボタンを押すと、15分のタイマーを開始し、同じ作業名を付箋にも保存する小さなHTMLツールを作ってください。両方を1つのHost確認にまとめてください。記録一覧は不要です。", ["pocket.html", "pocket.timer", "pocket.sticky"])
        ]
        for (name, disabled, text, expected) in cases {
            let catalog = try PocketLibraryCatalog(disabled: disabled)
            var request = PocketAppGenerationRequest(requestID: "libraries-live-" + name,
                userRequest: text, appID: "local.verification.library-" + name, version: "1.0.0",
                namespace: "library-" + name, capabilities: catalog.generationCapabilities(namespace: "library-" + name))
            request.libraryCatalog = catalog
            let envelope = try await generator.generate(request, cancellation: PocketAppGenerationCancellation())
            let draftRoot = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: draftRoot, withIntermediateDirectories: true)
            let result = try PocketAppGenerationMaterializer(rootDirectory: draftRoot).materialize(envelope: envelope, request: request)
            let chosen = try catalog.dependencies(of: result.package)
            guard chosen == expected, envelope.previewValidation != nil else { throw PocketAppGenerationError.packageInvalid }
            print("PASS live library selection \(name): \(chosen.sorted().joined(separator: ",")); preview=\(envelope.previewValidation!); package=\(result.directory.path)")
        }
        print("PASS library live generation: 2 combinations; evidence=\(root.path)")
    }

    static func showSettings() throws -> NSWindow {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PocketLibrariesUI-" + UUID().uuidString)
        let settings = AppSettings(defaults: EphemeralAppSettingsDefaults())
        let controller = try PocketAppGenerationController(rootDirectory: root.appendingPathComponent("Host"),
            userDataRoot: root.appendingPathComponent("Data"), generationRoot: root.appendingPathComponent("Generation"),
            generator: nil, generationSettings: settings)
        let view = ScrollView {
            PocketAppGenerationSettingsView(controller: controller, settings: settings, language: .japanese)
                .padding(20)
        }.frame(minWidth: 470, minHeight: 600).preferredColorScheme(.dark)
        let window = NSWindow(contentRect: NSRect(x: 150, y: 80, width: 560, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "機能ライブラリの検証（保存先を隔離）"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return window
    }

    static func run() throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw PocketAppPackageError.invalid("library-verification:" + name) }
            checks += 1
        }
        func rejects(_ name: String, _ operation: () throws -> Void) throws {
            var rejected = false
            do { try operation() } catch { rejected = true }
            try check(rejected, name)
        }
        let catalog = try PocketLibraryCatalog()
        try check(catalog.libraries.count == 10, "bundled-modules")
        try check(catalog.generationCapabilities(namespace: "test").count == 6, "existing-operation-contract")
        let withoutTimer = try catalog.settingEnabled(false, id: "pocket.timer", consumers: [:])
        try check(!withoutTimer.isAvailable("pocket.timer"), "disable-unused")
        try check(withoutTimer.generationCapabilities(namespace: "test").count == 4, "generation-filters-disabled")
        let timerJSON = try withoutTimer.promptJSON(namespace: "test")
        try check(!timerJSON.contains("timer.countdown.start"), "model-catalog-filters-disabled")
        try check(try withoutTimer.settingEnabled(true, id: "pocket.timer", consumers: [:]) == catalog, "reenable")
        try rejects("protect-host-ai") { _ = try catalog.settingEnabled(false, id: "pocket.codex", consumers: [:]) }
        try rejects("protect-used-module") {
            _ = try catalog.settingEnabled(false, id: "pocket.timer", consumers: ["a-tool": ["pocket.timer"]])
        }
        try rejects("unknown-module") { _ = try catalog.settingEnabled(false, id: "unknown", consumers: [:]) }
        try rejects("duplicate-modules") { _ = try PocketLibraryCatalog(libraries: catalog.libraries + [catalog.libraries[0]]) }
        try rejects("duplicate-operation-owner") {
            _ = try PocketLibraryCatalog(libraries: catalog.libraries + [
                .init(id: "duplicate", version: 1, name: "duplicate", purpose: "test", capabilityKeys: [PocketCapabilityKeys.timerStart])])
        }
        try rejects("missing-dependency") {
            _ = try PocketLibraryCatalog(libraries: [.init(id: "a", version: 1, name: "a", purpose: "test", dependencies: ["b"])])
        }
        try rejects("dependency-cycle") {
            _ = try PocketLibraryCatalog(libraries: [
                .init(id: "a", version: 1, name: "a", purpose: "test", dependencies: ["b"]),
                .init(id: "b", version: 1, name: "b", purpose: "test", dependencies: ["a"])])
        }
        let dependent = PocketLibraryDescriptor(id: "test.addon", version: 1, name: "addon", purpose: "test", dependencies: ["pocket.timer"])
        let extended = try PocketLibraryCatalog(libraries: catalog.libraries + [dependent])
        try check(extended.isAvailable(dependent.id), "register-module")
        try rejects("transitive-consumer-protection") {
            _ = try extended.settingEnabled(false, id: "pocket.timer", consumers: ["dependent-tool": [dependent.id]])
        }
        let disabledDependency = try PocketLibraryCatalog(libraries: extended.libraries, disabled: ["pocket.timer"])
        try check(!disabledDependency.isAvailable(dependent.id), "transitive-availability")
        try check(!(try PocketLibraryCatalog(platform: "Windows")).isAvailable("pocket.html"), "os-unavailable")
        try check((try PocketLibraryCatalog(disabled: ["future.module"])).isAvailable("pocket.timer"), "unknown-settings-preserved")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PocketLibraries-" + UUID().uuidString)
        let collection: [String: Any] = ["$schema": "hoverpocket://schemas/pocket-collection/v1", "schemaVersion": 1,
            "title": "記録", "fields": ["title": ["title": "名前", "type": "string", "required": true, "nullable": false]]]
        let files = try PocketToolsPlatformVerification.fixtureFiles(collection: collection)
        let packageRoot = root.appendingPathComponent("Package")
        try PocketAppFileSnapshot(rootDirectory: packageRoot, files: files, identities: [:]).materialize(at: packageRoot)
        let package = try PocketAppPackageRuntime().load(directory: packageRoot)
        try check(try catalog.dependencies(of: package) == ["pocket.collections"], "derive-legacy-manifest-dependencies")
        try catalog.validate(package)
        let recordsOff = try catalog.settingEnabled(false, id: "pocket.collections", consumers: [:])
        try rejects("disabled-surface-rejected") { try recordsOff.validate(package) }
        let missingRecords = try PocketLibraryCatalog(libraries: catalog.libraries.filter { $0.id != "pocket.collections" })
        try rejects("removed-module-rejected") { try missingRecords.validate(package) }

        var request = PocketAppGenerationRequest(requestID: "library-test", userRequest: "記録一覧を作る", appID: package.manifest.id,
            version: "1.0.0", namespace: "library-test", capabilities: [])
        request.libraryCatalog = catalog
        try request.validate()
        let originalDigest = request.requestDigest
        request.libraryCatalog = recordsOff
        try check(request.requestDigest != originalDigest, "catalog-bound-to-generation-digest")
        let envelope = PocketAppGenerationEnvelope(requestID: request.requestID, requestDigest: request.requestDigest,
            appID: request.appID, version: request.version, namespace: request.namespace,
            files: files.map { .init(path: $0.key, utf8: String(decoding: $0.value, as: UTF8.self)) })
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Drafts"), withIntermediateDirectories: true)
        var allowedRequest = request
        allowedRequest.libraryCatalog = catalog
        let allowedEnvelope = PocketAppGenerationEnvelope(requestID: allowedRequest.requestID, requestDigest: allowedRequest.requestDigest,
            appID: allowedRequest.appID, version: allowedRequest.version, namespace: allowedRequest.namespace, files: envelope.files)
        let allowedDraft = try PocketAppGenerationMaterializer(rootDirectory: root.appendingPathComponent("Drafts")).materialize(envelope: allowedEnvelope, request: allowedRequest)
        try check(allowedDraft.package.manifestDigest == package.manifestDigest, "positive-control-same-draft")
        try rejects("malicious-draft-rejected-before-preview") {
            _ = try PocketAppGenerationMaterializer(rootDirectory: root.appendingPathComponent("Drafts")).materialize(envelope: envelope, request: request)
        }
        request.libraryCatalog = catalog
        let prompt = try PocketToolGuide.prompt(request)
        try check(prompt.contains("hostOnly") && !prompt.contains("\"id\":\"timer.countdown.start\""), "controller-private-and-bounded-prompt")

        let defaults = EphemeralAppSettingsDefaults()
        let settings = AppSettings(defaults: defaults)
        try check(settings.disabledPocketLibraries.isEmpty, "old-settings-default-enabled")
        let definitions = root.appendingPathComponent("Host")
        let data = root.appendingPathComponent("Data")
        let controller = try PocketAppGenerationController(rootDirectory: definitions, userDataRoot: data,
            generationRoot: root.appendingPathComponent("Generation"), generator: nil, generationSettings: settings)
        controller.setLibraryEnabled(false, id: "pocket.timer")
        let reopened = AppSettings(defaults: defaults)
        try check(reopened.disabledPocketLibraries == ["pocket.timer"], "settings-reopen-readback")
        controller.setLibraryEnabled(true, id: "pocket.timer")
        try check(AppSettings(defaults: defaults).disabledPocketLibraries.isEmpty, "settings-rollback-readback")
        let lifecycle = try PocketAppLifecycleManager(rootDirectory: definitions, userDataRoot: data,
            libraryCatalog: { try PocketLibraryCatalog(disabled: settings.disabledPocketLibraries) })
        let proposal = try lifecycle.stage(draftDirectory: packageRoot)
        let grant = try lifecycle.approve(requestID: proposal.requestID, bindingDigest: proposal.bindingDigest)
        let installed = try lifecycle.install(proposal, approvalGrant: grant)
        try check(installed.readbackVerified, "old-package-install-compatible")
        let store = try PocketCollectionStore(packageID: package.manifest.id, collectionID: "items",
            schema: package.collections["items"]!, rootDirectory: data)
        let initial = try store.snapshot()
        _ = try store.insert(fields: ["title": .string("ライブラリ変更後も保持")], expectedRevision: initial.revision)
        let before = try store.snapshot()
        controller.setLibraryEnabled(false, id: "pocket.collections")
        try check(!settings.disabledPocketLibraries.contains("pocket.collections"), "installed-consumer-blocks-disable")
        try check(controller.libraryConsumers[package.manifest.id] == ["pocket.collections"], "consumer-readback")
        try check(try store.snapshot() == before, "records-unchanged")
        let backupManager = try PocketAppWorkspaceBackupManager(definitionRoot: definitions, userDataRoot: data,
            transactionRoot: root.appendingPathComponent("BackupRestore"), lifecycle: lifecycle)
        let archive = try backupManager.exportData()
        let restoreProposal = try backupManager.prepareRestore(data: archive)
        let restoreGrant = try backupManager.approve(requestID: restoreProposal.requestID, bindingDigest: restoreProposal.bindingDigest)
        settings.saveDisabledPocketLibraries(["pocket.collections"])
        try rejects("backup-preparation-checks-libraries") { _ = try backupManager.prepareRestore(data: archive) }
        try rejects("approved-backup-rechecks-before-mutation") { _ = try backupManager.restore(restoreProposal, grant: restoreGrant) }
        try check(try store.snapshot() == before, "rejected-backup-no-data-mutation")
        settings.saveDisabledPocketLibraries([])
        _ = try lifecycle.disable(packageID: package.manifest.id)
        controller.setLibraryEnabled(false, id: "pocket.collections")
        try check(!settings.disabledPocketLibraries.contains("pocket.collections"), "disabled-tool-still-protected")
        settings.saveDisabledPocketLibraries(["pocket.collections"])
        try rejects("restore-checks-current-library-state") { _ = try lifecycle.stage(draftDirectory: packageRoot) }
        try check(try store.snapshot() == before, "failed-restore-preserves-records")
        settings.saveDisabledPocketLibraries([])
        try check(try PocketAppPackageRuntime().load(directory: packageRoot).manifestDigest == package.manifestDigest, "manifest-unchanged")
        let installedHistory = try PocketToolHistoryStore(rootDirectory: root.appendingPathComponent("Generation/History"))
        _ = try installedHistory.record(package: package, summary: "導入時の履歴", kind: "installed")
        _ = try lifecycle.remove(packageID: package.manifest.id, dataDisposition: .preserve)
        controller.setLibraryEnabled(false, id: "pocket.collections")
        try check(!settings.disabledPocketLibraries.contains("pocket.collections"), "uninstalled-retained-definition-protected")
        try check(try store.snapshot() == before, "uninstalled-records-preserved")

        let historyRoot = root.appendingPathComponent("HistoryOnly")
        let historyStore = try PocketToolHistoryStore(rootDirectory: historyRoot.appendingPathComponent("Generation/History"))
        let checkpoint = try historyStore.record(package: package, summary: "作成途中")
        let historyController = try PocketAppGenerationController(rootDirectory: historyRoot.appendingPathComponent("Host"),
            userDataRoot: historyRoot.appendingPathComponent("Data"), generationRoot: historyRoot.appendingPathComponent("Generation"),
            generator: nil, generationSettings: settings)
        historyController.setLibraryEnabled(false, id: "pocket.collections")
        try check(!settings.disabledPocketLibraries.contains("pocket.collections"), "history-only-consumer-protected")
        historyController.restoreCheckpoint(checkpoint)
        try check(historyController.pendingProposal != nil, "draft-ready-for-confirmation")
        historyController.setLibraryEnabled(false, id: "pocket.timer")
        try check(!settings.disabledPocketLibraries.contains("pocket.timer"), "pending-draft-blocks-library-change")
        historyController.rejectPending()
        settings.saveDisabledPocketLibraries(["pocket.timer"])
        let entry = historyRoot.appendingPathComponent("Generation/History/" + package.manifest.id + "/Entries/" + checkpoint.id + ".json")
        try Data("invalid-test-fixture".utf8).write(to: entry)
        historyController.setLibraryEnabled(false, id: "pocket.html")
        try check(!settings.disabledPocketLibraries.contains("pocket.html"), "corrupt-history-fails-closed")
        historyController.setLibraryEnabled(true, id: "pocket.timer")
        try check(settings.disabledPocketLibraries.isEmpty, "reenable-works-during-history-recovery")

        for name in ["library-settings-old", "library-settings-disabled", "library-settings-rollback"] {
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("contracts/pocket/v2/fixtures/" + name + ".json")
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let fixtureDefaults = EphemeralAppSettingsDefaults()
            for (key, value) in fixture { fixtureDefaults.set(value, forKey: key) }
            let loaded = AppSettings(defaults: fixtureDefaults)
            try check(loaded.disabledPocketLibraries == Set(fixture["disabledPocketLibraries"] as? [String] ?? []), "fixture-settings-" + name)
        }
        print("PASS pocket libraries: \(checks) checks; evidence=\(root.path)")
    }
}
