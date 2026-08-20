import AppKit
import Darwin
import Foundation
import SwiftUI

enum CapabilityBrokerVerificationCommand {
    private static let goldenPlanDigest = "sha256:d098ea1b5f9f70e91486fd53229e7ddb68f73a9952ab94f17eed27cdeeb6413f"

    @MainActor
    static func run() -> Never {
        Task { @MainActor in
            do {
                try await verify()
                print("broker_verify=ok")
                print("broker_registry_descriptors=15")
                print("broker_available_handlers=14")
                print("broker_calculator_evaluate=ok")
                print("broker_sticky_lifecycle=ok")
                print("broker_today_focus=ok")
                print("broker_pocket_app=ok")
                print("broker_pocket_app_declared_tests=4")
                print("broker_pocket_app_layout_cases=16")
                print("broker_concurrent_duplicate=ok")
                print("broker_negative_cases=11")
                print("broker_golden_plan_digest=\(goldenPlanDigest)")
                Darwin.exit(0)
            } catch {
                fputs("broker_verify=failed\n", stderr)
                fputs("error=\(String(describing: error))\n", stderr)
                Darwin.exit(1)
            }
        }
        RunLoop.main.run()
        Darwin.exit(1)
    }

    @MainActor
    private static func verify() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoverpocket-broker-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let defaultsSuite = "HoverPocketBrokerVerify.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            throw BrokerVerificationFailure("feature_defaults_suite")
        }
        defaults.removePersistentDomain(forName: defaultsSuite)
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        try require(!AppSettings(defaults: defaults).aiNativeEnabled, "feature_default_off")
        let noteID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let timerStore = TimerStore(
            storageDirectory: root.appendingPathComponent("timer", isDirectory: true),
            observesWake: false,
            persistenceEnabled: true
        )
        let stickyStore = StickyNotesStore(
            storageDirectory: root.appendingPathComponent("sticky", isDirectory: true)
        )
        let calendar = BrokerFakeCalendarDataSource(now: now)
        let handlers = try makeHandlers(
            calendar: calendar,
            timerStore: timerStore,
            stickyStore: stickyStore,
            noteID: noteID
        )
        let brokerRoot = root.appendingPathComponent("broker", isDirectory: true)
        let registry = try CapabilityRegistry(handlers: handlers)
        let audit = try CapabilityBrokerAuditLog(rootDirectory: brokerRoot)
        let broker = CapabilityBroker(
            registry: registry,
            ledger: try CapabilityBrokerLedger(rootDirectory: brokerRoot),
            auditLog: audit
        )

        try require(registry.descriptorKeys.count == 15, "registry_descriptor_count")
        try require(registry.availableHandlerKeys.count == 14, "registry_handler_count")
        try require(
            registry.descriptor(PocketCapabilityKeys.stickyDelete)?.approvalPolicy == .strongPerCall,
            "sticky_delete_strong_approval"
        )
        try verifyStrongPerCallIsolation(broker: broker, noteID: noteID, now: now)
        do {
            try registry.descriptor(PocketCapabilityKeys.stickyArchive)?.validateOutput([
                "noteId": .string(noteID.uuidString),
                "state": .string("active"),
                "updatedAt": .string(CapabilityDateCodec.string(from: now))
            ])
            throw BrokerVerificationFailure("sticky_archive_wrong_postcondition_accepted")
        } catch CapabilityBrokerError.invalidPlan {
        }
        try verifyGoldenDigest(now: now)
        try verifyCalendarCreateEventBody(now: now)
        try verifyCalendarIdempotencyEquivalence(now: now)
        do {
            _ = try registry.resolve(PocketCapabilityKeys.nativeAuthority)
            throw BrokerVerificationFailure("native_authority_resolved")
        } catch CapabilityBrokerError.runtimeProhibited {
        }

        try await verifyCalculator(broker: broker, now: now)
        try await verifyStickyLifecycle(
            broker: broker,
            store: stickyStore,
            noteID: noteID,
            now: now
        )

        let invalidArgumentsPlan = CapabilityExecutionPlan(
            id: "invalid-extra-argument-plan",
            createdAt: now,
            origin: .text,
            principal: CapabilityPrincipal(userID: "user-broker-fixture"),
            appContext: nil,
            steps: [CapabilityPlanStep(
                id: "startTimer",
                capability: PocketCapabilityKeys.timerStart,
                arguments: [
                    "durationSeconds": .integer(1_500),
                    "title": .string("Focus"),
                    "sourceRef": .string("primary:event"),
                    "unexpected": .bool(true)
                ],
                idempotencyKey: "invalid-extra-argument-0001",
                dependencies: []
            )],
            requiredPermissions: ["timer.write"]
        )
        do {
            _ = try broker.prepare(
                invalidArgumentsPlan,
                permissions: CapabilityPermissionSet(
                    principal: invalidArgumentsPlan.principal,
                    permissions: ["timer.write"]
                ),
                now: now
            )
            throw BrokerVerificationFailure("extra_argument_accepted")
        } catch CapabilityBrokerError.invalidPlan {
        }

        let principal = CapabilityPrincipal(userID: "user-broker-fixture")
        let allPermissions = CapabilityPermissionSet(
            principal: principal,
            permissions: ["calendar.events.read", "sticky.write", "timer.write"]
        )
        let adapter = TodayFocusTextAdapter(broker: broker)
        let events = try await adapter.listToday(
            timezone: TimeZone(identifier: "UTC")!,
            principal: principal,
            permissions: allPermissions,
            now: now
        )
        try require(events.count == 1, "calendar_read")
        try require(events[0].eventRef == "primary:sensitive-event-ref", "calendar_event_ref")
        let ledgerURL = brokerRoot.appendingPathComponent("capability-broker-ledger.json")
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            let ledgerText = String(data: try Data(contentsOf: ledgerURL), encoding: .utf8) ?? ""
            try require(!ledgerText.contains("Sensitive Calendar Title"), "private_read_ledger_title")
            try require(!ledgerText.contains("sensitive-event-ref"), "private_read_ledger_ref")
        }
        let tokyoBoundary = ISO8601DateFormatter().date(from: "2026-08-14T16:00:00Z")!
        let localDateDraft = try adapter.prepareFocus(
            event: events[0],
            durationSeconds: 1_500,
            purpose: "local-date-purpose",
            principal: principal,
            permissions: allPermissions,
            now: tokyoBoundary,
            timeZone: TimeZone(identifier: "Asia/Tokyo")!
        )
        try require(
            localDateDraft.plan.steps[1].arguments["stableKey"] == .string("today-focus:2026-08-15"),
            "today_focus_local_date_key"
        )
        try require(
            TodayFocusApprovalText.sanitize("会議\n承認済み\u{202E}偽装") == "会議 承認済み 偽装",
            "approval_text_sanitized"
        )
        let canonicalDraft = try adapter.prepareFocus(
            event: events[0],
            durationSeconds: 1_500,
            purpose: "会議\n承認済み\u{202E}偽装",
            principal: principal,
            permissions: allPermissions,
            now: now
        )
        try require(canonicalDraft.approvalText == "会議 承認済み 偽装", "approval_text_draft")
        try require(
            canonicalDraft.plan.steps[0].arguments["title"] == .string(canonicalDraft.approvalText),
            "approval_timer_exact"
        )
        try require(
            canonicalDraft.plan.steps[1].arguments["body"] == .string(canonicalDraft.approvalText),
            "approval_sticky_exact"
        )
        let longApprovalDraft = try adapter.prepareFocus(
            event: events[0],
            durationSeconds: 1_500,
            purpose: String(repeating: "長", count: 100),
            principal: principal,
            permissions: allPermissions,
            now: now
        )
        try require(longApprovalDraft.approvalText.unicodeScalars.count == 80, "approval_text_bounded")
        try require(
            longApprovalDraft.plan.steps[0].arguments["title"] == .string(longApprovalDraft.approvalText),
            "approval_timer_long_exact"
        )
        try require(
            longApprovalDraft.plan.steps[1].arguments["body"] == .string(longApprovalDraft.approvalText),
            "approval_sticky_long_exact"
        )

        let invalidAuditMarker = "private-invalid-plan-marker"
        let invalidAuditPlan = CapabilityExecutionPlan(
            id: String(repeating: "x", count: 256) + invalidAuditMarker,
            createdAt: now,
            origin: .text,
            principal: principal,
            appContext: nil,
            steps: localDateDraft.plan.steps,
            requiredPermissions: localDateDraft.plan.requiredPermissions
        )
        do {
            _ = try broker.prepare(invalidAuditPlan, permissions: allPermissions, now: now)
            throw BrokerVerificationFailure("oversized_plan_accepted")
        } catch CapabilityBrokerError.invalidPlan {
        }
        let invalidVersionMarker = "private-version-marker"
        let appID = "com.hoverpocket.fixture"
        let appPrincipal = CapabilityPrincipal(userID: principal.userID, pocketAppID: appID)
        let invalidVersionPlan = CapabilityExecutionPlan(
            id: "invalid-version-plan",
            createdAt: now,
            origin: .pocketSurface,
            principal: appPrincipal,
            appContext: CapabilityAppContext(
                id: appID,
                version: "1.0.0-" + String(repeating: "a", count: 80) + invalidVersionMarker,
                manifestDigest: "sha256:" + String(repeating: "a", count: 64)
            ),
            steps: localDateDraft.plan.steps,
            requiredPermissions: localDateDraft.plan.requiredPermissions
        )
        do {
            _ = try broker.prepare(
                invalidVersionPlan,
                permissions: CapabilityPermissionSet(principal: appPrincipal, permissions: allPermissions.permissions),
                now: now
            )
            throw BrokerVerificationFailure("oversized_app_version_accepted")
        } catch CapabilityBrokerError.invalidPlan {
        }

        do {
            let denied = CapabilityPermissionSet(principal: principal, permissions: ["timer.write"])
            _ = try adapter.prepareFocus(
                event: events[0],
                durationSeconds: 1_500,
                purpose: "secret-purpose-denied",
                principal: principal,
                permissions: denied,
                now: now
            )
            throw BrokerVerificationFailure("permission_missing_accepted")
        } catch CapabilityBrokerError.permissionDenied {
        }
        try require(timerStore.runningTimers.isEmpty && stickyStore.notes.isEmpty, "permission_no_write")

        let rejected = try adapter.prepareFocus(
            event: events[0],
            durationSeconds: 1_500,
            purpose: "secret-purpose-rejected",
            principal: principal,
            permissions: allPermissions,
            now: now
        )
        guard let rejectedRequest = rejected.preparation.approvalRequest else {
            throw BrokerVerificationFailure("approval_request_missing")
        }
        do {
            _ = try broker.decideApproval(
                requestID: rejectedRequest.id,
                planDigest: rejected.preparation.planDigest,
                decision: .reject,
                now: now
            )
            throw BrokerVerificationFailure("approval_reject_accepted")
        } catch CapabilityBrokerError.approvalRejected {
        }
        try require(timerStore.runningTimers.isEmpty && stickyStore.notes.isEmpty, "reject_no_write")

        let expired = try adapter.prepareFocus(
            event: events[0],
            durationSeconds: 1_500,
            purpose: "secret-purpose-expired",
            principal: principal,
            permissions: allPermissions,
            now: now
        )
        guard let expiredRequest = expired.preparation.approvalRequest else {
            throw BrokerVerificationFailure("expiry_request_missing")
        }
        do {
            _ = try broker.decideApproval(
                requestID: expiredRequest.id,
                planDigest: expired.preparation.planDigest,
                decision: .approve,
                now: now.addingTimeInterval(301)
            )
            throw BrokerVerificationFailure("expired_approval_accepted")
        } catch CapabilityBrokerError.approvalExpired {
        }

        let tamper = try adapter.prepareFocus(
            event: events[0],
            durationSeconds: 1_500,
            purpose: "secret-purpose-original",
            principal: principal,
            permissions: allPermissions,
            now: now
        )
        guard let tamperRequest = tamper.preparation.approvalRequest else {
            throw BrokerVerificationFailure("tamper_request_missing")
        }
        let tamperGrant = try broker.decideApproval(
            requestID: tamperRequest.id,
            planDigest: tamper.preparation.planDigest,
            decision: .approve,
            now: now
        )
        let tamperedPlan = replacingPurpose(in: tamper.plan, with: "secret-purpose-tampered")
        do {
            _ = try await broker.execute(
                tamperedPlan,
                permissions: allPermissions,
                approvalGrant: tamperGrant,
                now: now
            )
            throw BrokerVerificationFailure("approved_plan_tamper_accepted")
        } catch CapabilityBrokerError.approvalInvalid {
        }
        try require(timerStore.runningTimers.isEmpty && stickyStore.notes.isEmpty, "tamper_no_write")

        let approved = try adapter.prepareFocus(
            event: events[0],
            durationSeconds: 1_500,
            purpose: "secret-purpose-approved",
            principal: principal,
            permissions: allPermissions,
            now: now
        )
        guard let approvedRequest = approved.preparation.approvalRequest else {
            throw BrokerVerificationFailure("approval_request_missing")
        }
        try require(approvedRequest.effects.count == 2, "approval_effect_count")
        let grant = try broker.decideApproval(
            requestID: approvedRequest.id,
            planDigest: approved.preparation.planDigest,
            decision: .approve,
            now: now
        )
        let receipt = try await broker.execute(
            approved.plan,
            permissions: allPermissions,
            approvalGrant: grant,
            now: now
        )
        try require(receipt.status == .succeeded, "today_focus_status")
        try require(receipt.steps.count == 2, "today_focus_receipts")
        try require(receipt.steps.allSatisfy { $0.readback.status == .verified }, "today_focus_readback")
        try require(timerStore.runningTimers.count == 1, "today_focus_timer_effect")
        try require(stickyStore.notes.count == 1, "today_focus_sticky_effect")
        try require(stickyStore.note(id: noteID)?.body == "secret-purpose-approved", "today_focus_sticky_body")

        let replayBroker = CapabilityBroker(
            registry: registry,
            ledger: try CapabilityBrokerLedger(rootDirectory: brokerRoot),
            auditLog: try CapabilityBrokerAuditLog(rootDirectory: brokerRoot)
        )
        let replay = try await replayBroker.execute(
            approved.plan,
            permissions: allPermissions,
            approvalGrant: nil,
            now: now.addingTimeInterval(1)
        )
        try require(replay.replayed, "workflow_replay_flag")
        try require(replay.planDigest == receipt.planDigest, "workflow_replay_digest")
        try require(timerStore.runningTimers.count == 1 && stickyStore.notes.count == 1, "workflow_replay_single_effect")

        let conflictingPlan = replacingPurpose(in: approved.plan, with: "secret-purpose-conflict")
        do {
            _ = try await replayBroker.execute(
                conflictingPlan,
                permissions: allPermissions,
                approvalGrant: nil,
                now: now.addingTimeInterval(2)
            )
            throw BrokerVerificationFailure("workflow_idempotency_conflict_accepted")
        } catch CapabilityBrokerError.idempotencyConflict {
        }

        let nextDraft = try adapter.prepareFocus(
            event: events[0],
            durationSeconds: 600,
            purpose: "secret-purpose-next",
            principal: principal,
            permissions: allPermissions,
            now: now
        )
        do {
            _ = try await broker.execute(
                nextDraft.plan,
                permissions: allPermissions,
                approvalGrant: grant,
                now: now
            )
            throw BrokerVerificationFailure("approval_replay_accepted")
        } catch CapabilityBrokerError.approvalReplayed {
        }

        let timerCountBeforeConcurrent = timerStore.runningTimers.count
        let concurrent = try adapter.prepareFocus(
            event: events[0],
            durationSeconds: 300,
            purpose: "secret-purpose-concurrent",
            principal: principal,
            permissions: allPermissions,
            now: now.addingTimeInterval(3)
        )
        guard let concurrentRequest = concurrent.preparation.approvalRequest else {
            throw BrokerVerificationFailure("concurrent_approval_request")
        }
        let concurrentGrant = try broker.decideApproval(
            requestID: concurrentRequest.id,
            planDigest: concurrent.preparation.planDigest,
            decision: .approve,
            now: now.addingTimeInterval(3)
        )
        async let firstConcurrent = broker.execute(
            concurrent.plan,
            permissions: allPermissions,
            approvalGrant: concurrentGrant,
            now: now.addingTimeInterval(3)
        )
        async let secondConcurrent = broker.execute(
            concurrent.plan,
            permissions: allPermissions,
            approvalGrant: concurrentGrant,
            now: now.addingTimeInterval(3)
        )
        let concurrentReceipts = try await [firstConcurrent, secondConcurrent]
        try require(concurrentReceipts.filter(\.replayed).count == 1, "concurrent_replay_count")
        try require(concurrentReceipts.allSatisfy { $0.status == .succeeded }, "concurrent_receipt_status")
        try require(
            timerStore.runningTimers.count == timerCountBeforeConcurrent + 1,
            "concurrent_single_timer_effect"
        )

        let auditText = String(data: try audit.combinedData(), encoding: .utf8) ?? ""
        for forbidden in [
            "Sensitive Calendar Title",
            "sensitive-event-ref",
            "secret-purpose-approved",
            "secret-purpose-rejected",
            "secret-purpose-concurrent",
            principal.userID
        ] {
            try require(!auditText.contains(forbidden), "audit_redaction_\(forbidden)")
        }
        try require(auditText.contains("principal:sha256:"), "audit_principal_digest")
        try require(auditText.contains("\"idempotencyReplay\":true"), "audit_replay")
        try require(auditText.contains("\"eventType\":\"authorization_decision\""), "authorization_audit")
        try require(auditText.contains("CAPABILITY_APPROVAL_REJECTED"), "authorization_reject_audit")
        try require(auditText.contains("\"planDigest\":\"unavailable\""), "invalid_plan_digest_audit")
        try require(auditText.contains("\"planID\":\"invalid\"") || auditText.contains("\"planId\":\"invalid\""), "invalid_plan_id_audit")
        try require(!auditText.contains(invalidAuditMarker), "invalid_plan_audit_redaction")
        try require(!auditText.contains(invalidVersionMarker), "invalid_version_audit_redaction")
        let durableLedgerText = String(data: try Data(contentsOf: ledgerURL), encoding: .utf8) ?? ""
        for forbidden in ["secret-purpose-approved", "secret-purpose-concurrent", "Sensitive Calendar Title"] {
            try require(!durableLedgerText.contains(forbidden), "ledger_redaction_\(forbidden)")
        }

        try await verifyPocketAppExecution(root: root, calendar: calendar, now: now)
        try await verifyTodayFocusActivationRevocation(
            root: root,
            now: now,
            principal: principal
        )
        try await verifyPartialRollback(root: root, now: now, principal: principal)
        try await verifyCurrentStepRollback(root: root, now: now, principal: principal)
        try await verifyCancellationAfterSuccessfulStep(root: root, now: now, principal: principal)
        try await verifyTimeout(root: root, now: now, principal: principal)
    }

    @MainActor
    private static func verifyPocketAppExecution(
        root: URL,
        calendar: BrokerFakeCalendarDataSource,
        now: Date
    ) async throws {
        guard let resourceRoot = Bundle.module.resourceURL else {
            throw BrokerVerificationFailure("pocket_app_bundle")
        }
        let packageRoot = resourceRoot
            .appendingPathComponent("PocketApps", isDirectory: true)
            .appendingPathComponent("local.example.today-focus", isDirectory: true)
        let package = try PocketAppPackageRuntime().load(directory: packageRoot)
        let timerStore = TimerStore(
            storageDirectory: root.appendingPathComponent("pocket-app-timer", isDirectory: true),
            observesWake: false,
            persistenceEnabled: true
        )
        let stickyStore = StickyNotesStore(
            storageDirectory: root.appendingPathComponent("pocket-app-sticky", isDirectory: true)
        )
        let noteID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        let handlers = try makeHandlers(
            calendar: calendar,
            timerStore: timerStore,
            stickyStore: stickyStore,
            noteID: noteID
        )
        let brokerRoot = root.appendingPathComponent("pocket-app-broker", isDirectory: true)
        let broker = CapabilityBroker(
            registry: try CapabilityRegistry(handlers: handlers),
            ledger: try CapabilityBrokerLedger(rootDirectory: brokerRoot),
            auditLog: try CapabilityBrokerAuditLog(rootDirectory: brokerRoot)
        )
        let stateRoot = root.appendingPathComponent("pocket-app-user-state", isDirectory: true)
        let userStateStore = try PocketAppUserStateStore(
            packageID: package.manifest.id,
            stateProperties: package.stateProperties,
            rootDirectory: stateRoot
        )
        let runtime = PocketAppExecutionRuntime(
            package: package,
            broker: broker,
            userID: "pocket-app-user",
            grantedPermissions: ["calendar.events.read", "sticky.read", "sticky.write", "timer.read", "timer.write"],
            timeZone: TimeZone(identifier: "Asia/Tokyo")!,
            userStateStore: userStateStore
        )
        let hostModel = try PocketSurfaceHostModel(runtime: runtime, surfaceID: "main")
        let generatedSurfaceRegistry = PocketSurfaceRegistry()
        let runtimeReadback = PocketAppRuntimeReadback(
            appID: package.manifest.id,
            version: package.manifest.version,
            packageDigest: package.manifestDigest,
            effectivePermissions: [
                "calendar.events.read",
                "sticky.read",
                "sticky.write",
                "timer.read",
                "timer.write"
            ]
        )
        generatedSurfaceRegistry.activate(
            runtimeReadback,
            runtimeHandle: runtime,
            surfaceIDs: ["main"]
        )
        guard let firstSurfaceModel = try generatedSurfaceRegistry.model(
            appID: package.manifest.id,
            surfaceID: "main"
        ), let reopenedSurfaceModel = try generatedSurfaceRegistry.model(
            appID: package.manifest.id,
            surfaceID: "main"
        ) else {
            throw BrokerVerificationFailure("pocket_app_surface_reopen_model")
        }
        try require(
            firstSurfaceModel !== reopenedSurfaceModel,
            "pocket_app_surface_reopen_refreshes_queries"
        )
        await firstSurfaceModel.load(now: now)
        await reopenedSurfaceModel.load(now: now)
        try require(
            !firstSurfaceModel.stringValue(for: "$state.selectedEventRef").isEmpty
                && !reopenedSurfaceModel.stringValue(for: "$state.selectedEventRef").isEmpty,
            "pocket_app_surface_reopen_queries_loaded"
        )
        generatedSurfaceRegistry.deactivate(appID: package.manifest.id)
        try require(
            !firstSurfaceModel.activationAvailable && !reopenedSurfaceModel.activationAvailable,
            "pocket_app_surface_reopen_models_revoked"
        )
        try require(hostModel.integerValue(for: "$input.durationSeconds") == 1_500, "pocket_app_surface_default")
        await hostModel.load(now: now)
        try require(
            !hostModel.choices(
                query: "calendar.events.list@1",
                arguments: [
                    "range": .string("today"),
                    "timezone": .string("$context.timezone")
                ]
            ).isEmpty,
            "pocket_app_query_binding_choices"
        )
        try require(
            PocketSurfaceHostModel.queryIdentity(
                reference: "calendar.events.list@1",
                arguments: ["timeZone": .string("UTC")]
            ) != PocketSurfaceHostModel.queryIdentity(
                reference: "calendar.events.list@1",
                arguments: ["timeZone": .string("Asia/Tokyo")]
            ),
            "pocket_app_query_binding_arguments_isolated"
        )
        try verifyPocketSurfaceLayoutMatrix(model: hostModel)
        let selectedEventRef = hostModel.stringValue(for: "$state.selectedEventRef")
        try require(!selectedEventRef.isEmpty, "pocket_app_surface_selection")
        hostModel.updateString(
            String(repeating: "x", count: PocketAppUserStateStore.maximumValueScalars + 1),
            binding: "$state.selectedEventRef"
        )
        try require(
            hostModel.stringValue(for: "$state.selectedEventRef") == selectedEventRef
                && userStateStore.snapshot()["selectedEventRef"] == .string(selectedEventRef),
            "pocket_app_surface_failed_state_write_not_published"
        )
        try require(
            !PocketSurfaceHostModel.acceptsWorkflowInput(.null, type: "boolean")
                && !PocketSurfaceHostModel.acceptsWorkflowInput(.string("true"), type: "boolean")
                && PocketSurfaceHostModel.acceptsWorkflowInput(.bool(true), type: "boolean"),
            "pocket_app_surface_workflow_input_exact_type"
        )
        let reloadedStateStore = try PocketAppUserStateStore(
            packageID: package.manifest.id,
            stateProperties: package.stateProperties,
            rootDirectory: stateRoot
        )
        try require(
            reloadedStateStore.snapshot()["selectedEventRef"] == .string(selectedEventRef),
            "pocket_app_surface_state_persistence"
        )
        let namespaceModel = try PocketSurfaceHostModel(runtime: runtime, surfaceID: "main")
        namespaceModel.updateString("input-value", binding: "$input.selectedEventRef")
        namespaceModel.updateString("state-value", binding: "$state.selectedEventRef")
        try require(
            namespaceModel.stringValue(for: "$input.selectedEventRef") == "input-value"
                && namespaceModel.stringValue(for: "$state.selectedEventRef") == "state-value",
            "pocket_app_input_state_namespaces_independent"
        )
        let typedStateStore = try PocketAppUserStateStore(
            packageID: "local.example.typed-state",
            allowedKeys: ["enabled", "label", "ratio"],
            rootDirectory: stateRoot
        )
        try typedStateStore.setValue(.bool(true), for: "enabled")
        try typedStateStore.setValue(.string("Saved"), for: "label")
        try typedStateStore.setValue(.number(1.5), for: "ratio")
        let typedStateReadback = try PocketAppUserStateStore(
            packageID: "local.example.typed-state",
            allowedKeys: ["enabled", "label", "ratio"],
            rootDirectory: stateRoot
        ).snapshot()
        try require(
            typedStateReadback["enabled"] == .bool(true)
                && typedStateReadback["label"] == .string("Saved")
                && typedStateReadback["ratio"] == .number(1.5),
            "pocket_app_typed_state_persistence"
        )
        let migratedStateTypes: [String: Set<String>] = [
            "enabled": ["string"],
            "label": ["string"],
            "ratio": ["integer"]
        ]
        let migratedStateStore = try PocketAppUserStateStore(
            packageID: "local.example.typed-state",
            propertyTypes: migratedStateTypes,
            rootDirectory: stateRoot
        )
        try require(
            migratedStateStore.snapshot() == ["label": .string("Saved")],
            "pocket_app_state_schema_migration"
        )
        let migratedStateReadback = try PocketAppUserStateStore(
            packageID: "local.example.typed-state",
            propertyTypes: migratedStateTypes,
            rootDirectory: stateRoot
        ).snapshot()
        try require(
            migratedStateReadback == ["label": .string("Saved")],
            "pocket_app_state_schema_migration_persisted"
        )
        do {
            try migratedStateStore.setValue(.bool(true), for: "label")
            throw BrokerVerificationFailure("pocket_app_state_schema_write_accepted")
        } catch PocketAppUserStateStoreError.invalidValue {
        }
        let constrainedStateProperties: [String: PocketAppStatePropertySchema] = [
            "focusDate": PocketAppStatePropertySchema(
                types: ["string"],
                isRequired: true,
                format: "date",
                maximumLength: 10
            )
        ]
        let constrainedStateStore = try PocketAppUserStateStore(
            packageID: "local.example.constrained-state",
            stateProperties: constrainedStateProperties,
            rootDirectory: stateRoot
        )
        try constrainedStateStore.setValue(.string("2026-08-20"), for: "focusDate")
        do {
            try constrainedStateStore.setValue(.string("2026-02-30"), for: "focusDate")
            throw BrokerVerificationFailure("pocket_app_state_date_constraint_accepted")
        } catch PocketAppUserStateStoreError.invalidValue {
        }
        do {
            try constrainedStateStore.setValue(.string("2026-08-200"), for: "focusDate")
            throw BrokerVerificationFailure("pocket_app_state_max_length_constraint_accepted")
        } catch PocketAppUserStateStoreError.invalidValue {
        }
        do {
            try constrainedStateStore.setValue(nil, for: "focusDate")
            throw BrokerVerificationFailure("pocket_app_state_required_removal_accepted")
        } catch PocketAppUserStateStoreError.invalidValue {
        }
        let optionalRequiredLoadStore = try PocketAppUserStateStore(
            packageID: "local.example.required-load-state",
            propertyTypes: ["focusDate": ["string"]],
            rootDirectory: stateRoot
        )
        try optionalRequiredLoadStore.setValue(.string("2026-08-20"), for: "focusDate")
        try optionalRequiredLoadStore.setValue(nil, for: "focusDate")
        do {
            _ = try PocketAppUserStateStore(
                packageID: "local.example.required-load-state",
                stateProperties: constrainedStateProperties,
                rootDirectory: stateRoot
            )
            throw BrokerVerificationFailure("pocket_app_state_required_load_accepted")
        } catch PocketAppUserStateStoreError.invalidDocument {
        }
        let isolatedStateStore = try PocketAppUserStateStore(
            packageID: "local.example.state-isolated-a",
            allowedKeys: ["label"],
            rootDirectory: stateRoot
        )
        let otherStateStore = try PocketAppUserStateStore(
            packageID: "local.example.state-isolated-b",
            allowedKeys: ["label"],
            rootDirectory: stateRoot
        )
        try otherStateStore.setString("other-app", for: "label")
        let isolatedDirectory = stateRoot.appendingPathComponent(
            "local.example.state-isolated-a",
            isDirectory: true
        )
        let isolatedBackup = stateRoot.appendingPathComponent(
            "local.example.state-isolated-a-backup",
            isDirectory: true
        )
        let otherDirectory = stateRoot.appendingPathComponent(
            "local.example.state-isolated-b",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: isolatedDirectory, to: isolatedBackup)
        try FileManager.default.createSymbolicLink(
            at: isolatedDirectory,
            withDestinationURL: otherDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: isolatedDirectory)
            try? FileManager.default.moveItem(at: isolatedBackup, to: isolatedDirectory)
        }
        do {
            try isolatedStateStore.setString("cross-app-write", for: "label")
            throw BrokerVerificationFailure("pocket_app_state_directory_swap_accepted")
        } catch PocketAppUserStateStoreError.persistenceFailed {
        }
        let otherStateReadback = try PocketAppUserStateStore(
            packageID: "local.example.state-isolated-b",
            allowedKeys: ["label"],
            rootDirectory: stateRoot
        ).snapshot()
        try require(
            otherStateReadback["label"] == .string("other-app"),
            "pocket_app_state_directory_swap_isolated"
        )
        do {
            try reloadedStateStore.setString("forbidden", for: "unknown")
            throw BrokerVerificationFailure("pocket_app_unknown_state_key_accepted")
        } catch PocketAppUserStateStoreError.invalidKey {
        }
        try require(!hostModel.stringValue(for: "$input.purpose").isEmpty, "pocket_app_surface_title_target")
        hostModel.updateString("safe\ntext\u{202E}", binding: "$input.purpose", maximumLength: 80)
        try require(hostModel.stringValue(for: "$input.purpose") == "safe text", "pocket_app_surface_sanitize")
        try require(hostModel.canPrepare(workflowID: "startFocus"), "pocket_app_surface_ready")
        hostModel.prepare(workflowID: "startFocus")
        try require(hostModel.showsApproval, "pocket_app_surface_approval")
        try require(hostModel.approvalText.contains("safe text"), "pocket_app_surface_approval_exact")
        hostModel.reject()
        let query = try await runtime.query(
            reference: "calendar.events.list@1",
            arguments: [
                "range": .string("today"),
                "timezone": .string("$context.timezone")
            ],
            now: now
        )
        guard case .array(let events)? = query["events"],
              case .object(let event)? = events.first,
              case .string(let eventRef)? = event["eventRef"] else {
            throw BrokerVerificationFailure("pocket_app_query")
        }
        do {
            _ = try await runtime.query(
                reference: "timer.countdown.start@1",
                arguments: [
                    "durationSeconds": .number(60),
                    "title": .string("must-not-run"),
                    "sourceRef": .null
                ],
                now: now
            )
            throw BrokerVerificationFailure("pocket_app_query_write_not_rejected")
        } catch let error as CapabilityBrokerError {
            guard case .invalidPlan("query_effect") = error else { throw error }
        }
        let tokyoBoundary = ISO8601DateFormatter().date(from: "2026-08-14T16:00:00Z")!
        let presentationDraft = try runtime.prepare(
            workflowID: "startFocus",
            inputs: [
                "selectedEventRef": .string(eventRef),
                "durationSeconds": .integer(1_500),
                "purpose": .string("表示\n偽装\u{202E}確認")
            ],
            now: tokyoBoundary
        )
        let canonicalPurpose = "表示 偽装 確認"
        try require(
            !PocketAppExecutionRuntime.supportsWorkflowPresentation(PocketCapabilityKeys.calendarList),
            "pocket_app_unpresentable_workflow_rejected"
        )
        try require(
            presentationDraft.plan.steps[0].arguments["title"] == .string(canonicalPurpose),
            "pocket_app_approval_timer_exact"
        )
        try require(
            presentationDraft.plan.steps[1].arguments["body"] == .string(canonicalPurpose),
            "pocket_app_approval_sticky_exact"
        )
        try require(
            PocketSurfaceHostModel.approvalSummary(presentationDraft).contains(canonicalPurpose),
            "pocket_app_approval_presentation_exact"
        )
        runtime.reject(presentationDraft, now: tokyoBoundary)
        let draft = try runtime.prepare(
            workflowID: "startFocus",
            inputs: [
                "selectedEventRef": .string(eventRef),
                "durationSeconds": .integer(1_500),
                "purpose": .string("pocket-app-purpose")
            ],
            now: tokyoBoundary
        )
        try require(draft.plan.origin == .pocketSurface, "pocket_app_origin")
        try require(draft.plan.principal.pocketAppID == package.manifest.id, "pocket_app_principal")
        try require(draft.plan.appContext?.manifestDigest == package.manifestDigest, "pocket_app_context")
        try require(
            draft.plan.steps[1].arguments["stableKey"] == .string("today-focus:2026-08-15"),
            "pocket_app_local_date"
        )
        let receipt = try await runtime.approveAndExecute(draft, now: tokyoBoundary)
        try require(receipt.status == .succeeded, "pocket_app_status")
        try require(receipt.steps.allSatisfy { $0.readback.status == .verified }, "pocket_app_readback")
        try require(
            PocketSurfaceHostModel.receiptSummary(receipt) == "Timer、Sticky Notesへ反映しました（2件確認済み）",
            "pocket_app_receipt_summary"
        )
        try require(timerStore.runningTimers.count == 1, "pocket_app_timer")
        try require(stickyStore.note(id: noteID)?.body == "pocket-app-purpose", "pocket_app_sticky")
        let replay = try await broker.execute(
            draft.plan,
            permissions: CapabilityPermissionSet(
                principal: draft.plan.principal,
                permissions: ["calendar.events.read", "sticky.read", "sticky.write", "timer.read", "timer.write"]
            ),
            approvalGrant: nil,
            now: tokyoBoundary.addingTimeInterval(1)
        )
        try require(replay.replayed, "pocket_app_replay")
        try require(timerStore.runningTimers.count == 1 && stickyStore.notes.count == 1, "pocket_app_replay_effect")
    }

    @MainActor
    private static func verifyPocketSurfaceLayoutMatrix(model: PocketSurfaceHostModel) throws {
        var cases = 0
        for panelSize in PanelSizeOption.allCases {
            let panel = PanelLayout.previewSize(for: panelSize)
            let contentSize = CGSize(width: panel.width, height: max(0, panel.height - 55))
            for textSize in PanelTextSizeOption.allCases {
                let view = PocketSurfaceHostView(model: model)
                    .environment(\.panelTextSize, textSize)
                    .frame(width: contentSize.width, height: contentSize.height)
                let host = NSHostingView(rootView: view)
                host.frame = CGRect(origin: .zero, size: contentSize)
                host.layoutSubtreeIfNeeded()
                let fitting = host.fittingSize
                try require(
                    fitting.width.isFinite
                    && fitting.height.isFinite
                    && fitting.width <= contentSize.width
                    && fitting.height <= contentSize.height,
                    "pocket_app_layout_\(panelSize.rawValue)_\(textSize.rawValue)"
                )
                cases += 1
            }
        }
        try require(cases == 16, "pocket_app_layout_matrix")
    }

    @MainActor
    private static func verifyStrongPerCallIsolation(
        broker: CapabilityBroker,
        noteID: UUID,
        now: Date
    ) throws {
        let principal = CapabilityPrincipal(userID: "user-strong-approval-fixture")
        let plan = CapabilityExecutionPlan(
            id: "strong-approval-batch-plan",
            createdAt: now,
            origin: .text,
            principal: principal,
            appContext: nil,
            steps: [
                CapabilityPlanStep(
                    id: "readNote",
                    capability: PocketCapabilityKeys.stickyStatus,
                    arguments: ["noteId": .string(noteID.uuidString)],
                    idempotencyKey: "strong-approval-read-key-0001",
                    dependencies: []
                ),
                CapabilityPlanStep(
                    id: "deleteNote",
                    capability: PocketCapabilityKeys.stickyDelete,
                    arguments: ["noteId": .string(noteID.uuidString)],
                    idempotencyKey: "strong-approval-delete-key-0001",
                    dependencies: ["readNote"]
                )
            ],
            requiredPermissions: ["sticky.delete", "sticky.read"]
        )
        do {
            _ = try broker.prepare(
                plan,
                permissions: CapabilityPermissionSet(
                    principal: principal,
                    permissions: ["sticky.delete", "sticky.read"]
                ),
                now: now
            )
            throw BrokerVerificationFailure("strong_per_call_batch_accepted")
        } catch CapabilityBrokerError.invalidPlan(let field) {
            try require(field == "strong_per_call", "strong_per_call_error")
        }
    }

    @MainActor
    private static func verifyCalculator(broker: CapabilityBroker, now: Date) async throws {
        let principal = CapabilityPrincipal(userID: "user-calculator-fixture")
        let plan = CapabilityExecutionPlan(
            id: "calculator-pure-plan",
            createdAt: now,
            origin: .text,
            principal: principal,
            appContext: nil,
            steps: [CapabilityPlanStep(
                id: "evaluate",
                capability: PocketCapabilityKeys.calculatorEvaluate,
                arguments: ["expression": .string("8 / 4 + 1")],
                idempotencyKey: "calculator-pure-key-0001",
                dependencies: []
            )],
            requiredPermissions: []
        )
        let permissions = CapabilityPermissionSet(principal: principal, permissions: [])
        let preparation = try broker.prepare(plan, permissions: permissions, now: now)
        try require(preparation.approvalRequest == nil, "calculator_approval_not_required")
        let receipt = try await broker.execute(
            plan,
            permissions: permissions,
            approvalGrant: nil,
            now: now
        )
        try require(receipt.status == .succeeded, "calculator_receipt_status")
        try require(receipt.steps.count == 1, "calculator_receipt_count")
        try require(receipt.steps[0].output == [
            "normalizedExpression": .string("8 / 4 + 1"),
            "result": .string("3")
        ], "calculator_receipt_output")
        try require(receipt.steps[0].readback.status == .verified, "calculator_readback")
        try require(receipt.steps[0].readback.strategy == .none, "calculator_readback_strategy")
        try require(receipt.steps[0].readback.observed == receipt.steps[0].output, "calculator_observed")
    }

    @MainActor
    private static func verifyStickyLifecycle(
        broker: CapabilityBroker,
        store: StickyNotesStore,
        noteID: UUID,
        now: Date
    ) async throws {
        _ = try store.upsertNote(
            stableKey: "broker-lifecycle-fixture",
            title: "Private title",
            body: "Private body",
            color: .yellow,
            id: noteID,
            at: now
        )
        let principal = CapabilityPrincipal(userID: "user-sticky-lifecycle-fixture")
        let archivePermissions = CapabilityPermissionSet(principal: principal, permissions: ["sticky.write"])
        let archivePlan = CapabilityExecutionPlan(
            id: "sticky-archive-plan",
            createdAt: now,
            origin: .text,
            principal: principal,
            appContext: nil,
            steps: [CapabilityPlanStep(
                id: "archiveNote",
                capability: PocketCapabilityKeys.stickyArchive,
                arguments: ["noteId": .string(noteID.uuidString)],
                idempotencyKey: "sticky-broker-archive-key-0001",
                dependencies: []
            )],
            requiredPermissions: ["sticky.write"]
        )
        let archivePreparation = try broker.prepare(archivePlan, permissions: archivePermissions, now: now)
        guard let archiveRequest = archivePreparation.approvalRequest else {
            throw BrokerVerificationFailure("sticky_archive_approval_missing")
        }
        let archiveGrant = try broker.decideApproval(
            requestID: archiveRequest.id,
            planDigest: archivePreparation.planDigest,
            decision: .approve,
            now: now
        )
        let archiveReceipt = try await broker.execute(
            archivePlan,
            permissions: archivePermissions,
            approvalGrant: archiveGrant,
            now: now
        )
        try require(archiveReceipt.status == .succeeded, "sticky_archive_receipt")
        try require(archiveReceipt.steps.first?.output?["state"] == .string("archived"), "sticky_archive_output")
        try require(archiveReceipt.steps.first?.readback.status == .verified, "sticky_archive_readback")
        try require(store.note(id: noteID)?.archivedAt == now, "sticky_archive_effect")

        let deletePermissions = CapabilityPermissionSet(principal: principal, permissions: ["sticky.delete"])
        let deletePlan = CapabilityExecutionPlan(
            id: "sticky-delete-plan",
            createdAt: now.addingTimeInterval(1),
            origin: .text,
            principal: principal,
            appContext: nil,
            steps: [CapabilityPlanStep(
                id: "deleteNote",
                capability: PocketCapabilityKeys.stickyDelete,
                arguments: ["noteId": .string(noteID.uuidString)],
                idempotencyKey: "sticky-broker-delete-key-0001",
                dependencies: []
            )],
            requiredPermissions: ["sticky.delete"]
        )
        let deletePreparation = try broker.prepare(
            deletePlan,
            permissions: deletePermissions,
            now: now.addingTimeInterval(1)
        )
        guard let deleteRequest = deletePreparation.approvalRequest else {
            throw BrokerVerificationFailure("sticky_delete_approval_missing")
        }
        let deleteGrant = try broker.decideApproval(
            requestID: deleteRequest.id,
            planDigest: deletePreparation.planDigest,
            decision: .approve,
            now: now.addingTimeInterval(1)
        )
        let deleteReceipt = try await broker.execute(
            deletePlan,
            permissions: deletePermissions,
            approvalGrant: deleteGrant,
            now: now.addingTimeInterval(1)
        )
        try require(deleteReceipt.status == .succeeded, "sticky_delete_receipt")
        try require(deleteReceipt.steps.first?.output?["state"] == .string("missing"), "sticky_delete_output")
        try require(deleteReceipt.steps.first?.readback.status == .verified, "sticky_delete_readback")
        try require(store.note(id: noteID) == nil, "sticky_delete_effect")
    }

    private static func verifyCalendarCreateEventBody(now: Date) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let draft = GoogleCalendarEventDraft(
            calendarID: "primary",
            eventID: nil,
            title: "Verify event",
            location: "",
            notes: "",
            start: now.addingTimeInterval(0.987),
            end: now.addingTimeInterval(3_600.987),
            isAllDay: false
        )
        let ordinaryBody = try GoogleCalendarAPIClient.createEventBody(from: draft, calendar: calendar)
        let ordinary = try JSONSerialization.jsonObject(with: ordinaryBody) as? [String: Any]
        try require(ordinary?["id"] == nil, "calendar_create_ordinary_id_omitted")

        let deterministicID = "hp0123456789abcdef"
        let idempotentBody = try GoogleCalendarAPIClient.createEventBody(
            from: draft,
            calendar: calendar,
            eventID: deterministicID
        )
        let idempotent = try JSONSerialization.jsonObject(with: idempotentBody) as? [String: Any]
        try require(idempotent?["id"] as? String == deterministicID, "calendar_create_idempotent_id")
    }

    @MainActor
    private static func verifyCalendarIdempotencyEquivalence(now: Date) throws {
        let draft = GoogleCalendarEventDraft(
            calendarID: "primary",
            eventID: nil,
            title: " Verify event ",
            location: " Room A ",
            notes: " Approved notes ",
            start: now,
            end: now.addingTimeInterval(3_600),
            isAllDay: false
        ).normalized()
        let observed = GoogleCalendarEventOccurrence(
            id: "primary:event",
            googleEventID: "event",
            calendarID: "primary",
            calendarTitle: "Primary",
            calendarColorHex: nil,
            calendarCanWrite: true,
            title: draft.normalizedTitle,
            location: draft.normalizedLocation,
            notes: draft.normalizedNotes,
            start: Date(timeIntervalSince1970: floor(draft.start.timeIntervalSince1970)),
            end: Date(timeIntervalSince1970: floor(draft.end.timeIntervalSince1970)),
            isAllDay: draft.isAllDay,
            htmlLink: nil,
            allDayStartDate: nil,
            allDayEndDate: nil
        )
        try require(GoogleCalendarStore.capabilityEventMatches(observed, draft: draft), "calendar_idempotency_match")
        try require(
            !GoogleCalendarStore.capabilityEventMatches(observedWith(observed, location: "Room B"), draft: draft),
            "calendar_idempotency_location_mismatch"
        )
        try require(
            !GoogleCalendarStore.capabilityEventMatches(observedWith(observed, notes: "Different notes"), draft: draft),
            "calendar_idempotency_notes_mismatch"
        )
        try require(
            !GoogleCalendarStore.capabilityEventMatches(
                observedWith(observed, start: observed.start.addingTimeInterval(1)),
                draft: draft
            ),
            "calendar_idempotency_second_mismatch"
        )

        let allDayDraft = GoogleCalendarEventDraft(
            calendarID: "primary",
            eventID: nil,
            title: "All day",
            location: "",
            notes: "",
            start: now,
            end: now.addingTimeInterval(86_400),
            isAllDay: true
        ).normalized()
        let allDayObserved = GoogleCalendarEventOccurrence(
            id: "primary:all-day",
            googleEventID: "all-day",
            calendarID: "primary",
            calendarTitle: "Primary",
            calendarColorHex: nil,
            calendarCanWrite: true,
            title: allDayDraft.normalizedTitle,
            location: allDayDraft.normalizedLocation,
            notes: allDayDraft.normalizedNotes,
            start: allDayDraft.start,
            end: allDayDraft.end,
            isAllDay: true,
            htmlLink: nil,
            allDayStartDate: calendarDateString(allDayDraft.start),
            allDayEndDate: calendarDateString(allDayDraft.end)
        )
        try require(
            GoogleCalendarStore.capabilityEventMatches(allDayObserved, draft: allDayDraft),
            "calendar_idempotency_all_day_match"
        )
    }

    private static func observedWith(
        _ event: GoogleCalendarEventOccurrence,
        location: String? = nil,
        notes: String? = nil,
        start: Date? = nil
    ) -> GoogleCalendarEventOccurrence {
        GoogleCalendarEventOccurrence(
            id: event.id,
            googleEventID: event.googleEventID,
            calendarID: event.calendarID,
            calendarTitle: event.calendarTitle,
            calendarColorHex: event.calendarColorHex,
            calendarCanWrite: event.calendarCanWrite,
            title: event.title,
            location: location ?? event.location,
            notes: notes ?? event.notes,
            start: start ?? event.start,
            end: event.end,
            isAllDay: event.isAllDay,
            htmlLink: event.htmlLink,
            allDayStartDate: event.allDayStartDate,
            allDayEndDate: event.allDayEndDate
        )
    }

    private static func calendarDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func verifyGoldenDigest(now: Date) throws {
        let plan = CapabilityExecutionPlan(
            id: "digest-fixture-plan",
            createdAt: now,
            origin: .text,
            principal: CapabilityPrincipal(userID: "user-broker-fixture"),
            appContext: nil,
            steps: [CapabilityPlanStep(
                id: "startTimer",
                capability: PocketCapabilityKeys.timerStart,
                arguments: [
                    "durationSeconds": .integer(1_500),
                    "sourceRef": .string("primary:event"),
                    "title": .string("Focus")
                ],
                idempotencyKey: "digest-fixture-timer-0001",
                dependencies: []
            )],
            requiredPermissions: ["timer.write"]
        )
        try require(
            CapabilityCanonicalJSON.planDigest(plan) == goldenPlanDigest,
            "golden_plan_digest"
        )
    }

    @MainActor
    private static func verifyPartialRollback(
        root: URL,
        now: Date,
        principal: CapabilityPrincipal
    ) async throws {
        let timerID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let timerStore = TimerStore(
            storageDirectory: root.appendingPathComponent("partial-timer", isDirectory: true),
            observesWake: false,
            persistenceEnabled: true
        )
        let handlers = try PocketCapabilityHandlerSet(handlers: [
            TimerCapabilityHandler(operation: .start, store: timerStore, idGenerator: { timerID }),
            TimerCapabilityHandler(operation: .get, store: timerStore),
            TimerCapabilityHandler(operation: .stop, store: timerStore),
            BrokerFailingStickyHandler()
        ])
        let brokerRoot = root.appendingPathComponent("partial-broker", isDirectory: true)
        let broker = CapabilityBroker(
            registry: try CapabilityRegistry(handlers: handlers),
            ledger: try CapabilityBrokerLedger(rootDirectory: brokerRoot),
            auditLog: try CapabilityBrokerAuditLog(rootDirectory: brokerRoot)
        )
        let permissions = CapabilityPermissionSet(principal: principal, permissions: ["sticky.write", "timer.write"])
        let event = TodayFocusCalendarEvent(
            eventRef: "event:partial",
            safeTitle: "Partial",
            start: now,
            end: now.addingTimeInterval(600)
        )
        let adapter = TodayFocusTextAdapter(broker: broker)
        let draft = try adapter.prepareFocus(
            event: event,
            durationSeconds: 600,
            purpose: "partial-secret",
            principal: principal,
            permissions: permissions,
            now: now
        )
        guard let request = draft.preparation.approvalRequest else {
            throw BrokerVerificationFailure("partial_approval_request")
        }
        let grant = try broker.decideApproval(
            requestID: request.id,
            planDigest: draft.preparation.planDigest,
            decision: .approve,
            now: now
        )
        let receipt = try await broker.execute(
            draft.plan,
            permissions: permissions,
            approvalGrant: grant,
            now: now
        )
        try require(receipt.status == .failed, "partial_compensated_status")
        try require(receipt.steps.first?.rollbackStatus == "succeeded", "partial_timer_rollback")
        try require(timerStore.runningTimers.isEmpty, "partial_timer_removed")
    }

    @MainActor
    private static func verifyTodayFocusActivationRevocation(
        root: URL,
        now: Date,
        principal: CapabilityPrincipal
    ) async throws {
        let timerHandler = BrokerBlockingTimerStartHandler()
        let handlers = try PocketCapabilityHandlerSet(handlers: [
            timerHandler,
            BrokerFailingStickyHandler()
        ])
        let brokerRoot = root.appendingPathComponent("activation-revocation-broker", isDirectory: true)
        let broker = CapabilityBroker(
            registry: try CapabilityRegistry(handlers: handlers),
            ledger: try CapabilityBrokerLedger(rootDirectory: brokerRoot),
            auditLog: try CapabilityBrokerAuditLog(rootDirectory: brokerRoot)
        )
        let permissions = CapabilityPermissionSet(
            principal: principal,
            permissions: ["sticky.write", "timer.write"]
        )
        let lease = PocketAppActivationLease()
        let adapter = TodayFocusTextAdapter(
            broker: broker,
            activationLease: lease
        )
        let draft = try adapter.prepareFocus(
            event: TodayFocusCalendarEvent(
                eventRef: "event:activation-revocation",
                safeTitle: "Activation revocation",
                start: now,
                end: now.addingTimeInterval(600)
            ),
            durationSeconds: 600,
            purpose: "activation-revocation",
            principal: principal,
            permissions: permissions,
            now: now
        )
        let execution = Task { @MainActor in
            try await adapter.approveAndExecute(
                draft,
                permissions: permissions,
                now: now
            )
        }
        for _ in 0..<100 where !timerHandler.entered {
            await Task.yield()
        }
        try require(timerHandler.entered, "today_focus_activation_entered")
        lease.invalidate()
        do {
            _ = try await execution.value
            throw BrokerVerificationFailure("today_focus_activation_result_returned")
        } catch is CancellationError {
        } catch PocketAppRuntimeActivationError.unavailable {
        }
        try require(timerHandler.wasCancelled, "today_focus_activation_handler_cancelled")
        try require(!timerHandler.didWrite, "today_focus_activation_no_stale_write")
    }

    @MainActor
    private static func verifyTimeout(
        root: URL,
        now: Date,
        principal: CapabilityPrincipal
    ) async throws {
        let key = PocketCapabilityKey(id: "verify.slow.read", version: 1)
        let descriptor = PocketCapabilityDescriptor(
            key: key,
            titleKey: "capability.verify.slow.read",
            effect: .privateRead,
            permissions: ["verify.read"],
            approvalPolicy: .permissionGrant,
            idempotency: .optional,
            limits: CapabilityLimits(
                timeoutMilliseconds: 10,
                maximumPayloadBytes: 128,
                maximumCallsPerMinute: 10
            ),
            readback: CapabilityReadbackPolicy(
                strategy: .sameStoreSnapshot,
                query: nil,
                matchFields: ["value"]
            ),
            rollbackAvailable: false,
            inputValidator: { try CapabilitySchemaValidation.exactKeys($0, []) },
            outputValidator: { output in
                try CapabilitySchemaValidation.exactKeys(output, ["value"])
                _ = try CapabilitySchemaValidation.string(output, "value", maximum: 16)
            }
        )
        let slowHandler = BrokerSlowReadHandler(key: key)
        let handlers = try PocketCapabilityHandlerSet(handlers: [slowHandler])
        let brokerRoot = root.appendingPathComponent("timeout-broker", isDirectory: true)
        let broker = CapabilityBroker(
            registry: try CapabilityRegistry(descriptors: [descriptor], handlers: handlers),
            ledger: try CapabilityBrokerLedger(rootDirectory: brokerRoot),
            auditLog: try CapabilityBrokerAuditLog(rootDirectory: brokerRoot)
        )
        let plan = CapabilityExecutionPlan(
            id: "timeout-plan",
            createdAt: now,
            origin: .text,
            principal: principal,
            appContext: nil,
            steps: [CapabilityPlanStep(
                id: "slowRead",
                capability: key,
                arguments: [:],
                idempotencyKey: "timeout-read-key-0001",
                dependencies: []
            )],
            requiredPermissions: ["verify.read"]
        )
        let receipt = try await broker.execute(
            plan,
            permissions: CapabilityPermissionSet(principal: principal, permissions: ["verify.read"]),
            approvalGrant: nil,
            now: now
        )
        try require(receipt.status == .unknown, "timeout_status")
        try require(receipt.steps.first?.safeError?.code == "CAPABILITY_TIMEOUT", "timeout_safe_error")
        try require(slowHandler.wasCancelled, "timeout_handler_cancelled")
    }

    @MainActor
    private static func verifyCurrentStepRollback(
        root: URL,
        now: Date,
        principal: CapabilityPrincipal
    ) async throws {
        let timerID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        let timerStore = TimerStore(
            storageDirectory: root.appendingPathComponent("current-step-timer", isDirectory: true),
            observesWake: false,
            persistenceEnabled: true
        )
        let handlers = try PocketCapabilityHandlerSet(handlers: [
            TimerCapabilityHandler(operation: .start, store: timerStore, idGenerator: { timerID }),
            BrokerMismatchedTimerReadHandler(store: timerStore),
            TimerCapabilityHandler(operation: .stop, store: timerStore)
        ])
        let brokerRoot = root.appendingPathComponent("current-step-broker", isDirectory: true)
        let broker = CapabilityBroker(
            registry: try CapabilityRegistry(handlers: handlers),
            ledger: try CapabilityBrokerLedger(rootDirectory: brokerRoot),
            auditLog: try CapabilityBrokerAuditLog(rootDirectory: brokerRoot)
        )
        let plan = CapabilityExecutionPlan(
            id: "current-step-rollback-plan",
            createdAt: now,
            origin: .text,
            principal: principal,
            appContext: nil,
            steps: [CapabilityPlanStep(
                id: "startTimer",
                capability: PocketCapabilityKeys.timerStart,
                arguments: [
                    "durationSeconds": .integer(600),
                    "sourceRef": .string("event:current-step"),
                    "title": .string("Current step")
                ],
                idempotencyKey: "current-step-timer-key-0001",
                dependencies: []
            )],
            requiredPermissions: ["timer.write"]
        )
        let permissions = CapabilityPermissionSet(principal: principal, permissions: ["timer.write"])
        let preparation = try broker.prepare(plan, permissions: permissions, now: now)
        let grant = try broker.decideApproval(
            requestID: preparation.approvalRequest!.id,
            planDigest: preparation.planDigest,
            decision: .approve,
            now: now
        )
        let receipt = try await broker.execute(plan, permissions: permissions, approvalGrant: grant, now: now)
        try require(receipt.status == .failed, "current_step_status")
        try require(receipt.steps.first?.rollbackStatus == "succeeded", "current_step_rollback")
        try require(timerStore.runningTimers.isEmpty, "current_step_timer_removed")
    }

    @MainActor
    private static func verifyCancellationAfterSuccessfulStep(
        root: URL,
        now: Date,
        principal: CapabilityPrincipal
    ) async throws {
        let timerID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        let timerStore = TimerStore(
            storageDirectory: root.appendingPathComponent("cancel-after-step-timer", isDirectory: true),
            observesWake: false,
            persistenceEnabled: true
        )
        let lease = PocketAppActivationLease()
        let sticky = BrokerCountingStickyHandler()
        let handlers = try PocketCapabilityHandlerSet(handlers: [
            TimerCapabilityHandler(operation: .start, store: timerStore, idGenerator: { timerID }),
            BrokerPostReadCancellationTimerReadHandler(store: timerStore, lease: lease),
            TimerCapabilityHandler(operation: .stop, store: timerStore),
            sticky
        ])
        let brokerRoot = root.appendingPathComponent("cancel-after-step-broker", isDirectory: true)
        let broker = CapabilityBroker(
            registry: try CapabilityRegistry(handlers: handlers),
            ledger: try CapabilityBrokerLedger(rootDirectory: brokerRoot),
            auditLog: try CapabilityBrokerAuditLog(rootDirectory: brokerRoot)
        )
        let permissions = CapabilityPermissionSet(principal: principal, permissions: ["sticky.write", "timer.write"])
        let adapter = TodayFocusTextAdapter(broker: broker)
        let draft = try adapter.prepareFocus(
            event: TodayFocusCalendarEvent(
                eventRef: "event:cancel-after-step",
                safeTitle: "Cancel after step",
                start: now,
                end: now.addingTimeInterval(600)
            ),
            durationSeconds: 600,
            purpose: "cancel-after-step",
            principal: principal,
            permissions: permissions,
            now: now
        )
        let grant = try broker.decideApproval(
            requestID: draft.preparation.approvalRequest!.id,
            planDigest: draft.preparation.planDigest,
            decision: .approve,
            now: now
        )
        let execution = Task { @MainActor in
            try await broker.execute(draft.plan, permissions: permissions, approvalGrant: grant, now: now)
        }
        let registration = lease.registerCancellation { execution.cancel() }
        defer { lease.unregisterCancellation(registration) }
        let receipt = try await execution.value
        try require(receipt.status == .failed, "cancel_after_step_status")
        try require(receipt.steps.count == 2, "cancel_after_step_receipts")
        try require(receipt.steps[0].status == .succeeded, "cancel_after_step_first_succeeded")
        try require(receipt.steps[0].rollbackStatus == "succeeded", "cancel_after_step_rollback_succeeded")
        try require(receipt.steps[1].status == .failed, "cancel_after_step_second_failed")
        try require(receipt.steps[1].safeError?.code == "CAPABILITY_CANCELLED", "cancel_after_step_safe_error")
        try require(sticky.invocationCount == 0, "cancel_after_step_no_sticky_write")
        try require(timerStore.runningTimers.isEmpty, "cancel_after_step_timer_removed")

        let replay = try await broker.execute(
            draft.plan,
            permissions: permissions,
            approvalGrant: nil,
            now: now.addingTimeInterval(1)
        )
        try require(replay.replayed && replay.status == .failed, "cancel_after_step_durable_replay")
    }

    @MainActor
    private static func makeHandlers(
        calendar: BrokerFakeCalendarDataSource,
        timerStore: TimerStore,
        stickyStore: StickyNotesStore,
        noteID: UUID
    ) throws -> PocketCapabilityHandlerSet {
        try PocketCapabilityHandlerSet(handlers: [
            CalendarListCapabilityHandler(dataSource: calendar),
            CalendarGetCapabilityHandler(dataSource: calendar),
            CalendarCreateCapabilityHandler(dataSource: calendar),
            CalculatorEvaluateCapabilityHandler(),
            TimerCapabilityHandler(operation: .start, store: timerStore),
            TimerCapabilityHandler(operation: .get, store: timerStore),
            TimerCapabilityHandler(operation: .pause, store: timerStore),
            TimerCapabilityHandler(operation: .resume, store: timerStore),
            TimerCapabilityHandler(operation: .stop, store: timerStore),
            StickyCapabilityHandler(operation: .upsert, store: stickyStore, idGenerator: { noteID }),
            StickyCapabilityHandler(operation: .get, store: stickyStore),
            StickyCapabilityHandler(operation: .status, store: stickyStore),
            StickyCapabilityHandler(operation: .archive, store: stickyStore),
            StickyCapabilityHandler(operation: .delete, store: stickyStore)
        ])
    }

    private static func replacingPurpose(
        in plan: CapabilityExecutionPlan,
        with purpose: String
    ) -> CapabilityExecutionPlan {
        let steps = plan.steps.map { step -> CapabilityPlanStep in
            guard step.capability == PocketCapabilityKeys.stickyUpsert else { return step }
            var arguments = step.arguments
            arguments["body"] = .string(purpose)
            return CapabilityPlanStep(
                id: step.id,
                capability: step.capability,
                arguments: arguments,
                idempotencyKey: step.idempotencyKey,
                dependencies: step.dependencies
            )
        }
        return CapabilityExecutionPlan(
            id: plan.id,
            createdAt: plan.createdAt,
            origin: plan.origin,
            principal: plan.principal,
            appContext: plan.appContext,
            steps: steps,
            requiredPermissions: plan.requiredPermissions
        )
    }

    private static func require(_ condition: Bool, _ label: String) throws {
        if !condition {
            throw BrokerVerificationFailure(label)
        }
    }
}

