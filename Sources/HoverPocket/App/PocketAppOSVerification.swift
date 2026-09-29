import AppKit
import Foundation

@MainActor
enum PocketAppOSVerification {
    private actor Generator: PocketAppGenerationAdapter {
        let files: [String: Data]
        init(files: [String: Data]) { self.files = files }
        func generate(_ request: PocketAppGenerationRequest, cancellation: PocketAppGenerationCancellation) async throws -> PocketAppGenerationEnvelope {
            try await Task.sleep(for: .milliseconds(180))
            guard !cancellation.isCancelled else { throw PocketAppGenerationError.generatorCancelled }
            var files = self.files
            var manifest = try JSONSerialization.jsonObject(with: files["manifest.json"]!) as! [String: Any]
            manifest["id"] = request.appID; manifest["version"] = request.version
            manifest["state"] = ["schema": "data.schema.json", "store": "user-data://" + request.appID]
            files["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            return PocketAppGenerationEnvelope(requestID: request.requestID, requestDigest: request.requestDigest,
                appID: request.appID, version: request.version, namespace: request.namespace,
                files: files.map { PocketAppGeneratedFile(path: $0.key, utf8: String(data: $0.value, encoding: .utf8)!) }, previewValidation: "verification-fixture")
        }
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PocketAppOS-" + UUID().uuidString)
        defer { AINativeRuntime.shared.configure(); try? FileManager.default.removeItem(at: root) }
        let definition: [String: Any] = ["$schema": "hoverpocket://schemas/pocket-collection/v1", "schemaVersion": 1,
            "title": "確認記録", "fields": ["title": ["title": "名前", "type": "string", "required": true, "nullable": false]]]
        var files = try PocketToolsPlatformVerification.fixtureFiles(collection: definition)
        var manifest = try JSONSerialization.jsonObject(with: files["manifest.json"]!) as! [String: Any]
        manifest["requestedCapabilities"] = [["id": "timer.countdown.start", "version": 1]]
        manifest["workflows"] = ["startTimer": "workflows/timer.workflow.json"]
        files["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        files["workflows/timer.workflow.json"] = Data(#"{"$schema":"hoverpocket://schemas/pocket-workflow/v1","workflowVersion":1,"id":"startTimer","inputs":{"seconds":"integer","title":"string"},"approval":{"mode":"before_writes","group":"all_writes"},"steps":[{"id":"start","use":"timer.countdown.start@1","with":{"durationSeconds":"$input.seconds","title":"$input.title"},"dependsOn":[]}],"onPartialFailure":{"mode":"compensate_if_available","presentReceipt":true},"limits":{"maxSteps":8,"maxDepth":2,"timeoutSeconds":30}}"#.utf8)
        let data = root.appendingPathComponent("Data"), definitions = root.appendingPathComponent("Host")
        let timer = TimerStore(storageDirectory: root.appendingPathComponent("Timer"), observesWake: false)
        let handlers = try PocketCapabilityHandlerSet(handlers: [TimerCapabilityHandler(operation: .start, store: timer), TimerCapabilityHandler(operation: .get, store: timer)])
        let broker = CapabilityBroker(registry: try CapabilityRegistry(handlers: handlers),
            ledger: try CapabilityBrokerLedger(rootDirectory: root.appendingPathComponent("Broker")),
            auditLog: try CapabilityBrokerAuditLog(rootDirectory: root.appendingPathComponent("Broker")))
        let registry = try PocketAppRuntimeActivationRegistry(rootDirectory: definitions, userDataRoot: data, broker: broker, userID: "verification")
        let controller = try PocketAppGenerationController(rootDirectory: definitions, userDataRoot: data,
            generationRoot: root.appendingPathComponent("Generation"), generator: Generator(files: files),
            runtimeActivationReadback: { try registry.synchronize($0) }, previewFactory: { package, previewRoot in
                var stores: [String: PocketCollectionStore] = [:]
                for (id, schema) in package.collections { stores[id] = try PocketCollectionStore(packageID: package.manifest.id, collectionID: id, schema: schema, rootDirectory: previewRoot) }
                let runtime = PocketAppExecutionRuntime(package: package, broker: broker, userID: "preview", grantedPermissions: [], collectionStores: stores)
                return try PocketSurfaceHostModel(runtime: runtime, surfaceID: "main")
            })
        AINativeRuntime.shared.configure(pocketAppGenerationController: controller, generatedActivationRegistry: registry)
        let defaults = EphemeralAppSettingsDefaults()
        let settings = AppSettings(defaults: defaults)
        let providerStore = ProviderStore(registry: .builtIn, settings: settings)
        var verificationTime = Date()
        let host = PocketAppOSController(now: { verificationTime })
        host.providerStore = providerStore
        var notices = 0
        host.notifySession = { _, _ in notices += 1; return true }
        let session = "voice-verification"
        var serial = 0
        func call(_ operation: String, _ fields: [String: CodexJSONValue] = [:], sessionID: String? = nil, callID: String? = nil) async throws -> [String: Any] {
            serial += 1
            var args = fields; args["operation"] = .string(operation)
            let text = await host.execute(session: sessionID ?? session, callID: callID ?? "call-\(serial)", arguments: .object(args))
            return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        }
        var checks = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw PocketPreviewValidationError(code: name) }
            checks += 1
        }
        func waitForJob() async throws {
            let end = Date().addingTimeInterval(8)
            while host.jobStatus == "generating", Date() < end { try await Task.sleep(for: .milliseconds(30)) }
            try check(host.jobStatus != "generating", "generation_timeout")
        }
        let catalog = try await call("catalog")
        try check((catalog["screens"] as? [[String: Any]])?.contains { $0["provider_id"] as? String == "google-calendar" && $0["owner"] as? String == "standard" } == true, "standard_catalog")
        let clockBefore = verificationTime
        let clockScreen = catalog["screen"] as? [String: Any]
        try check(clockScreen?["current_time"] as? String == CapabilityDateCodec.string(from: clockBefore)
            && clockScreen?["timezone"] as? String == TimeZone.current.identifier, "catalog_host_current_time")
        verificationTime = clockBefore.addingTimeInterval(600)
        let refreshedClock = try await call("catalog")["screen"] as? [String: Any]
        try check(refreshedClock?["current_time"] as? String == CapabilityDateCodec.string(from: verificationTime), "catalog_clock_refresh_for_relative_reminder")
        verificationTime = clockBefore
        let accepted = try await call("generate", ["request": .string("記録ツール")], callID: "generate-once")
        let job = accepted["job_id"] as! String
        try check(accepted["status"] as? String == "accepted" && host.jobStatus == "generating", "background_acceptance")
        let replay = try await call("generate", ["request": .string("記録ツール")], callID: "generate-once")
        try check(replay["job_id"] as? String == job, "generation_replay")
        try check(try await call("generate", ["request": .string("二重起動")])["code"] as? String == "generation_busy", "busy_rejected")
        try check(try await call("catalog")["status"] as? String == "succeeded", "other_tool_during_generation")
        try await waitForJob()
        try check(notices == 1 && controller.pendingProposal != nil && controller.managedPackages.isEmpty, "preview_without_install")
        try check(controller.previewValidationReport == "verification-fixture" && controller.historyIssue == nil, "preview_report_preserves_history_format")
        let preview = try await call("job", ["job_id": .string(job)])
        let packageID = (preview["proposal"] as! [String: Any])["package_id"] as! String
        let prepared = try await call("install_prepare", ["job_id": .string(job)])
        let confirmation = prepared["confirmation_id"] as! String
        try check(try await call("confirm", ["confirmation_id": .string(confirmation), "confirmed": .bool(true)])["code"] as? String == "confirmation_mismatch", "no_user_reply_no_install")
        host.noteUserInput(session: "other-session")
        try check(try await call("confirm", ["confirmation_id": .string(confirmation), "confirmed": .bool(true)], sessionID: "other-session")["code"] as? String == "confirmation_mismatch", "session_bound")
        host.noteUserInput(session: session)
        let installed = try await call("confirm", ["confirmation_id": .string(confirmation), "confirmed": .bool(true)])
        try check(installed["readback_verified"] as? Bool == true && registry.surfaceRegistry.activeAppIDs.contains(packageID), "install_readback")
        let collections = try await call("collections", ["package_id": .string(packageID)])
        try check((collections["collections"] as? [[String: Any]])?.count == 1, "schema_discovery")
        let model = try registry.surfaceRegistry.model(appID: packageID, surfaceID: "main")!
        try check(try registry.surfaceRegistry.model(appID: packageID, surfaceID: "main") === model, "shared_surface_model")
        let workflowInputs: [String: CodexJSONValue] = ["package_id": .string(packageID), "workflow_id": .string("startTimer"),
            "inputs": .object(["seconds": .integer(60), "title": .string("隔離音声確認")])]
        _ = try await call("workflow_prepare", workflowInputs)
        try check(timer.runningTimers.isEmpty && model.pendingVoiceApprovalID != nil && !model.showsApproval, "workflow_prepared_without_write_or_duplicate_dialog")
        try check(host.cancelPendingConfirmation(session: session) && model.pendingVoiceApprovalID == nil && timer.runningTimers.isEmpty, "workflow_cancelled_without_write")
        let workflow = try await call("workflow_prepare", workflowInputs)
        host.noteUserInput(session: session)
        let workflowResult = try await call("confirm", ["confirmation_id": .string(workflow["confirmation_id"] as! String), "confirmed": .bool(true)])
        try check(workflowResult["readback_verified"] as? Bool == true && timer.runningTimers.count == 1, "generic_workflow_broker_readback")
        let recordPrepare = try await call("record_prepare", ["package_id": .string(packageID), "collection_id": .string("items"), "revision": .integer(0), "fields": .object(["title": .string("保持する記録")])])
        host.noteUserInput(session: session)
        let recordConfirmation = recordPrepare["confirmation_id"] as! String
        let recordResult = try await call("confirm", ["confirmation_id": .string(recordConfirmation), "confirmed": .bool(true)], callID: "record-once")
        try check(recordResult["revision"] as? Int == 1 && model.collectionSelection("items").snapshot?.records.count == 1, "record_and_ui_readback")
        _ = try await call("confirm", ["confirmation_id": .string(recordConfirmation), "confirmed": .bool(true)], callID: "record-once")
        try check(try model.collectionSnapshot("items").records.count == 1, "record_replay_no_duplicate")
        model.collectionSelection("items").isEditing = true
        try check(try await call("record_prepare", ["package_id": .string(packageID), "collection_id": .string("items"), "revision": .integer(1), "fields": .object(["title": .string("競合")])])["code"] as? String == "screen_edit_in_progress", "editing_preserved")
        model.collectionSelection("items").isEditing = false
        let stale = try await call("record_prepare", ["package_id": .string(packageID), "collection_id": .string("items"), "revision": .integer(1), "fields": .object(["title": .string("古い確認")])])
        _ = try model.writeCollection("items", recordID: nil, fields: ["title": .string("別の操作")], revision: 1)
        host.noteUserInput(session: session)
        try check(try await call("confirm", ["confirmation_id": .string(stale["confirmation_id"] as! String), "confirmed": .bool(true)])["code"] as? String == "revision_conflict", "stale_revision_rejected")
        for id in PocketAppOwnership.standardPackageIDs.union(ProviderRegistry.builtIn.manifests.map { $0.id.rawValue }) {
            try check(try await call("remove_prepare", ["package_id": .string(id)])["code"] as? String == "protected_or_unknown_package", "standard_protected")
        }
        controller.refreshHistory()
        let checkpoint = controller.history.first { $0.packageID == packageID }!.id
        let remove = try await call("remove_prepare", ["package_id": .string(packageID)])
        host.noteUserInput(session: session)
        let removed = try await call("confirm", ["confirmation_id": .string(remove["confirmation_id"] as! String), "confirmed": .bool(true)])
        try check(removed["state"] as? String == "removed" && !model.activationAvailable, "remove_and_invalidation")
        let schema = try PocketCollectionSchema(data: JSONSerialization.data(withJSONObject: definition))
        let readback = try PocketCollectionStore(packageID: packageID, collectionID: "items", schema: schema, rootDirectory: data)
        try check(try readback.snapshot().records.count == 2, "uninstall_keeps_data")
        let restore = try await call("restore_prepare", ["checkpoint_id": .string(checkpoint)])
        let restoration = try await call("install_prepare", ["job_id": .string(restore["job_id"] as! String)])
        host.noteUserInput(session: session)
        try check(try await call("confirm", ["confirmation_id": .string(restoration["confirmation_id"] as! String), "confirmed": .bool(true)])["readback_verified"] as? Bool == true, "restore_approved")
        try check(try readback.snapshot().records.count == 2, "restore_keeps_data")
        let expired = try await call("remove_prepare", ["package_id": .string(packageID)])
        verificationTime = verificationTime.addingTimeInterval(301)
        host.noteUserInput(session: session)
        try check(try await call("confirm", ["confirmation_id": .string(expired["confirmation_id"] as! String), "confirmed": .bool(true)])["code"] as? String == "confirmation_mismatch", "confirmation_expiry")
        let pendingRemove = try await call("remove_prepare", ["package_id": .string(packageID)])
        host.cancelSession(session)
        host.noteUserInput(session: session)
        try check(try await call("confirm", ["confirmation_id": .string(pendingRemove["confirmation_id"] as! String), "confirmed": .bool(true)])["code"] as? String == "confirmation_mismatch", "disconnect_expires_confirmation")
        host.actionConfirmationEnabled = { false }
        let autoRecord = try await call("record_prepare", ["package_id": .string(packageID), "collection_id": .string("items"),
            "revision": .integer(Int64(try readback.snapshot().revision)), "fields": .object(["title": .string("音声だけで追加")])])
        try check(autoRecord["readback_verified"] as? Bool == true && (try readback.snapshot().records.count) == 3, "normal_off_record_without_confirmation")
        let autoWorkflow = try await call("workflow_prepare", workflowInputs)
        let restoredModel = try registry.surfaceRegistry.model(appID: packageID, surfaceID: "main")!
        try check(autoWorkflow["readback_verified"] as? Bool == true && timer.runningTimers.count == 2 && !restoredModel.showsApproval, "normal_off_workflow_without_dialog")
        let deletionSnapshot = try readback.snapshot()
        let deletionFields: [String: CodexJSONValue] = ["package_id": .string(packageID), "collection_id": .string("items"),
            "record_id": .string(deletionSnapshot.records.last!.id), "revision": .integer(Int64(deletionSnapshot.revision)),
            "fields": .object([:]), "delete_record": .bool(true)]
        try check(try await call("record_prepare", deletionFields)["status"] as? String == "awaiting_confirmation", "delete_on_independent_of_normal_off")
        _ = host.cancelPendingConfirmation(session: session)
        host.destructiveConfirmationEnabled = { false }
        host.actionConfirmationEnabled = { true }
        try check(try await call("record_prepare", deletionFields)["readback_verified"] as? Bool == true && (try readback.snapshot().records.count) == 2, "delete_off_record_without_confirmation")
        try check(try await call("remove_prepare", ["package_id": .string(packageID)])["state"] as? String == "removed", "delete_off_uninstall_without_confirmation")
        try check(try readback.snapshot().records.count == 2, "automatic_uninstall_preserves_data")
        host.actionConfirmationEnabled = { false }
        let automaticRestore = try await call("restore_prepare", ["checkpoint_id": .string(checkpoint)])
        try check(try await call("install_prepare", ["job_id": .string(automaticRestore["job_id"] as! String)])["readback_verified"] as? Bool == true, "normal_off_restored_install")
        _ = try await call("generate", ["request": .string("取り消す試作")])
        _ = try await call("cancel")
        try await waitForJob()
        try check(host.jobStatus == "cancelled", "generation_cancelled")
        settings.codexVoiceSelection = "maple"
        try check(AppSettings(defaults: defaults).codexVoiceSelection == "maple", "voice_selection_persisted")
        try check(AppSettings(defaults: EphemeralAppSettingsDefaults()).codexVoiceSelection.isEmpty, "voice_default_compatible")
        let voices = try CodexVoiceCoordinator.parseVoices(.object(["voices": .object([
            "v1": .array([.string("maple"), .string("cove")]), "v2": .array([.string("cedar")])
        ])]))
        try check(voices == ["cove", "maple"], "voice_v3_uses_server_v1_family")
        let fixtureRoot = root.appendingPathComponent("Preview")
        try PocketAppFileSnapshot(rootDirectory: fixtureRoot, files: files, identities: [:]).materialize(at: fixtureRoot)
        let fixture = try PocketAppPackageRuntime().load(directory: fixtureRoot)
        let validation = try await PocketGeneratedPreviewValidator.validate(fixture)
        try check(validation.contains("isolated-native-render"), "isolated_native_preview")
        var invalidFiles = files
        var invalidManifest = try JSONSerialization.jsonObject(with: invalidFiles["manifest.json"]!) as! [String: Any]
        invalidManifest["surfaces"] = [["id": "main", "kind": "html", "source": "views/main.html"]]
        invalidFiles["manifest.json"] = try JSONSerialization.data(withJSONObject: invalidManifest, options: [.sortedKeys])
        invalidFiles.removeValue(forKey: "surfaces/main.surface.json")
        invalidFiles["views/main.html"] = Data("<main style='width:1400px;min-width:1400px!important;max-width:none!important'>はみ出す画面</main>".utf8)
        let invalidRoot = root.appendingPathComponent("InvalidPreview")
        try PocketAppFileSnapshot(rootDirectory: invalidRoot, files: invalidFiles, identities: [:]).materialize(at: invalidRoot)
        let invalidPackage = try PocketAppPackageRuntime().load(directory: invalidRoot)
        do {
            _ = try await PocketGeneratedPreviewValidator.validate(invalidPackage)
            throw PocketPreviewValidationError(code: "overflow_was_accepted")
        } catch let error as PocketPreviewValidationError {
            try check(error.code == "horizontal_overflow", "real_web_overflow_rejected:" + error.code)
        }
        print("PASS Pocket App OS: \(checks) checks; background jobs, confirmation/session/revision binding, protected standards, shared UI, uninstall/restore data, voice settings, isolated rendering")
    }
}
