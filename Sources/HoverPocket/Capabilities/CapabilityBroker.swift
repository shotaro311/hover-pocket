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
        var digest = "unavailable"
        do {
            let descriptors = try validate(plan, permissions: permissions)
            digest = try CapabilityCanonicalJSON.planDigest(plan)
            let request = try approvalStore.request(
                for: plan,
                digest: digest,
                descriptors: descriptors,
                now: now
            )
            return CapabilityBrokerPreparation(planDigest: digest, approvalRequest: request)
        } catch {
            try appendAuthorizationAudit(plan: plan, planDigest: digest, decision: "denied", error: error, now: now)
            throw error
        }
    }

    func decideApproval(
        requestID: String,
        planDigest: String,
        decision: CapabilityApprovalStore.Decision,
        now: Date = Date()
    ) throws -> CapabilityApprovalGrant {
        let request = approvalStore.pendingRequest(requestID: requestID)
        do {
            let grant = try approvalStore.decide(
                requestID: requestID,
                presentedPlanDigest: planDigest,
                decision: decision,
                now: now
            )
            try appendApprovalDecisionAudit(request: request, planDigest: planDigest, decision: "approved", error: nil, now: now)
            return grant
        } catch {
            try appendApprovalDecisionAudit(request: request, planDigest: planDigest, decision: "denied", error: error, now: now)
            throw error
        }
    }

    func execute(
        _ plan: CapabilityExecutionPlan,
        permissions: CapabilityPermissionSet,
        approvalGrant: CapabilityApprovalGrant?,
        now: Date = Date()
    ) async throws -> CapabilityWorkflowReceipt {
        await acquireExecutionSlot()
        defer { releaseExecutionSlot() }
        try Task.checkCancellation()
        var digest = "unavailable"
        let descriptors: [PocketCapabilityDescriptor]
        do {
            descriptors = try validate(plan, permissions: permissions)
            digest = try CapabilityCanonicalJSON.planDigest(plan)
        } catch {
            try appendAuthorizationAudit(plan: plan, planDigest: digest, decision: "denied", error: error, now: now)
            throw error
        }
        let durableExecution = descriptors.contains { $0.effect.isWrite }
        if durableExecution {
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
        }

        let approvalPermissions = Set(descriptors.filter(\.approvalPolicy.requiresExecutionApproval).flatMap(\.permissions))
        if !approvalPermissions.isEmpty {
            guard let approvalGrant else {
                try appendAuthorizationAudit(plan: plan, planDigest: digest, decision: "denied", error: CapabilityBrokerError.approvalRequired, now: now)
                throw CapabilityBrokerError.approvalRequired
            }
            do {
                try approvalStore.consume(
                    approvalGrant,
                    plan: plan,
                    digest: digest,
                    requiredPermissions: approvalPermissions,
                    now: now
                )
            } catch {
                try appendAuthorizationAudit(plan: plan, planDigest: digest, decision: "denied", error: error, now: now)
                throw error
            }
        }

        if durableExecution {
            try Task.checkCancellation()
            try ledger.startWorkflow(planID: plan.id, planDigest: digest)
        }
        var receipts: [CapabilityReceipt] = []
        var successfulSteps: [(step: CapabilityPlanStep, descriptor: PocketCapabilityDescriptor, receiptIndex: Int)] = []
        var workflowStatus = CapabilityReceiptStatus.succeeded

        for (index, step) in plan.steps.enumerated() {
            try Task.checkCancellation()
            let descriptor = descriptors[index]
            let receipt = try await executeStep(
                step,
                descriptor: descriptor,
                plan: plan,
                planDigest: digest,
                durableExecution: durableExecution,
                now: now
            )
            receipts.append(receipt)
            if receipt.status == .succeeded {
                successfulSteps.append((step, descriptor, receipts.count - 1))
                continue
            }

            workflowStatus = receipt.status == .unknown ? .unknown : (successfulSteps.isEmpty ? .failed : .partial)
            var rollbackCandidates = successfulSteps
            if descriptor.rollbackAvailable, receipt.output != nil {
                rollbackCandidates.append((step, descriptor, receipts.count - 1))
            }
            if !rollbackCandidates.isEmpty {
                let rollbackSucceeded = try await rollback(
                    successfulSteps: rollbackCandidates,
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
        if durableExecution {
            try ledger.completeWorkflow(workflow)
        }
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
              plan.requiredPermissions.count <= 64,
              plan.requiredPermissions.allSatisfy(Self.validPermission),
              permissions.principal == plan.principal,
              Self.validIdentifier(plan.principal.userID, maximum: 128),
              plan.principal.pocketAppID.map({ Self.matches($0, "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$") && $0.unicodeScalars.count <= 160 }) ?? true,
              plan.principal.agentSessionID.map({ Self.validIdentifier($0, maximum: 128) }) ?? true else {
            throw CapabilityBrokerError.invalidPlan("identity")
        }
        if let app = plan.appContext {
            guard Self.matches(app.id, "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$"),
                  app.version.unicodeScalars.count <= 64,
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
                  Self.matches(step.capability.id, "^[a-z][a-z0-9]*(?:\\.[a-z][a-z0-9_]*){2,}$"),
                  step.capability.id.unicodeScalars.count <= 128,
                  step.capability.version >= 1,
                  CapabilityHandlerContext(idempotencyKey: step.idempotencyKey).requiredIdempotencyKeyIfValid,
                  seenIdempotencyKeys.insert(step.idempotencyKey).inserted,
                  step.dependencies.count <= 32,
                  Set(step.dependencies).count == step.dependencies.count,
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
        if descriptors.contains(where: { $0.approvalPolicy == .strongPerCall }),
           descriptors.count != 1 {
            throw CapabilityBrokerError.invalidPlan("strong_per_call")
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
        durableExecution: Bool,
        now: Date
    ) async throws -> CapabilityReceipt {
        let argumentDigest = try CapabilityCanonicalJSON.digest(step.arguments)
        if durableExecution {
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
        var possibleOutput: CapabilityObject?
        do {
            let output = try await invokeWithTimeout(
                descriptor.key,
                arguments: step.arguments,
                context: CapabilityHandlerContext(idempotencyKey: step.idempotencyKey, now: now),
                timeoutMilliseconds: descriptor.limits.timeoutMilliseconds
            )
            possibleOutput = output
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
                possibleOutput: possibleOutput,
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
        if durableExecution {
            try ledger.completeInvocation(idempotencyKey: step.idempotencyKey, receipt: receipt)
        }
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
        case PocketCapabilityKeys.stickyGet, PocketCapabilityKeys.stickyStatus:
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
                durableExecution: true,
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
        let cancellation = CapabilityInvocationCancellationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = CapabilityInvocationContinuationGate(continuation, expectedTaskCount: 2)
                cancellation.install(gate)
                let operation = Task { @MainActor [registry] in
                    do {
                        try Task.checkCancellation()
                        gate.resolve(.success(try await registry.invoke(key, arguments: arguments, context: context)))
                    } catch {
                        gate.resolve(.failure(error))
                    }
                }
                let timeout = Task { @MainActor in
                    do {
                        try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                        gate.resolve(.failure(CapabilityBrokerError.timedOut(key)))
                    } catch {
                        gate.resolve(.failure(error))
                    }
                }
                gate.install(tasks: [operation, timeout])
            }
        } onCancel: {
            Task { @MainActor in cancellation.cancel() }
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
        possibleOutput: CapabilityObject?,
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
            output: possibleOutput,
            readback: CapabilityReadbackReceipt(status: .unavailable, strategy: descriptor.readback.strategy, observedAt: nil, observed: nil, evidenceDigest: nil),
            rollbackAvailable: descriptor.rollbackAvailable,
            rollbackStatus: descriptor.rollbackAvailable ? "not_requested" : nil,
            auditEntryID: auditEntryID,
            safeError: safe,
            completedAt: now,
            replayed: false
        )
    }

    private func appendApprovalDecisionAudit(
        request: CapabilityApprovalRequest?,
        planDigest: String,
        decision: String,
        error: Error?,
        now: Date
    ) throws {
        try auditLog.appendAuthorization(CapabilityAuthorizationAuditEntry(
            decision: decision,
            origin: "approval",
            planDigest: planDigest,
            planID: request?.planID ?? "unknown",
            pocketApp: request?.appContext.map { .init(id: $0.id, version: $0.version, manifestDigest: $0.manifestDigest) },
            principalPseudonym: request.map { CapabilityBrokerAuditLog.principalPseudonym($0.principal) } ?? "principal:unknown",
            safeErrorCode: error.map(Self.authorizationErrorCode),
            timestamp: now
        ))
    }

    private func appendAuthorizationAudit(
        plan: CapabilityExecutionPlan,
        planDigest: String,
        decision: String,
        error: Error?,
        now: Date
    ) throws {
        try auditLog.appendAuthorization(CapabilityAuthorizationAuditEntry(
            decision: decision,
            origin: String(plan.origin.rawValue.prefix(32)),
            planDigest: Self.safeAuditDigest(planDigest),
            planID: Self.safeAuditPlanID(plan.id),
            pocketApp: Self.safeAuditPocketApp(plan.appContext),
            principalPseudonym: CapabilityBrokerAuditLog.principalPseudonym(Self.safeAuditPrincipal(plan.principal)),
            safeErrorCode: error.map(Self.authorizationErrorCode),
            timestamp: now
        ))
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

    private static func authorizationErrorCode(_ error: Error) -> String {
        guard let broker = error as? CapabilityBrokerError else {
            return safeError(error).code
        }
        return switch broker {
        case .invalidPlan: "CAPABILITY_PLAN_INVALID"
        case .unknownCapability: "CAPABILITY_UNKNOWN"
        case .unavailable: "CAPABILITY_UNAVAILABLE"
        case .runtimeProhibited: "CAPABILITY_RUNTIME_PROHIBITED"
        case .invalidArguments: "CAPABILITY_ARGUMENT_INVALID"
        case .permissionDenied: "CAPABILITY_PERMISSION_DENIED"
        case .approvalRequired: "CAPABILITY_APPROVAL_REQUIRED"
        case .approvalRejected: "CAPABILITY_APPROVAL_REJECTED"
        case .approvalExpired: "CAPABILITY_APPROVAL_EXPIRED"
        case .approvalInvalid: "CAPABILITY_APPROVAL_INVALID"
        case .approvalReplayed: "CAPABILITY_APPROVAL_REPLAYED"
        case .idempotencyConflict: "CAPABILITY_IDEMPOTENCY_CONFLICT"
        case .executionUnknown: "CAPABILITY_EXECUTION_UNKNOWN"
        case .rateLimited: "CAPABILITY_RATE_LIMITED"
        case .timedOut: "CAPABILITY_TIMEOUT"
        case .ledgerUnavailable: "CAPABILITY_LEDGER_UNAVAILABLE"
        }
    }

    private static func invocationID(planDigest: String, stepID: String) -> String {
        "invocation:\(planDigest.dropFirst("sha256:".count).prefix(32)):\(stepID)"
    }

    private static func validIdentifier(_ value: String, maximum: Int) -> Bool {
        value.unicodeScalars.count <= maximum && matches(value, "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
    }

    private static func validPermission(_ value: String) -> Bool {
        value.unicodeScalars.count <= 128
            && matches(value, "^[a-z][a-z0-9]*(?:\\.[a-z][a-z0-9_]*)+$")
    }

    private static func safeAuditDigest(_ value: String) -> String {
        matches(value, "^sha256:[a-f0-9]{64}$") ? value : "unavailable"
    }

    private static func safeAuditPlanID(_ value: String) -> String {
        matches(value, "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$") ? value : "invalid"
    }

    private static func safeAuditPrincipal(_ principal: CapabilityPrincipal) -> CapabilityPrincipal {
        CapabilityPrincipal(
            userID: String(principal.userID.prefix(128)),
            pocketAppID: principal.pocketAppID.map { String($0.prefix(160)) },
            agentSessionID: principal.agentSessionID.map { String($0.prefix(128)) }
        )
    }

    private static func safeAuditPocketApp(_ app: CapabilityAppContext?) -> CapabilityAuditEntry.PocketAppSummary? {
        guard let app,
              app.id.unicodeScalars.count <= 160,
              app.version.unicodeScalars.count <= 64,
              matches(app.id, "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$"),
              matches(app.version, "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$"),
              matches(app.manifestDigest, "^sha256:[a-f0-9]{64}$") else {
            return nil
        }
        return .init(id: app.id, version: app.version, manifestDigest: app.manifestDigest)
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
    private var tasks: [Task<Void, Never>] = []
    private var winningResult: Result<CapabilityObject, Error>?
    private var remainingTaskCount: Int
    private var installed = false

    init(
        _ continuation: CheckedContinuation<CapabilityObject, Error>,
        expectedTaskCount: Int
    ) {
        self.continuation = continuation
        remainingTaskCount = expectedTaskCount
    }

    func install(tasks: [Task<Void, Never>]) {
        self.tasks = tasks
        installed = true
        if winningResult != nil {
            tasks.forEach { $0.cancel() }
        }
        finishIfReady()
    }

    func resolve(_ result: Result<CapabilityObject, Error>) {
        guard remainingTaskCount > 0 else { return }
        remainingTaskCount -= 1
        if winningResult == nil {
            winningResult = result
            if installed {
                tasks.forEach { $0.cancel() }
            }
        }
        finishIfReady()
    }

    func cancel() {
        guard winningResult == nil else { return }
        winningResult = .failure(CancellationError())
        if installed {
            tasks.forEach { $0.cancel() }
        }
        finishIfReady()
    }

    private func finishIfReady() {
        guard installed,
              remainingTaskCount == 0,
              let continuation,
              let winningResult else { return }
        self.continuation = nil
        tasks.removeAll(keepingCapacity: false)
        continuation.resume(with: winningResult)
    }
}

@MainActor
private final class CapabilityInvocationCancellationBox {
    private var gate: CapabilityInvocationContinuationGate?
    private var isCancelled = false

    func install(_ gate: CapabilityInvocationContinuationGate) {
        self.gate = gate
        if isCancelled {
            gate.cancel()
        }
    }

    func cancel() {
        isCancelled = true
        gate?.cancel()
    }
}
