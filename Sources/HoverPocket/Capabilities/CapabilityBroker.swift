import Foundation

@MainActor
final class CapabilityBroker {
    private let registry: CapabilityRegistry
    private let ledger: CapabilityBrokerLedger
    private let approvalStore: CapabilityApprovalStore
    private let auditLog: CapabilityBrokerAuditLog
    private var callHistory: [String: [Date]] = [:]
    private var executionActive = false
    private var executionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        registry: CapabilityRegistry,
        ledger: CapabilityBrokerLedger,
        approvalStore: CapabilityApprovalStore = CapabilityApprovalStore(),
        auditLog: CapabilityBrokerAuditLog
    ) {
        self.registry = registry
        self.ledger = ledger
        self.approvalStore = approvalStore
        self.auditLog = auditLog
    }

    func prepare(
        _ plan: CapabilityExecutionPlan,
        permissions: CapabilityPermissionSet,
        now: Date = Date()
    ) throws -> CapabilityBrokerPreparation {
        let descriptors = try validate(plan, permissions: permissions)
        let digest = try CapabilityCanonicalJSON.planDigest(plan)
        let request = try approvalStore.request(
            for: plan,
            digest: digest,
            descriptors: descriptors,
            now: now
        )
        return CapabilityBrokerPreparation(planDigest: digest, approvalRequest: request)
    }

    func decideApproval(
        requestID: String,
        planDigest: String,
        decision: CapabilityApprovalStore.Decision,
        now: Date = Date()
    ) throws -> CapabilityApprovalGrant {
        try approvalStore.decide(
            requestID: requestID,
            presentedPlanDigest: planDigest,
            decision: decision,
            now: now
        )
    }

    func execute(
        _ plan: CapabilityExecutionPlan,
        permissions: CapabilityPermissionSet,
        approvalGrant: CapabilityApprovalGrant?,
        now: Date = Date()
    ) async throws -> CapabilityWorkflowReceipt {
        await acquireExecutionSlot()
        defer { releaseExecutionSlot() }
        let descriptors = try validate(plan, permissions: permissions)
        let digest = try CapabilityCanonicalJSON.planDigest(plan)
        switch try ledger.lookupWorkflow(planID: plan.id, planDigest: digest) {
        case .replay(let receipt):
            for ((step, descriptor), stepReceipt) in zip(zip(plan.steps, descriptors), receipt.steps) {
                try appendAudit(
                    receipt: stepReceipt,
                    descriptor: descriptor,
                    plan: plan,
                    argumentDigest: try CapabilityCanonicalJSON.digest(step.arguments),
                    durationMilliseconds: 0,
                    replayed: true,
                    now: now
                )
            }
            return receipt
        case .unknown:
            throw CapabilityBrokerError.executionUnknown(plan.id)
        case .execute:
            break
        }

        let approvalPermissions = Set(descriptors.filter(\.approvalPolicy.requiresExecutionApproval).flatMap(\.permissions))
        if !approvalPermissions.isEmpty {
            guard let approvalGrant else {
                throw CapabilityBrokerError.approvalRequired
            }
            try approvalStore.consume(
                approvalGrant,
                plan: plan,
                digest: digest,
                requiredPermissions: approvalPermissions,
                now: now
            )
        }

        try ledger.startWorkflow(planID: plan.id, planDigest: digest)
        var receipts: [CapabilityReceipt] = []
        var successfulSteps: [(step: CapabilityPlanStep, descriptor: PocketCapabilityDescriptor, receiptIndex: Int)] = []
        var workflowStatus = CapabilityReceiptStatus.succeeded

        for (index, step) in plan.steps.enumerated() {
            let descriptor = descriptors[index]
            let receipt = try await executeStep(
                step,
                descriptor: descriptor,
                plan: plan,
                planDigest: digest,
                now: now
            )
            receipts.append(receipt)
            if receipt.status == .succeeded {
                successfulSteps.append((step, descriptor, receipts.count - 1))
                continue
            }

            workflowStatus = receipt.status == .unknown ? .unknown : (successfulSteps.isEmpty ? .failed : .partial)
            if !successfulSteps.isEmpty {
                let rollbackSucceeded = try await rollback(
                    successfulSteps: successfulSteps,
                    receipts: &receipts,
                    plan: plan,
                    planDigest: digest,
                    now: now
                )
                if rollbackSucceeded && receipt.status != .unknown {
                    workflowStatus = .failed
                }
            }
            break
        }

        let workflow = CapabilityWorkflowReceipt(
            planID: plan.id,
            planDigest: digest,
            status: workflowStatus,
            steps: receipts,
            completedAt: now,
            replayed: false
        )
        try ledger.completeWorkflow(workflow)
        return workflow
    }

    private func acquireExecutionSlot() async {
        if !executionActive {
            executionActive = true
            return
        }
        await withCheckedContinuation { continuation in
            executionWaiters.append(continuation)
        }
    }

    private func releaseExecutionSlot() {
        guard !executionWaiters.isEmpty else {
            executionActive = false
            return
        }
        executionWaiters.removeFirst().resume()
    }

    private func validate(
        _ plan: CapabilityExecutionPlan,
        permissions: CapabilityPermissionSet
    ) throws -> [PocketCapabilityDescriptor] {
        guard Self.matches(plan.id, "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"),
              (1...32).contains(plan.steps.count),
              permissions.principal == plan.principal,
              Self.validIdentifier(plan.principal.userID, maximum: 128),
              plan.principal.pocketAppID.map({ Self.matches($0, "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$") && $0.unicodeScalars.count <= 160 }) ?? true,
              plan.principal.agentSessionID.map({ Self.validIdentifier($0, maximum: 128) }) ?? true else {
            throw CapabilityBrokerError.invalidPlan("identity")
        }
        if let app = plan.appContext {
            guard Self.matches(app.id, "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$"),
                  Self.matches(app.version, "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$"),
                  Self.matches(app.manifestDigest, "^sha256:[a-f0-9]{64}$"),
                  app.id == plan.principal.pocketAppID else {
                throw CapabilityBrokerError.invalidPlan("app_context")
            }
        } else if plan.principal.pocketAppID != nil {
            throw CapabilityBrokerError.invalidPlan("app_context")
        }

        var seenStepIDs: Set<String> = []
        var seenIdempotencyKeys: Set<String> = []
        var descriptors: [PocketCapabilityDescriptor] = []
        var requiredPermissions: Set<String> = []
        for step in plan.steps {
            guard Self.matches(step.id, "^[A-Za-z][A-Za-z0-9_-]{0,63}$"),
                  seenStepIDs.insert(step.id).inserted,
                  CapabilityHandlerContext(idempotencyKey: step.idempotencyKey).requiredIdempotencyKeyIfValid,
                  seenIdempotencyKeys.insert(step.idempotencyKey).inserted,
                  step.dependencies.allSatisfy(seenStepIDs.contains),
                  !step.dependencies.contains(step.id) else {
                throw CapabilityBrokerError.invalidPlan("steps")
            }
            let descriptor = try registry.resolve(step.capability)
            try descriptor.validateInput(step.arguments)
            descriptors.append(descriptor)
            requiredPermissions.formUnion(descriptor.permissions)
        }
        guard requiredPermissions == plan.requiredPermissions else {
            throw CapabilityBrokerError.invalidPlan("permissions")
        }
        guard permissions.contains(requiredPermissions) else {
            let missing = requiredPermissions.subtracting(permissions.permissions).sorted().first ?? "unknown"
            throw CapabilityBrokerError.permissionDenied(missing)
        }
        return descriptors
    }

    private func executeStep(
        _ step: CapabilityPlanStep,
        descriptor: PocketCapabilityDescriptor,
        plan: CapabilityExecutionPlan,
        planDigest: String,
        now: Date
    ) async throws -> CapabilityReceipt {
        let argumentDigest = try CapabilityCanonicalJSON.digest(step.arguments)
        switch try ledger.beginInvocation(
            idempotencyKey: step.idempotencyKey,
            planDigest: planDigest,
            argumentDigest: argumentDigest,
            capability: step.capability
        ) {
        case .replay(let receipt):
            try appendAudit(
                receipt: receipt,
                descriptor: descriptor,
                plan: plan,
                argumentDigest: argumentDigest,
                durationMilliseconds: 0,
                replayed: true,
                now: now
            )
            return receipt
        case .unknown:
            throw CapabilityBrokerError.executionUnknown(step.idempotencyKey)
        case .execute:
            break
        }

        try enforceRateLimit(descriptor, principal: plan.principal, now: now)
        let invocationID = Self.invocationID(planDigest: planDigest, stepID: step.id)
        let auditEntryID = "audit:\(UUID().uuidString.lowercased())"
        let traceID = "trace:\(planDigest.dropFirst("sha256:".count).prefix(32))"
        let start = ContinuousClock.now

        let started = CapabilityAuditEntry(
            approvalDecision: descriptor.approvalPolicy.requiresExecutionApproval ? "approved" : "not_required",
            approvalPolicy: descriptor.approvalPolicy.rawValue,
            auditEntryID: auditEntryID,
            capability: .init(id: descriptor.key.id, version: descriptor.key.version, effect: descriptor.effect.rawValue),
            durationMilliseconds: 0,
            idempotencyReplay: false,
            inputDigest: argumentDigest,
            invocationID: invocationID,
            origin: plan.origin.rawValue,
            permissionDecision: "granted",
            pocketApp: plan.appContext.map { .init(id: $0.id, version: $0.version, manifestDigest: $0.manifestDigest) },
            principalPseudonym: CapabilityBrokerAuditLog.principalPseudonym(plan.principal),
            readback: .init(status: CapabilityReadbackStatus.unavailable.rawValue, evidenceDigest: nil),
            retryCount: 0,
            safeErrorCode: nil,
            status: CapabilityReceiptStatus.unknown.rawValue,
            timestamp: now,
            traceID: traceID
        )
        try auditLog.append(started)

        let receipt: CapabilityReceipt
        do {
            let output = try await invokeWithTimeout(
                descriptor.key,
                arguments: step.arguments,
                context: CapabilityHandlerContext(idempotencyKey: step.idempotencyKey, now: now),
                timeoutMilliseconds: descriptor.limits.timeoutMilliseconds
            )
            try descriptor.validateOutput(output)
            let readback = try await readback(
                descriptor: descriptor,
                output: output,
                now: now
            )
            let status: CapabilityReceiptStatus = readback.status == .verified
                ? .succeeded
                : (descriptor.effect.isWrite ? .partial : .failed)
            receipt = CapabilityReceipt(
                invocationID: invocationID,
                planID: plan.id,
                planDigest: planDigest,
                capability: descriptor.key,
                status: status,
                output: output,
                readback: readback,
                rollbackAvailable: descriptor.rollbackAvailable,
                rollbackStatus: descriptor.rollbackAvailable ? "not_requested" : nil,
                auditEntryID: auditEntryID,
                safeError: status == .succeeded ? nil : .init(code: "CAPABILITY_READBACK_MISMATCH", retryable: false, messageKey: "error.capability.readback_mismatch"),
                completedAt: now,
                replayed: false
            )
        } catch {
            receipt = failureReceipt(
                error,
                invocationID: invocationID,
                auditEntryID: auditEntryID,
                descriptor: descriptor,
                plan: plan,
                planDigest: planDigest,
                now: now
            )
        }

        let elapsed = ContinuousClock.now - start
        let duration = Int(elapsed.components.seconds * 1_000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        try appendAudit(
            receipt: receipt,
            descriptor: descriptor,
            plan: plan,
            argumentDigest: argumentDigest,
            durationMilliseconds: max(0, duration),
            replayed: false,
            now: now
        )
        try ledger.completeInvocation(idempotencyKey: step.idempotencyKey, receipt: receipt)
        return receipt
    }

    private func readback(
        descriptor: PocketCapabilityDescriptor,
        output: CapabilityObject,
        now: Date
    ) async throws -> CapabilityReadbackReceipt {
        let observed: CapabilityObject
        switch descriptor.readback.strategy {
        case .sameStoreSnapshot, .osState, .contentDigest:
            observed = output
        case .capabilityQuery, .entityGetByID:
            guard let queryKey = descriptor.readback.query else {
                throw CapabilityBrokerError.invalidPlan("readback_query")
            }
            let arguments = try readbackArguments(queryKey, output: output)
            let queryDescriptor = try registry.resolve(queryKey)
            try queryDescriptor.validateInput(arguments)
            observed = try await invokeWithTimeout(
                queryKey,
                arguments: arguments,
                context: CapabilityHandlerContext(now: now),
                timeoutMilliseconds: queryDescriptor.limits.timeoutMilliseconds
            )
            try queryDescriptor.validateOutput(observed)
        case .none:
            guard !descriptor.effect.isWrite else {
                throw CapabilityBrokerError.invalidPlan("write_without_readback")
            }
            observed = output
        }

        let matched = descriptor.readback.matchFields.allSatisfy { field in
            output[field] == observed[field] && output[field] != nil
        }
        return CapabilityReadbackReceipt(
            status: matched ? .verified : .mismatch,
            strategy: descriptor.readback.strategy,
            observedAt: now,
            observed: observed,
            evidenceDigest: try CapabilityCanonicalJSON.digest(observed)
        )
    }

    private func readbackArguments(
        _ query: PocketCapabilityKey,
        output: CapabilityObject
    ) throws -> CapabilityObject {
        let sourceField: String
        let targetField: String
        switch query {
        case PocketCapabilityKeys.calendarGet:
            sourceField = "eventRef"
            targetField = "eventRef"
        case PocketCapabilityKeys.timerGet:
            sourceField = "timerId"
            targetField = "timerId"
        case PocketCapabilityKeys.stickyGet:
            sourceField = "noteId"
            targetField = "noteId"
        default:
            throw CapabilityBrokerError.invalidPlan("readback_query")
        }
        guard let value = output[sourceField] else {
            throw CapabilityBrokerError.invalidPlan("readback_identifier")
        }
        return [targetField: value]
    }

    private func rollback(
        successfulSteps: [(step: CapabilityPlanStep, descriptor: PocketCapabilityDescriptor, receiptIndex: Int)],
        receipts: inout [CapabilityReceipt],
        plan: CapabilityExecutionPlan,
        planDigest: String,
        now: Date
    ) async throws -> Bool {
        var allSucceeded = true
        for item in successfulSteps.reversed() {
            guard item.descriptor.rollbackAvailable else {
                allSucceeded = false
                continue
            }
            guard item.step.capability == PocketCapabilityKeys.timerStart,
                  let output = receipts[item.receiptIndex].output,
                  let timerID = output["timerId"] else {
                allSucceeded = false
                continue
            }
            let rollbackStep = CapabilityPlanStep(
                id: "rollback_\(item.step.id)",
                capability: PocketCapabilityKeys.timerStop,
                arguments: ["timerId": timerID],
                idempotencyKey: "rollback.\(planDigest.dropFirst("sha256:".count).prefix(24)).\(item.step.id)",
                dependencies: []
            )
            let rollbackDescriptor = try registry.resolve(rollbackStep.capability)
            let rollbackReceipt = try await executeStep(
                rollbackStep,
                descriptor: rollbackDescriptor,
                plan: plan,
                planDigest: planDigest,
                now: now
            )
            let succeeded = rollbackReceipt.status == .succeeded
            receipts[item.receiptIndex] = receipts[item.receiptIndex].withRollbackStatus(succeeded ? "succeeded" : "failed")
            allSucceeded = allSucceeded && succeeded
        }
        return allSucceeded
    }

    private func invokeWithTimeout(
        _ key: PocketCapabilityKey,
        arguments: CapabilityObject,
        context: CapabilityHandlerContext,
        timeoutMilliseconds: Int
    ) async throws -> CapabilityObject {
        try await withCheckedThrowingContinuation { continuation in
            let gate = CapabilityInvocationContinuationGate(continuation)
            Task { @MainActor [registry] in
                do {
                    gate.resolve(.success(try await registry.invoke(key, arguments: arguments, context: context)))
                } catch {
                    gate.resolve(.failure(error))
                }
            }
            Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                    gate.resolve(.failure(CapabilityBrokerError.timedOut(key)))
                } catch {
                    gate.resolve(.failure(error))
                }
            }
        }
    }

    private func enforceRateLimit(
        _ descriptor: PocketCapabilityDescriptor,
        principal: CapabilityPrincipal,
        now: Date
    ) throws {
        let key = CapabilityBrokerAuditLog.principalPseudonym(principal) + ":" + descriptor.key.id
        let cutoff = now.addingTimeInterval(-60)
        var history = callHistory[key, default: []].filter { $0 >= cutoff }
        guard history.count < descriptor.limits.maximumCallsPerMinute else {
            throw CapabilityBrokerError.rateLimited(descriptor.key)
        }
        history.append(now)
        callHistory[key] = history
    }

    private func failureReceipt(
        _ error: Error,
        invocationID: String,
        auditEntryID: String,
        descriptor: PocketCapabilityDescriptor,
        plan: CapabilityExecutionPlan,
        planDigest: String,
        now: Date
    ) -> CapabilityReceipt {
        let safe = Self.safeError(error)
        let status: CapabilityReceiptStatus = error is CancellationError
            || (error as? CapabilityBrokerError).map { if case .timedOut = $0 { true } else { false } } == true
            ? .unknown
            : (descriptor.effect.isWrite ? .partial : .failed)
        return CapabilityReceipt(
            invocationID: invocationID,
            planID: plan.id,
            planDigest: planDigest,
            capability: descriptor.key,
            status: status,
            output: nil,
            readback: CapabilityReadbackReceipt(status: .unavailable, strategy: descriptor.readback.strategy, observedAt: nil, observed: nil, evidenceDigest: nil),
            rollbackAvailable: descriptor.rollbackAvailable,
            rollbackStatus: descriptor.rollbackAvailable ? "not_requested" : nil,
            auditEntryID: auditEntryID,
            safeError: safe,
            completedAt: now,
            replayed: false
        )
    }

    private func appendAudit(
        receipt: CapabilityReceipt,
        descriptor: PocketCapabilityDescriptor,
        plan: CapabilityExecutionPlan,
        argumentDigest: String,
        durationMilliseconds: Int,
        replayed: Bool,
        now: Date
    ) throws {
        try auditLog.append(CapabilityAuditEntry(
            approvalDecision: descriptor.approvalPolicy.requiresExecutionApproval ? "approved" : "not_required",
            approvalPolicy: descriptor.approvalPolicy.rawValue,
            auditEntryID: receipt.auditEntryID,
            capability: .init(id: descriptor.key.id, version: descriptor.key.version, effect: descriptor.effect.rawValue),
            durationMilliseconds: durationMilliseconds,
            idempotencyReplay: replayed,
            inputDigest: argumentDigest,
            invocationID: receipt.invocationID,
            origin: plan.origin.rawValue,
            permissionDecision: "granted",
            pocketApp: plan.appContext.map { .init(id: $0.id, version: $0.version, manifestDigest: $0.manifestDigest) },
            principalPseudonym: CapabilityBrokerAuditLog.principalPseudonym(plan.principal),
            readback: .init(status: receipt.readback.status.rawValue, evidenceDigest: receipt.readback.evidenceDigest),
            retryCount: 0,
            safeErrorCode: receipt.safeError?.code,
            status: receipt.status.rawValue,
            timestamp: now,
            traceID: "trace:\(receipt.planDigest.dropFirst("sha256:".count).prefix(32))"
        ))
    }

    private static func safeError(_ error: Error) -> CapabilitySafeError {
        if let handler = error as? CapabilityHandlerError {
            return CapabilitySafeError(code: handler.code, retryable: false, messageKey: "error.capability.handler")
        }
        if let broker = error as? CapabilityBrokerError {
            switch broker {
            case .timedOut:
                return CapabilitySafeError(code: "CAPABILITY_TIMEOUT", retryable: false, messageKey: "error.capability.timeout")
            case .rateLimited:
                return CapabilitySafeError(code: "CAPABILITY_RATE_LIMITED", retryable: true, messageKey: "error.capability.rate_limited")
            default:
                return CapabilitySafeError(code: "CAPABILITY_EXECUTION_FAILED", retryable: false, messageKey: "error.capability.execution_failed")
            }
        }
        if error is CancellationError {
            return CapabilitySafeError(code: "CAPABILITY_CANCELLED", retryable: false, messageKey: "error.capability.cancelled")
        }
        return CapabilitySafeError(code: "CAPABILITY_EXECUTION_FAILED", retryable: false, messageKey: "error.capability.execution_failed")
    }

    private static func invocationID(planDigest: String, stepID: String) -> String {
        "invocation:\(planDigest.dropFirst("sha256:".count).prefix(32)):\(stepID)"
    }

    private static func validIdentifier(_ value: String, maximum: Int) -> Bool {
        value.unicodeScalars.count <= maximum && matches(value, "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

private extension CapabilityHandlerContext {
    var requiredIdempotencyKeyIfValid: Bool {
        (try? requiredIdempotencyKey()) != nil
    }
}

@MainActor
private final class CapabilityInvocationContinuationGate {
    private var continuation: CheckedContinuation<CapabilityObject, Error>?

    init(_ continuation: CheckedContinuation<CapabilityObject, Error>) {
        self.continuation = continuation
    }

    func resolve(_ result: Result<CapabilityObject, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
