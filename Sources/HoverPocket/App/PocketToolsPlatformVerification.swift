import Foundation

@MainActor
enum PocketToolsPlatformVerification {
    static func verifyGeneratedActions(packageDirectory: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PocketToolActions-" + UUID().uuidString)
        let definitions = root.appendingPathComponent("Host")
        let data = root.appendingPathComponent("Data")
        let brokerRoot = root.appendingPathComponent("Broker")
        let timer = TimerStore(storageDirectory: root.appendingPathComponent("Timer"), observesWake: false)
        let sticky = StickyNotesStore(storageDirectory: root.appendingPathComponent("Sticky"))
        let handlers = try PocketCapabilityHandlerSet(handlers: [
            TimerCapabilityHandler(operation: .start, store: timer), TimerCapabilityHandler(operation: .get, store: timer),
            StickyCapabilityHandler(operation: .upsert, store: sticky), StickyCapabilityHandler(operation: .get, store: sticky)
        ])
        let broker = CapabilityBroker(registry: try CapabilityRegistry(handlers: handlers),
            ledger: try CapabilityBrokerLedger(rootDirectory: brokerRoot), auditLog: try CapabilityBrokerAuditLog(rootDirectory: brokerRoot),
            approvalPresentationResolver: HostCapabilityApprovalPresentationResolver(stickyStore: sticky))
        let lifecycle = try PocketAppLifecycleManager(rootDirectory: definitions, userDataRoot: data)
        let proposal = try lifecycle.stage(draftDirectory: packageDirectory)
        let grant = try lifecycle.approve(requestID: proposal.requestID, bindingDigest: proposal.bindingDigest)
        let receipt = try lifecycle.install(proposal, approvalGrant: grant)
        let registry = try PocketAppRuntimeActivationRegistry(rootDirectory: definitions, userDataRoot: data, broker: broker, userID: "verification")
        _ = try registry.synchronize(receipt)
        let package = try PocketAppPackageRuntime().load(directory: packageDirectory)
        guard let workflow = package.workflows.values.first,
              let model = try registry.surfaceRegistry.model(appID: package.manifest.id, surfaceID: "main") else {
            throw PocketAppGenerationError.packageInvalid
        }
        var inputs: [String: Any] = [:]
        for (key, type) in workflow.inputs { inputs[key] = type == "integer" ? 900 : "本番動作の検証" }
        try model.prepareHTMLWorkflow(workflow.id, values: inputs)
        guard model.showsApproval, timer.runningTimers.isEmpty, sticky.activeNotes.isEmpty else { throw PocketAppGenerationError.packageInvalid }
        model.reject()
        guard timer.runningTimers.isEmpty, sticky.activeNotes.isEmpty else { throw PocketAppGenerationError.packageInvalid }
        print("PASS generated actions: prepare and cancel cause no writes")
        try model.prepareHTMLWorkflow(workflow.id, values: inputs)
        model.approve()
        let deadline = Date().addingTimeInterval(35)
        while model.isExecuting, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard model.receiptText != nil, timer.runningTimers.count == 1, sticky.activeNotes.count == 1 else {
            throw PocketAppPackageError.invalid("generated-actions: \(model.statusText ?? "no receipt")")
        }
        let readback = StickyNotesStore(storageDirectory: root.appendingPathComponent("Sticky"))
        guard readback.activeNotes.first?.title == "本番動作の検証" else { throw PocketAppGenerationError.packageInvalid }
        print("PASS generated actions: real timer and sticky stores, native approval, verified receipt and independent sticky readback")
        print("Generated action evidence: \(root.path)")
    }

