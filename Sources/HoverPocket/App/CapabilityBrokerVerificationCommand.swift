import Darwin
import Foundation

enum CapabilityBrokerVerificationCommand {
    private static let goldenPlanDigest = "sha256:d098ea1b5f9f70e91486fd53229e7ddb68f73a9952ab94f17eed27cdeeb6413f"

    @MainActor
    static func run() -> Never {
        Task { @MainActor in
            do {
                try await verify()
                print("broker_verify=ok")
                print("broker_registry_descriptors=11")
                print("broker_available_handlers=10")
                print("broker_today_focus=ok")
                print("broker_concurrent_duplicate=ok")
                print("broker_negative_cases=10")
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
        let timerID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
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
            timerID: timerID,
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

        try require(registry.descriptorKeys.count == 11, "registry_descriptor_count")
        try require(registry.availableHandlerKeys.count == 10, "registry_handler_count")
        try verifyGoldenDigest(now: now)
        do {
            _ = try registry.resolve(PocketCapabilityKeys.nativeAuthority)
            throw BrokerVerificationFailure("native_authority_resolved")
        } catch CapabilityBrokerError.runtimeProhibited {
        }

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

        try await verifyPartialRollback(root: root, now: now, principal: principal)
        try await verifyTimeout(root: root, now: now, principal: principal)
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
        let handlers = try PocketCapabilityHandlerSet(handlers: [BrokerSlowReadHandler(key: key)])
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
    }

    @MainActor
    private static func makeHandlers(
        calendar: BrokerFakeCalendarDataSource,
        timerStore: TimerStore,
        stickyStore: StickyNotesStore,
        timerID: UUID,
        noteID: UUID
    ) throws -> PocketCapabilityHandlerSet {
        try PocketCapabilityHandlerSet(handlers: [
            CalendarListCapabilityHandler(dataSource: calendar),
            CalendarGetCapabilityHandler(dataSource: calendar),
            CalendarCreateCapabilityHandler(dataSource: calendar),
            TimerCapabilityHandler(operation: .start, store: timerStore, idGenerator: { timerID }),
            TimerCapabilityHandler(operation: .get, store: timerStore),
            TimerCapabilityHandler(operation: .pause, store: timerStore),
            TimerCapabilityHandler(operation: .resume, store: timerStore),
            TimerCapabilityHandler(operation: .stop, store: timerStore),
            StickyCapabilityHandler(operation: .upsert, store: stickyStore, idGenerator: { noteID }),
            StickyCapabilityHandler(operation: .get, store: stickyStore)
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
private final class BrokerSlowReadHandler: PocketCapabilityHandler {
    let key: PocketCapabilityKey

    init(key: PocketCapabilityKey) {
        self.key = key
    }

    func handle(arguments: CapabilityObject, context: CapabilityHandlerContext) async throws -> CapabilityObject {
        _ = arguments
        _ = context
        try await Task.sleep(for: .milliseconds(100))
        return ["value": .string("late")]
    }
}