private struct BrokerVerificationFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

@MainActor
private final class BrokerFakeCalendarDataSource: CalendarCapabilityDataSource {
    private let event: CalendarCapabilityEvent

    init(now: Date) {
        self.event = CalendarCapabilityEvent(
            eventRef: "primary:sensitive-event-ref",
            eventID: "sensitive-event-id",
            safeTitle: "Sensitive Calendar Title",
            start: now.addingTimeInterval(600),
            end: now.addingTimeInterval(3_600)
        )
    }

    func listEvents(from start: Date, to end: Date) async throws -> [CalendarCapabilityEvent] {
        event.start < end && event.end > start ? [event] : []
    }

    func getEvent(eventRef: String) async throws -> CalendarCapabilityEvent? {
        eventRef == event.eventRef ? event : nil
    }

    func createEvent(
        _ request: CalendarCapabilityCreateRequest,
        idempotencyKey: String
    ) async throws -> CalendarCapabilityEvent {
        _ = request
        _ = idempotencyKey
        return event
    }
}

@MainActor
private final class BrokerFailingStickyHandler: PocketCapabilityHandler {
    let key = PocketCapabilityKeys.stickyUpsert

    func handle(arguments: CapabilityObject, context: CapabilityHandlerContext) async throws -> CapabilityObject {
        _ = arguments
        _ = try context.requiredIdempotencyKey()
        throw CapabilityHandlerError.unavailable("sticky_storage")
    }
}

