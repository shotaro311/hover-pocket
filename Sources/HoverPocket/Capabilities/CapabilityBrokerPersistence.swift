import Foundation

enum CapabilityLedgerStart<Result> {
    case execute
    case replay(Result)
    case unknown
}

final class CapabilityBrokerLedger {
    private enum RecordState: String, Codable {
        case pending
        case completed
    }

    private struct InvocationRecord: Codable {
        let planDigest: String
        let argumentDigest: String
        let capability: PocketCapabilityKey
        var state: RecordState
        var receipt: CapabilityReceipt?
    }

    private struct WorkflowRecord: Codable {
        let planDigest: String
        var state: RecordState
        var receipt: CapabilityWorkflowReceipt?
    }

    private struct State: Codable {
        var version = 1
        var invocations: [String: InvocationRecord] = [:]
        var workflows: [String: WorkflowRecord] = [:]
    }

    private let fileURL: URL
    private var state: State
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootDirectory: URL) throws {
        self.fileURL = rootDirectory.appendingPathComponent("capability-broker-ledger.json", isDirectory: false)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder.dateDecodingStrategy = .iso8601

        do {
            try FileManager.default.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                state = try decoder.decode(State.self, from: data)
                guard state.version == 1 else {
                    throw CapabilityBrokerError.ledgerUnavailable
                }
            } else {
                state = State()
            }
        } catch let error as CapabilityBrokerError {
            throw error
        } catch {
            throw CapabilityBrokerError.ledgerUnavailable
        }
    }

    func beginInvocation(
        idempotencyKey: String,
        planDigest: String,
        argumentDigest: String,
        capability: PocketCapabilityKey
    ) throws -> CapabilityLedgerStart<CapabilityReceipt> {
        if let existing = state.invocations[idempotencyKey] {
            guard existing.planDigest == planDigest,
                  existing.argumentDigest == argumentDigest,
                  existing.capability == capability else {
                throw CapabilityBrokerError.idempotencyConflict(idempotencyKey)
            }
            if existing.state == .completed, let receipt = existing.receipt {
                return .replay(receipt.replayCopy())
            }
            return .unknown
        }

        state.invocations[idempotencyKey] = InvocationRecord(
            planDigest: planDigest,
            argumentDigest: argumentDigest,
            capability: capability,
            state: .pending,
            receipt: nil
        )
        try persist()
        return .execute
    }

    func completeInvocation(idempotencyKey: String, receipt: CapabilityReceipt) throws {
        guard var record = state.invocations[idempotencyKey],
              record.planDigest == receipt.planDigest,
              record.capability == receipt.capability else {
            throw CapabilityBrokerError.ledgerUnavailable
        }
        record.state = .completed
        record.receipt = receipt
        state.invocations[idempotencyKey] = record
        try persist()
    }

    func lookupWorkflow(planID: String, planDigest: String) throws -> CapabilityLedgerStart<CapabilityWorkflowReceipt> {
        if let existing = state.workflows[planID] {
            guard existing.planDigest == planDigest else {
                throw CapabilityBrokerError.idempotencyConflict(planID)
            }
            if existing.state == .completed, let receipt = existing.receipt {
                return .replay(receipt.replayCopy())
            }
            return .unknown
        }

        return .execute
    }

    func startWorkflow(planID: String, planDigest: String) throws {
        guard state.workflows[planID] == nil else {
            throw CapabilityBrokerError.idempotencyConflict(planID)
        }
        state.workflows[planID] = WorkflowRecord(planDigest: planDigest, state: .pending, receipt: nil)
        try persist()
    }

    func completeWorkflow(_ receipt: CapabilityWorkflowReceipt) throws {
        guard var record = state.workflows[receipt.planID],
              record.planDigest == receipt.planDigest else {
            throw CapabilityBrokerError.ledgerUnavailable
        }
        record.state = .completed
        record.receipt = receipt
        state.workflows[receipt.planID] = record
        try persist()
    }

    private func persist() throws {
        do {
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw CapabilityBrokerError.ledgerUnavailable
        }
    }
}

final class CapabilityApprovalStore {
    enum Decision {
        case approve
        case reject
    }