    static func runLiveGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PocketToolsLive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let generator = try CodexAppServerPocketGenerator(workspaceRoot: root.appendingPathComponent("Generator"), diagnostic: { print("CHECK " + $0) })
        let efforts = try await generator.supportedEfforts()
        guard efforts.contains("medium") else { throw PocketAppGenerationError.generatorUnavailable }
        print("PASS live Astra model discovery: Medium supported")
        let requests = [
            "読みたい本の管理ツール。タイトル、著者、読了したかを保存し、追加・編集・検索できる標準画面にしてください。",
            "水やり記録ツール。植物名と最後に水をあげた日を保存し、植物ごとにカードを並べる独自HTML画面にしてください。追加・編集・削除と読み込み・保存エラーの表示も必要です。"
        ]
        for (index, text) in requests.enumerated() {
            let request = PocketAppGenerationRequest(requestID: "live:\(UUID().uuidString.lowercased())",
                userRequest: text, appID: "local.verification.tool\(index)", version: "1.0.0", namespace: "live-tool-\(index)",
                capabilities: PocketAppGenerationCapability.boundedCatalog(namespace: "live-tool-\(index)"))
            let envelope = try await generator.generate(request, cancellation: PocketAppGenerationCancellation())
            let draftRoot = root.appendingPathComponent("Drafts\(index)")
            try FileManager.default.createDirectory(at: draftRoot, withIntermediateDirectories: true)
            let result = try PocketAppGenerationMaterializer(rootDirectory: draftRoot).materialize(envelope: envelope, request: request)
            guard !result.package.collections.isEmpty,
                  result.package.manifest.surfaceKinds.values.contains(index == 0 ? "collection" : "html") else {
                throw PocketAppGenerationError.packageInvalid
            }
            let checks = try PocketAppStagingTestRunner().run(result.package)
            print("PASS live generated tool \(index + 1): package validated, \(checks.count) staging checks")
        }
        print("Live generation artifacts: \(root.path)")
    }

    static func runLiveWorkflow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PocketToolsWorkflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Drafts"), withIntermediateDirectories: true)
        let generator = try CodexAppServerPocketGenerator(workspaceRoot: root.appendingPathComponent("Generator"), diagnostic: { print("CHECK " + $0) })
        let request = PocketAppGenerationRequest(requestID: "live-workflow:\(UUID().uuidString.lowercased())",
            userRequest: "作業を始める小さなツールを作ってください。作業名を入力し、15分のタイマーを開始して同じ作業名の付箋を残す1つのボタンが欲しいです。実行前にHoverPocketの確認を出してください。独自HTML画面で作成し、Hostが処理するまで成功と表示しないでください。",
            appID: "local.verification.startwork", version: "1.0.0", namespace: "live-workflow",
            capabilities: PocketAppGenerationCapability.boundedCatalog(namespace: "live-workflow"))
        let envelope = try await generator.generate(request, cancellation: PocketAppGenerationCancellation())
        let result = try PocketAppGenerationMaterializer(rootDirectory: root.appendingPathComponent("Drafts"))
            .materialize(envelope: envelope, request: request)
        let keys = Set(result.package.manifest.requestedCapabilities.map(\.key))
        guard keys.contains(PocketCapabilityKeys.timerStart), keys.contains(PocketCapabilityKeys.stickyUpsert),
              !result.package.workflows.isEmpty else { throw PocketAppGenerationError.packageInvalid }
        let checks = try PocketAppStagingTestRunner().run(result.package)
        print("PASS live host workflow generation: timer and sticky operations, \(checks.count) staging checks")
        print("Live workflow artifact: \(result.directory.path)")
    }

    static func runLiveEdit(packageDirectory: URL) async throws {
        let source = try PocketAppPackageRuntime().load(directory: packageDirectory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PocketToolsEdit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let generator = try CodexAppServerPocketGenerator(workspaceRoot: root.appendingPathComponent("Generator"),
            diagnostic: { print("CHECK " + $0) })
        let files = try PocketAppFileSnapshot.capture(directory: packageDirectory).files
        var request = PocketAppGenerationRequest(requestID: "live-edit:\(UUID().uuidString.lowercased())",
            userRequest: "この水やりツールを改善してください。植物を置いている場所を任意の文字列項目locationとして追加し、入力フォームと植物カードにも表示してください。既存の植物名・水やり日・追加編集削除・エラー表示は保持してください。collectionのschemaVersionを2へ上げ、locationはrequired:false、nullable:falseにしてください。既存フィールドの名前や型は変更しないでください。",
            appID: source.manifest.id, version: "1.0.1", namespace: "live-tool-1",
            capabilities: PocketAppGenerationCapability.boundedCatalog(namespace: "live-tool-1"))
        request.previousFiles = try files.sorted { $0.key < $1.key }.map { path, bytes in
            guard let text = String(data: bytes, encoding: .utf8) else { throw PocketAppGenerationError.packageInvalid }
            return PocketAppGeneratedFile(path: path, utf8: text)
        }
        let envelope = try await generator.generate(request, cancellation: PocketAppGenerationCancellation())
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Drafts"), withIntermediateDirectories: true)
        let result = try PocketAppGenerationMaterializer(rootDirectory: root.appendingPathComponent("Drafts"))
            .materialize(envelope: envelope, request: request)
        guard let original = source.collections["plants"], let edited = result.package.collections["plants"],
              edited.version == 2, edited.fields["location"]?.type == "string", edited.fields["location"]?.required == false,
              original.fields.allSatisfy({ edited.fields[$0.key] == $0.value }),
              result.package.manifest.surfaceKinds["main"] == "html" else { throw PocketAppGenerationError.packageInvalid }
        print("PASS live conversational edit: optional location added and previous fields preserved")
        print("Live edit artifact: \(result.directory.path)")
    }

    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PocketTools-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let definition: [String: Any] = [
            "$schema": "hoverpocket://schemas/pocket-collection/v1", "schemaVersion": 1, "title": "記録",
            "fields": [
                "title": ["title": "名前", "type": "string", "required": true, "nullable": false],
                "count": ["title": "数", "type": "number", "required": false, "nullable": true],
                "done": ["title": "完了", "type": "boolean", "required": false, "nullable": false],
                "date": ["title": "日付", "type": "date", "required": false, "nullable": false]
            ]
        ]
        let schema = try PocketCollectionSchema(data: JSONSerialization.data(withJSONObject: definition))
        let appID = "local.test.records"
        let store = try PocketCollectionStore(packageID: appID, collectionID: "items", schema: schema, rootDirectory: root)
        let otherWindow = try PocketCollectionStore(packageID: appID, collectionID: "items", schema: schema, rootDirectory: root)
        var checks = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw PocketAppPackageError.invalid("verification:" + name) }
            checks += 1
        }
        func rejects(_ name: String, _ body: () throws -> Void) throws {
            do { try body() } catch { checks += 1; return }
            throw PocketAppPackageError.invalid("verification:accepted_" + name)
        }
        try check(try store.snapshot().revision == 0, "empty")
        let first = try store.insert(fields: ["title": .string("本"), "count": .number(1), "done": .bool(false)], expectedRevision: 0)
        try check(first.revision == 1 && first.records.count == 1, "insert")
        try check(try otherWindow.snapshot() == first, "readback_other_window")
        try rejects("stale_write") { _ = try otherWindow.insert(fields: ["title": .string("古い画面")], expectedRevision: 0) }
        try check(try store.snapshot() == first, "conflict_preserves_bytes")
        try rejects("required") { _ = try store.insert(fields: [:], expectedRevision: 1) }
        try rejects("unknown") { _ = try store.insert(fields: ["title": .string("本"), "other": .string("x")], expectedRevision: 1) }
        try rejects("infinity") { _ = try store.insert(fields: ["title": .string("本"), "count": .number(.infinity)], expectedRevision: 1) }
        try rejects("bad_date") { _ = try store.insert(fields: ["title": .string("本"), "date": .string("2026-02-30")], expectedRevision: 1) }
        try rejects("number_as_bool") { _ = try store.insert(fields: ["title": .string("本"), "done": .number(1)], expectedRevision: 1) }
        let updated = try otherWindow.update(id: first.records[0].id,
            fields: ["title": .string(""), "count": .null, "date": .string("2028-02-29")], expectedRevision: 1)
        try check(updated.records[0].id == first.records[0].id, "stable_id")
        let reopened = try PocketCollectionStore(packageID: appID, collectionID: "items", schema: schema, rootDirectory: root)
        try check(try reopened.snapshot() == updated, "restart_null_empty_date")
        try rejects("missing_id") { _ = try store.delete(id: UUID().uuidString, expectedRevision: 2) }
        let deleted = try store.delete(id: first.records[0].id, expectedRevision: 2)
        try check(deleted.records.isEmpty && deleted.revision == 3, "delete")
        try rejects("path_escape") { _ = try PocketCollectionStore(packageID: appID, collectionID: "../items", schema: schema, rootDirectory: root) }
        let isolated = try PocketCollectionStore(packageID: "local.other.records", collectionID: "items", schema: schema, rootDirectory: root)
        try check(try isolated.snapshot().revision == 0, "tool_isolation")
        let path = root.appendingPathComponent(appID + "/Collections/items.json")
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: path)
        try rejects("corrupt_document") { _ = try store.snapshot() }
        try check(try Data(contentsOf: path) == corrupt, "no_silent_repair")
        try FileManager.default.removeItem(at: path)
        let outside = root.appendingPathComponent("outside.json")
        try corrupt.write(to: outside)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
        try rejects("symlink") { _ = try store.insert(fields: ["title": .string("x")], expectedRevision: 0) }
        try check(try Data(contentsOf: outside) == corrupt, "symlink_target_untouched")
        let number = try PocketJSONValue(any: JSONSerialization.jsonObject(with: Data("{\"v\":1}".utf8)) as! [String: Any], path: "$")
        try check(number == .object(["v": .number(1)]), "json_numeric_one")
        let packageRoot = root.appendingPathComponent("Package")
        var files = try fixtureFiles(collection: definition)
        try PocketAppFileSnapshot(rootDirectory: packageRoot, files: files, identities: [:]).materialize(at: packageRoot)
        let package = try PocketAppPackageRuntime().load(directory: packageRoot)
        try check(package.collections.count == 1 && package.surfaces["main"]?.root.type == "collection", "v2_package")
        let trash = root.appendingPathComponent("TestTrash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let history = try PocketToolHistoryStore(rootDirectory: root.appendingPathComponent("History"), countLimit: 3,
            moveToTrash: { url in try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString)) })
        let initial = try history.record(package: package, summary: "最初", now: Date(timeIntervalSince1970: 1))
        let duplicate = try history.record(package: package, summary: "変更なし", now: Date(timeIntervalSince1970: 2))
        try check(initial.id == duplicate.id && (try history.list()).count == 1, "history_dedup")
        for index in 2...5 {
            files["intent.md"] = Data("説明\(index)".utf8)
            try files["intent.md"]!.write(to: packageRoot.appendingPathComponent("intent.md"))
            let changed = try PocketAppPackageRuntime().load(directory: packageRoot)
            _ = try history.record(package: changed, summary: "変更\(index)", installedDigest: initial.packageDigest,
                now: Date(timeIntervalSince1970: Double(index)))
        }
        let retained = try history.list()
        try check(retained.count == 3 && retained.contains(initial), "history_protect_installed_and_previous")
        try check(try FileManager.default.contentsOfDirectory(atPath: trash.path).count > 0, "history_uses_trash")
        let old = try history.package(for: initial)
        _ = try history.record(package: old, summary: "復元", kind: "restored", installedDigest: initial.packageDigest,
            now: Date(timeIntervalSince1970: 9))
        try check(try history.list().first?.kind == "restored", "restore_is_new_checkpoint")
        let failureHistoryRoot = root.appendingPathComponent("TrashFailureHistory")
        let failureHistory = try PocketToolHistoryStore(rootDirectory: failureHistoryRoot, countLimit: 2,
            moveToTrash: { _ in throw PocketToolHistoryError.busy })
        _ = try failureHistory.record(package: old, summary: "保護する最初の版", now: Date(timeIntervalSince1970: 1))
        let secondPackage = try PocketAppPackageRuntime().load(directory: packageRoot)
        _ = try failureHistory.record(package: secondPackage, summary: "保護する直前版", now: Date(timeIntervalSince1970: 2))
        for _ in 0..<3 {
            try rejects("trash_failure_does_not_allocate") {
                _ = try failureHistory.record(package: old, summary: "復元候補", kind: "restored", now: Date(timeIntervalSince1970: 3))
            }
        }
        try check(try failureHistory.list().count == 2, "trash_failure_history_bounded")
        try check(try failureHistory.package(for: failureHistory.list().first!).manifestDigest == secondPackage.manifestDigest, "trash_failure_preserves_working")
        let limited = try PocketToolHistoryStore(rootDirectory: root.appendingPathComponent("LimitedHistory"), byteLimit: 1)
        try rejects("protected_capacity") { _ = try limited.record(package: old, summary: "容量不足") }
        try check(try limited.list().isEmpty, "capacity_failure_no_checkpoint")
        let lifecycle = try PocketAppLifecycleManager(rootDirectory: root.appendingPathComponent("Host"), userDataRoot: root.appendingPathComponent("LiveData"))
        let proposal = try lifecycle.stage(draftDirectory: packageRoot)
        let grant = try lifecycle.approve(requestID: proposal.requestID, bindingDigest: proposal.bindingDigest)
        let receipt = try lifecycle.install(proposal, approvalGrant: grant)
        try check(receipt.readbackVerified, "v2_install")
        let reloaded = try PocketAppLifecycleManager(rootDirectory: root.appendingPathComponent("Host"), userDataRoot: root.appendingPathComponent("LiveData"))
        try check(try reloaded.activePackage(packageID: package.manifest.id)?.manifestDigest == receipt.packageDigest, "v2_lifecycle_restart")
        let dataRoot = root.appendingPathComponent("LiveData")
        let liveStore = try PocketCollectionStore(packageID: package.manifest.id, collectionID: "items", schema: schema, rootDirectory: dataRoot)
        let saved = try liveStore.insert(fields: ["title": .string("残す記録")], expectedRevision: 0)
        var revisedSchema = definition
        var revisedFields = definition["fields"] as! [String: [String: Any]]
        revisedFields["rating"] = ["title": "評価", "type": "number", "required": false, "nullable": true]
        revisedSchema["fields"] = revisedFields
        revisedSchema["schemaVersion"] = 2
        var revisedManifest = try JSONSerialization.jsonObject(with: files["manifest.json"]!) as! [String: Any]
        revisedManifest["version"] = "1.0.1"
        try JSONSerialization.data(withJSONObject: revisedManifest, options: [.sortedKeys]).write(to: packageRoot.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: revisedSchema, options: [.sortedKeys]).write(to: packageRoot.appendingPathComponent("collections/items.schema.json"))
        let revised = try PocketAppPackageRuntime().load(directory: packageRoot)
        let stale = try lifecycle.stage(draftDirectory: packageRoot)
        try check(stale.dataMigration?.summary.isEmpty == false, "migration_impact_preview")
        _ = try liveStore.insert(fields: ["title": .string("確認後の入力")], expectedRevision: saved.revision)
        let staleGrant = try lifecycle.approve(requestID: stale.requestID, bindingDigest: stale.bindingDigest)
        try rejects("migration_stale_data") { _ = try lifecycle.install(stale, approvalGrant: staleGrant) }
        try lifecycle.reject(requestID: stale.requestID, bindingDigest: stale.bindingDigest)
        try check(try lifecycle.activePackage(packageID: package.manifest.id)?.manifestDigest == receipt.packageDigest, "stale_migration_keeps_definition")
        let migrationProposal = try lifecycle.stage(draftDirectory: packageRoot)
        let migrationGrant = try lifecycle.approve(requestID: migrationProposal.requestID, bindingDigest: migrationProposal.bindingDigest)
        _ = try lifecycle.install(migrationProposal, approvalGrant: migrationGrant)
        let migratedStore = try PocketCollectionStore(packageID: package.manifest.id, collectionID: "items", schema: revised.collections["items"]!, rootDirectory: dataRoot)
        let migrated = try migratedStore.snapshot()
        try check(migrated.schemaVersion == 2 && migrated.records.count == 2 && migrated.records[0].id == saved.records[0].id, "migration_keeps_records_and_ids")
        try rejects("stale_store_after_migration") { _ = try liveStore.snapshot() }
        _ = try migratedStore.update(id: migrated.records[0].id, fields: ["title": .string("移行後の入力"), "rating": .number(4)], expectedRevision: migrated.revision)
        let rollback = try lifecycle.prepareRollback(packageID: package.manifest.id, version: "1.0.0")
        try check(rollback.dataMigration?.summary.contains(where: { $0.contains("評価") }) == true, "rollback_discloses_field_loss")
        let rollbackGrant = try lifecycle.approve(requestID: rollback.requestID, bindingDigest: rollback.bindingDigest)
        _ = try lifecycle.rollback(rollback, approvalGrant: rollbackGrant)
        let restoredStore = try PocketCollectionStore(packageID: package.manifest.id, collectionID: "items", schema: schema, rootDirectory: dataRoot)
        let restored = try restoredStore.snapshot()
        try check(restored.records.count == 2 && restored.records[0].fields["title"] == .string("移行後の入力"), "rollback_keeps_latest_values")
        let manager = try PocketAppWorkspaceBackupManager(definitionRoot: root.appendingPathComponent("Host"),
            userDataRoot: dataRoot, transactionRoot: root.appendingPathComponent("BackupRestore"), lifecycle: lifecycle)
        let backup = try manager.exportData()
        let backupObject = try JSONSerialization.jsonObject(with: backup) as! [String: Any]
        try check(backupObject["schema"] as? String == PocketAppWorkspaceBackupArchive.schemaV2, "v2_backup_contract")
        _ = try restoredStore.insert(fields: ["title": .string("バックアップ後")], expectedRevision: restored.revision)
        let restoreProposal = try manager.prepareRestore(data: backup)
        let restoreGrant = try manager.approve(requestID: restoreProposal.requestID, bindingDigest: restoreProposal.bindingDigest)
        let changed = try restoredStore.snapshot()
        _ = try restoredStore.insert(fields: ["title": .string("承認後")], expectedRevision: changed.revision)
        try rejects("restore_stale_data") { _ = try manager.restore(restoreProposal, grant: restoreGrant) }
        try manager.reject(requestID: restoreProposal.requestID, bindingDigest: restoreProposal.bindingDigest)
        let freshRestore = try manager.prepareRestore(data: backup)
        let freshGrant = try manager.approve(requestID: freshRestore.requestID, bindingDigest: freshRestore.bindingDigest)
        let restoredBackup = try manager.restore(freshRestore, grant: freshGrant)
        let afterBackup = try PocketCollectionStore(packageID: package.manifest.id, collectionID: "items", schema: schema, rootDirectory: dataRoot)
        try check(restoredBackup.readbackVerified && (try afterBackup.snapshot()) == restored, "v2_backup_full_readback")
        let current = try lifecycle.activePackage(packageID: package.manifest.id)!
        let crashPlan = try PocketToolDataMigration.prepare(from: current, to: revised, userDataRoot: dataRoot)
        let previousRecord = try PocketAppFileSnapshot.readFileNoFollow(rootDirectory: root.appendingPathComponent("Host"),
            relativePath: "Apps/\(package.manifest.id)/active.json", maximumBytes: 32_768)
        _ = try PocketToolDataLock.withLock(rootDirectory: dataRoot, packageID: package.manifest.id) {
            try PocketToolDataMigrationTransaction.begin(plan: crashPlan, previousActiveRecord: previousRecord,
                userDataRoot: dataRoot, journalRoot: root.appendingPathComponent("Host/DataMigrations"))
        }
        let recoveredHost = try PocketAppLifecycleManager(rootDirectory: root.appendingPathComponent("Host"), userDataRoot: dataRoot)
        try check(try recoveredHost.activePackage(packageID: package.manifest.id)?.manifestDigest == current.manifestDigest, "crash_recovers_definition")
        try check(try PocketToolDataMigration.capture(directory: dataRoot.appendingPathComponent(package.manifest.id)) == crashPlan.sourceFiles, "crash_recovers_data")
        for patch in 2...4 {
            let previous = try lifecycle.activePackage(packageID: package.manifest.id)!
            revisedManifest["version"] = "1.0.\(patch)"
            try JSONSerialization.data(withJSONObject: revisedManifest, options: [.sortedKeys]).write(to: packageRoot.appendingPathComponent("manifest.json"))
            let next = try lifecycle.stage(draftDirectory: packageRoot)
            let grant = try lifecycle.approve(requestID: next.requestID, bindingDigest: next.bindingDigest)
            _ = try lifecycle.install(next, approvalGrant: grant)
            try lifecycle.retainCurrentAndPreviousDefinition(packageID: package.manifest.id, previousDigest: previous.manifestDigest,
                moveToTrash: { url in try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString)) })
            try check((try lifecycle.managedPackage(packageID: package.manifest.id))?.installedVersions.count == 2, "bounded_runtime_definitions")
        }
        try check(try lifecycle.installedDefinitionBytes(packageID: package.manifest.id) > 0, "runtime_definition_budget")
        let sharedBudget = try PocketToolHistoryStore(rootDirectory: root.appendingPathComponent("SharedBudget"), byteLimit: 10_000)
        try rejects("runtime_reservation_capacity") {
            _ = try sharedBudget.record(package: package, summary: "共同上限", reservedDefinitionBytes: 10_000)
        }
        try check(try sharedBudget.list().isEmpty, "shared_capacity_keeps_existing")
        let activeForLargeBackup = try lifecycle.activePackage(packageID: package.manifest.id)!
        let largeRecords = (0..<300).map { index in
            ["id": UUID().uuidString.lowercased(), "fields": ["title": String(repeating: "x", count: 4_000) + String(index)]] as [String: Any]
        }
        let largeBytes = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "schemaVersion": 2,
            "revision": 1, "records": largeRecords], options: [.sortedKeys])
        try largeBytes.write(to: dataRoot.appendingPathComponent("\(package.manifest.id)/Collections/items.json"), options: .atomic)
        let largeBackup = try manager.exportData()
        try check(largeBackup.count > 1_048_576, "large_collection_backup")
        let largeRestore = try manager.prepareRestore(data: largeBackup)
        let largeGrant = try manager.approve(requestID: largeRestore.requestID, bindingDigest: largeRestore.bindingDigest)
        let largeReceipt = try manager.restore(largeRestore, grant: largeGrant)
        let largeReadback = try PocketCollectionStore(packageID: package.manifest.id, collectionID: "items",
            schema: activeForLargeBackup.collections["items"]!, rootDirectory: dataRoot)
        try check(largeReceipt.readbackVerified && (try largeReadback.snapshot()).records.count == 300, "large_backup_restore_readback")
        var invalid = files
        invalid["collections/items.schema.json"] = Data("{}".utf8)
        try rejects("invalid_collection_contract") { _ = try PocketAppPackageRuntime().load(snapshot: PocketAppFileSnapshot(rootDirectory: root, files: invalid, identities: [:])) }
        let sampleRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/HoverPocket/Resources/PocketApps/local.example.today-focus")
        if FileManager.default.fileExists(atPath: sampleRoot.path) {
            let original = try PocketAppFileSnapshot.capture(directory: sampleRoot).files
            var scoped = original.mapValues { data in
                Data(String(decoding: data, as: UTF8.self)
                    .replacingOccurrences(of: "\"namespace\": \"today-focus\"", with: "\"namespace\": \"tool-verification\"")
                    .replacingOccurrences(of: "$context.todayFocusStableKey", with: "tool-verification:current").utf8)
            }
            var manifest = try JSONSerialization.jsonObject(with: scoped["manifest.json"]!) as! [String: Any]
            manifest["$schema"] = "hoverpocket://schemas/pocket-app/v2"
            manifest["apiVersion"] = "hoverpocket.app/v2"
            scoped["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            let scopedPackage = try PocketAppPackageRuntime().load(snapshot: PocketAppFileSnapshot(rootDirectory: sampleRoot, files: scoped, identities: [:]))
            try check(scopedPackage.manifest.requestedCapabilities.contains(where: { $0.scope == .object(["namespace": .string("tool-verification")]) }), "v2_scoped_host_actions")
            let workflowPath = "workflows/start-focus.workflow.json"
            let workflowObject = try JSONSerialization.jsonObject(with: scoped[workflowPath]!) as! [String: Any]
            var optionalWorkflow = workflowObject
            var optionalSteps = workflowObject["steps"] as! [[String: Any]]
            var timerArguments = optionalSteps[0]["with"] as! [String: Any]
            timerArguments.removeValue(forKey: "sourceRef")
            timerArguments.removeValue(forKey: "title")
            optionalSteps[0]["with"] = timerArguments
            optionalWorkflow["steps"] = optionalSteps
            var optionalFiles = scoped
            optionalFiles[workflowPath] = try JSONSerialization.data(withJSONObject: optionalWorkflow)
            _ = try PocketAppPackageRuntime().load(snapshot: PocketAppFileSnapshot(rootDirectory: sampleRoot, files: optionalFiles, identities: [:]))
            let normalized = try PocketAppWorkflowPresentationPolicy.canonicalArguments(
                ["durationSeconds": .integer(900)], capability: PocketCapabilityKeys.timerStart, allowsOptionalDefaults: true)
            try check(normalized["sourceRef"] == .null && normalized["title"] == .string("タイマー"), "v2_timer_optional_defaults_match_runtime")
            for (name, stepIndex, key, value) in [
                ("invalid_timer_duration", 0, "durationSeconds", 0 as Any),
                ("invalid_sticky_color", 1, "color", "purple" as Any),
                ("unknown_timer_argument", 0, "extra", "unexpected" as Any)
            ] {
                var brokenWorkflow = workflowObject
                var brokenSteps = workflowObject["steps"] as! [[String: Any]]
                var brokenArguments = brokenSteps[stepIndex]["with"] as! [String: Any]
                brokenArguments[key] = value
                brokenSteps[stepIndex]["with"] = brokenArguments
                brokenWorkflow["steps"] = brokenSteps
                var brokenFiles = scoped
                brokenFiles[workflowPath] = try JSONSerialization.data(withJSONObject: brokenWorkflow)
                try rejects("v2_" + name + "_before_install") {
                    _ = try PocketAppPackageRuntime().load(snapshot: PocketAppFileSnapshot(rootDirectory: sampleRoot, files: brokenFiles, identities: [:]))
                }
            }
            var outOfScope = scoped
            outOfScope["workflows/start-focus.workflow.json"] = Data(String(decoding: scoped["workflows/start-focus.workflow.json"]!, as: UTF8.self)
                .replacingOccurrences(of: "tool-verification:current", with: "other-tool:current").utf8)
            try rejects("v2_workflow_scope_escape") { _ = try PocketAppPackageRuntime().load(snapshot: PocketAppFileSnapshot(rootDirectory: sampleRoot, files: outOfScope, identities: [:])) }
            var capabilities = manifest["requestedCapabilities"] as! [[String: Any]]
            let scopedIndex = capabilities.firstIndex { $0["id"] as? String == "sticky.note.upsert" }!
            capabilities[scopedIndex].removeValue(forKey: "scope")
            manifest["requestedCapabilities"] = capabilities
            scoped["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            try rejects("v2_missing_sticky_scope") { _ = try PocketAppPackageRuntime().load(snapshot: PocketAppFileSnapshot(rootDirectory: sampleRoot, files: scoped, identities: [:])) }
        }
        let defaults = EphemeralAppSettingsDefaults()
        let settings = AppSettings(defaults: defaults)
        try check(settings.pocketToolReasoningEffort == "medium", "default_medium")
        settings.pocketToolReasoningEffort = "high"
        try check(AppSettings(defaults: defaults).pocketToolReasoningEffort == "high", "preserve_effort")
        checks += try verifyRemoval(files: fixtureFiles(collection: definition))
        print("PASS pocket tools platform: \(checks) persistence, history, lifecycle and settings checks")
    }

    private static func verifyRemoval(files: [String: Data]) throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PocketRemoval-" + UUID().uuidString)
        let definitions = root.appendingPathComponent("Host"), data = root.appendingPathComponent("Data")
        let generation = root.appendingPathComponent("Generation"), draft = generation.appendingPathComponent("draft-fixture")
        for (path, bytes) in files {
            let file = draft.appendingPathComponent(path)
            _ = try PocketAppPinnedDirectory(url: file.deletingLastPathComponent())
            try bytes.write(to: file)
        }
        let package = try PocketAppPackageRuntime().load(directory: draft)
        let id = package.manifest.id
        let broker = CapabilityBroker(registry: try CapabilityRegistry(handlers: PocketCapabilityHandlerSet()),
            ledger: try CapabilityBrokerLedger(rootDirectory: root.appendingPathComponent("Broker")),
            auditLog: try CapabilityBrokerAuditLog(rootDirectory: root.appendingPathComponent("Broker")))
        let activation = try PocketAppRuntimeActivationRegistry(rootDirectory: definitions, userDataRoot: data, broker: broker, userID: "verification")
        let lifecycle = try PocketAppLifecycleManager(rootDirectory: definitions, userDataRoot: data)
        let proposal = try lifecycle.stage(draftDirectory: draft)
        let grant = try lifecycle.approve(requestID: proposal.requestID, bindingDigest: proposal.bindingDigest)
        _ = try activation.synchronize(lifecycle.install(proposal, approvalGrant: grant))
        let model = try activation.surfaceRegistry.model(appID: id, surfaceID: "main")!
        _ = try model.writeCollection("items", recordID: nil, fields: ["title": .string("残す記録")], revision: 0)
        let history = try PocketToolHistoryStore(rootDirectory: generation.appendingPathComponent("History"))
        _ = try history.record(package: package, summary: "確認用", kind: "installed")
        let controller = try PocketAppGenerationController(rootDirectory: definitions, userDataRoot: data, generationRoot: generation,
            generator: nil, runtimeActivationReadback: { try activation.synchronize($0) })
        var count = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw PocketAppPackageError.invalid("removal:" + label) }
            count += 1
        }
        controller.removeTool(packageID: id, includingData: false)
        try check(controller.uninstalledPackages.contains { $0.packageID == id } && !controller.history.isEmpty, "uninstall_retains_history")
        let readback = try PocketCollectionStore(packageID: id, collectionID: "items", schema: package.collections["items"]!, rootDirectory: data)
        try check(try readback.snapshot().records.count == 1 && activation.surfaceRegistry.routes.isEmpty, "uninstall_retains_record_and_removes_route")
        do {
            _ = try model.writeCollection("items", recordID: nil, fields: ["title": .string("stale")], revision: 1)
            throw PocketAppPackageError.invalid("removal:stale_surface_wrote")
        } catch is PocketAppRuntimeActivationError { count += 1 }
          catch is PocketCollectionError { count += 1 }

        let other = data.appendingPathComponent("local.other.tool/keep.txt")
        _ = try PocketAppPinnedDirectory(url: other.deletingLastPathComponent())
        try Data("other tool".utf8).write(to: other)
        let backup = definitions.appendingPathComponent("BackupRestore/PriorData/" + id + "/snapshot/keep.txt")
        _ = try PocketAppPinnedDirectory(url: backup.deletingLastPathComponent())
        try Data("backup".utf8).write(to: backup)
        let migration = definitions.appendingPathComponent("DataMigrations/" + UUID().uuidString)
        _ = try PocketAppPinnedDirectory(url: migration)
        try JSONSerialization.data(withJSONObject: ["packageID": id]).write(to: migration.appendingPathComponent("journal.json"))
        let remover = PocketToolRemoval(definitionRoot: definitions, userDataRoot: data, generationRoot: generation)
        var failing = remover
        var moved = 0
        failing.moveToTrash = { url in
            moved += 1
            if moved == 2 { throw PocketCollectionError.persistenceFailed }
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        do { try failing.removeDataAndHistory(packageID: id); throw PocketAppPackageError.invalid("removal:failure_not_injected") }
        catch is PocketCollectionError { count += 1 }
        try check(FileManager.default.fileExists(atPath: definitions.appendingPathComponent("Apps/" + id).path), "partial_failure_keeps_retry_marker")
        controller.removeTool(packageID: id, includingData: true)
        try check(controller.uninstalledPackages.isEmpty && controller.history.isEmpty && controller.errorCode == nil,
                  "retry_removes_tool_and_history")
        try check(!FileManager.default.fileExists(atPath: data.appendingPathComponent(id).path)
                  && !FileManager.default.fileExists(atPath: draft.path)
                  && !FileManager.default.fileExists(atPath: backup.path)
                  && !FileManager.default.fileExists(atPath: migration.path), "owned_data_drafts_and_backups_removed")
        try check(try Data(contentsOf: other) == Data("other tool".utf8), "other_tool_untouched")
        let restarted = try PocketAppGenerationController(rootDirectory: definitions, userDataRoot: data, generationRoot: generation, generator: nil)
        try check(restarted.managedPackages.isEmpty && restarted.uninstalledPackages.isEmpty && restarted.history.isEmpty, "restart_does_not_restore_deleted_tool")
        let link = data.appendingPathComponent(id)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other.deletingLastPathComponent())
        do { try remover.removeDataAndHistory(packageID: id); throw PocketAppPackageError.invalid("removal:symlink_accepted") }
        catch is PocketAppGenerationError { count += 1 }
        try check(try Data(contentsOf: other) == Data("other tool".utf8), "symlink_target_untouched")
        do { try remover.removeDataAndHistory(packageID: "local.example.today-focus"); throw PocketAppPackageError.invalid("removal:built_in_accepted") }
        catch is PocketAppGenerationError { count += 1 }
        try check(ProviderRegistry.builtIn.providers.contains { $0.manifest.id == MirrorProvider.pluginID }
                  && ProviderRegistry.builtIn.providers.contains { $0.manifest.id == GoogleCalendarProvider.pluginID }, "native_providers_preserved")
        return count
    }

    static func fixtureFiles(collection: [String: Any]) throws -> [String: Data] {
        let manifest: [String: Any] = [
            "$schema": "hoverpocket://schemas/pocket-app/v2", "apiVersion": "hoverpocket.app/v2",
            "id": "local.verification.records", "name": "記録ツール", "version": "1.0.0", "minHostVersion": "1.0.0",
            "intent": "intent.md", "state": ["schema": "data.schema.json", "store": "user-data://local.verification.records"],
            "collections": ["items": ["schema": "collections/items.schema.json"]],
            "surfaces": [["id": "main", "kind": "collection", "source": "surfaces/main.surface.json"]],
            "requestedCapabilities": [], "workflows": [:], "tests": ["tests/surface.json"],
            "workspace": ["ownership": "user", "definitionRoot": "app_definition", "dataRoot": "separate_user_data",
                "secrets": "credential_store_only", "exportable": true, "deletable": true, "rollback": "versioned_snapshot"]
        ]
        let documents: [String: [String: Any]] = [
            "manifest.json": manifest,
            "data.schema.json": ["type": "object", "required": [], "properties": [:], "additionalProperties": false],
            "collections/items.schema.json": collection,
            "surfaces/main.surface.json": ["$schema": "hoverpocket://schemas/pocket-collection-surface/v1", "id": "main", "collection": "items", "titleField": "title"],
            "tests/surface.json": ["case": "surface-renders", "expected": "pass"]
        ]
        var files = try documents.mapValues { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        files["intent.md"] = Data("記録を管理する".utf8)
        return files
    }
}