@MainActor
private final class BrokerCountingStickyHandler: PocketCapabilityHandler {
    let key = PocketCapabilityKeys.stickyUpsert
    private(set) var invocationCount = 0

    func handle(arguments: CapabilityObject, context: CapabilityHandlerContext) async throws -> CapabilityObject {
        _ = arguments
        _ = try context.requiredIdempotencyKey()
        invocationCount += 1
        return [
            "noteId": .string("00000000-0000-0000-0000-000000000000"),
            "state": .string("active"),
            "updatedAt": .string(CapabilityDateCodec.string(from: context.now))
        ]
    }
}

@MainActor
private final class BrokerSlowReadHandler: PocketCapabilityHandler {
    let key: PocketCapabilityKey
    private(set) var wasCancelled = false

    init(key: PocketCapabilityKey) {
        self.key = key
    }

    func handle(arguments: CapabilityObject, context: CapabilityHandlerContext) async throws -> CapabilityObject {
        _ = arguments
        _ = context
        do {
            try await Task.sleep(for: .milliseconds(100))
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
        return ["value": .string("late")]
    }
}

@MainActor
private final class BrokerBlockingTimerStartHandler: PocketCapabilityHandler {
    let key = PocketCapabilityKeys.timerStart
    private(set) var entered = false
    private(set) var wasCancelled = false
    private(set) var didWrite = false