    private struct PendingApproval {
        let request: CapabilityApprovalRequest
    }

    private struct IssuedGrant {
        let requestID: String
        let planID: String
        let planDigest: String
        let principal: CapabilityPrincipal
        let appContext: CapabilityAppContext?
        let permissions: Set<String>
        let expiresAt: Date
    }

    private var pending: [String: PendingApproval] = [:]
    private var grants: [String: IssuedGrant] = [:]
    private var consumedTokens: Set<String> = []
    private let timeToLive: TimeInterval

    init(timeToLive: TimeInterval = 300) {
        self.timeToLive = timeToLive
    }

    func request(
        for plan: CapabilityExecutionPlan,
        digest: String,
        descriptors: [PocketCapabilityDescriptor],
        now: Date
    ) throws -> CapabilityApprovalRequest? {
        let effects = try zip(plan.steps, descriptors).compactMap { step, descriptor -> CapabilityApprovalEffect? in
            guard descriptor.approvalPolicy.requiresExecutionApproval else { return nil }
            return CapabilityApprovalEffect(
                stepID: step.id,
                capability: step.capability,
                effect: descriptor.effect,
                argumentDigest: try CapabilityCanonicalJSON.digest(step.arguments),
                summaryKey: "approval.\(step.capability.id)",
                rollbackAvailable: descriptor.rollbackAvailable
            )
        }
        guard !effects.isEmpty else { return nil }

        let request = CapabilityApprovalRequest(
            id: "approval:\(UUID().uuidString.lowercased())",
            planID: plan.id,
            planDigest: digest,
            principal: plan.principal,
            appContext: plan.appContext,
            createdAt: now,
            expiresAt: now.addingTimeInterval(timeToLive),
            nonce: "nonce:\(UUID().uuidString.lowercased())",
            effects: effects,
            requiredPermissions: Set(zip(descriptors, plan.steps).flatMap { descriptor, _ in
                descriptor.approvalPolicy.requiresExecutionApproval ? descriptor.permissions : []
            })
        )
        pending[request.id] = PendingApproval(request: request)
        return request
    }

    func decide(
        requestID: String,
        presentedPlanDigest: String,
        decision: Decision,
        now: Date
    ) throws -> CapabilityApprovalGrant {
        guard let pendingApproval = pending.removeValue(forKey: requestID) else {
            throw CapabilityBrokerError.approvalInvalid
        }
        let request = pendingApproval.request
        guard request.planDigest == presentedPlanDigest else {
            throw CapabilityBrokerError.approvalInvalid
        }
        guard now <= request.expiresAt else {
            throw CapabilityBrokerError.approvalExpired
        }
        guard decision == .approve else {
            throw CapabilityBrokerError.approvalRejected
        }

        let token = "grant:\(UUID().uuidString.lowercased())"
        grants[token] = IssuedGrant(
            requestID: request.id,
            planID: request.planID,
            planDigest: request.planDigest,
            principal: request.principal,
            appContext: request.appContext,
            permissions: request.requiredPermissions,
            expiresAt: request.expiresAt
        )
        return CapabilityApprovalGrant(token: token)
    }

    func consume(
        _ grant: CapabilityApprovalGrant,
        plan: CapabilityExecutionPlan,
        digest: String,
        requiredPermissions: Set<String>,
        now: Date
    ) throws {
        if consumedTokens.contains(grant.token) {
            throw CapabilityBrokerError.approvalReplayed
        }
        guard let issued = grants.removeValue(forKey: grant.token),
              issued.planID == plan.id,
              issued.planDigest == digest,
              issued.principal == plan.principal,
              issued.appContext == plan.appContext,
              requiredPermissions.isSubset(of: issued.permissions) else {
            throw CapabilityBrokerError.approvalInvalid
        }
        consumedTokens.insert(grant.token)
        if consumedTokens.count > 1_024 {
            consumedTokens.removeAll(keepingCapacity: true)
            consumedTokens.insert(grant.token)
        }
        guard now <= issued.expiresAt else {
            throw CapabilityBrokerError.approvalExpired
        }
    }
}