    func handle(arguments: CapabilityObject, context: CapabilityHandlerContext) async throws -> CapabilityObject {
        _ = arguments
        _ = try context.requiredIdempotencyKey()
        entered = true
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
        didWrite = true
        return [:]
    }
}

@MainActor
private final class BrokerMismatchedTimerReadHandler: PocketCapabilityHandler {
    let key = PocketCapabilityKeys.timerGet
    private let store: TimerStore

    init(store: TimerStore) {
        self.store = store
    }

    func handle(arguments: CapabilityObject, context: CapabilityHandlerContext) async throws -> CapabilityObject {
        guard case .string(let rawID)? = arguments["timerId"], let id = UUID(uuidString: rawID) else {
            throw CapabilityHandlerError.invalidArgument("timerId")
        }
        guard store.runningTimer(id: id) != nil else {
            return ["timerId": .string(rawID.lowercased()), "state": .string("stopped"), "endAt": .null]
        }
        return [
            "timerId": .string(rawID.lowercased()),
            "state": .string("running"),
            "endAt": .string(CapabilityDateCodec.string(from: context.now.addingTimeInterval(999)))
        ]
    }
}

@MainActor
private final class BrokerPostReadCancellationTimerReadHandler: PocketCapabilityHandler {
    let key = PocketCapabilityKeys.timerGet
    private let store: TimerStore
    private let lease: PocketAppActivationLease

    init(store: TimerStore, lease: PocketAppActivationLease) {
        self.store = store
        self.lease = lease
    }

    func handle(arguments: CapabilityObject, context: CapabilityHandlerContext) async throws -> CapabilityObject {
        guard case .string(let rawID)? = arguments["timerId"], let id = UUID(uuidString: rawID) else {
            throw CapabilityHandlerError.invalidArgument("timerId")
        }
        let timer = store.runningTimer(id: id)
        lease.invalidate()
        guard timer != nil else {
            return ["timerId": .string(rawID.lowercased()), "state": .string("stopped"), "endAt": .null]
        }
        return [
            "timerId": .string(rawID.lowercased()),
            "state": .string("running"),
            "endAt": .string(CapabilityDateCodec.string(from: context.now.addingTimeInterval(600)))
        ]
    }
}
