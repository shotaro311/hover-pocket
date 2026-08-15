import Foundation

struct PocketAppWorkflowDraft: Equatable, Sendable {
    let packageID: String
    let workflowID: String
    let plan: CapabilityExecutionPlan
    let preparation: CapabilityBrokerPreparation
}

@MainActor
final class PocketAppExecutionRuntime {
    private static let presentableWorkflowCapabilities: Set<PocketCapabilityKey> = [
        PocketCapabilityKeys.timerStart,
        PocketCapabilityKeys.stickyUpsert
    ]

    let package: PocketAppPackage
    let userStateStore: PocketAppUserStateStore?

    private let broker: CapabilityBroker
    private let principal: CapabilityPrincipal
    private let grantedPermissions: Set<String>
    private let timeZone: TimeZone

    init(
        package: PocketAppPackage,
        broker: CapabilityBroker,
        userID: String,
        grantedPermissions: Set<String>,
        timeZone: TimeZone = .current,
        userStateStore: PocketAppUserStateStore? = nil
    ) {
        self.package = package
        self.broker = broker
        self.principal = CapabilityPrincipal(userID: userID, pocketAppID: package.manifest.id)
        self.grantedPermissions = grantedPermissions
        self.timeZone = timeZone
        self.userStateStore = userStateStore
    }

    func query(
        reference: String,
        arguments: [String: PocketJSONValue],
        now: Date = Date()
    ) async throws -> CapabilityObject {
        let key = try capabilityKey(reference)
        let request = try requestedCapability(key)
        guard request.effect == .pure || request.effect == .privateRead else {
            throw CapabilityBrokerError.invalidPlan("query_effect")
        }
        let resolvedArguments = try arguments.mapValues { try resolve($0, inputs: [:], now: now) }
        try validateScope(resolvedArguments, request: request)
        let nonce = UUID().uuidString.lowercased()
        let plan = CapabilityExecutionPlan(
            id: "pocket-query:\(nonce)",
            createdAt: now,
            origin: .pocketSurface,
            principal: principal,
            appContext: appContext,
            steps: [
                CapabilityPlanStep(
                    id: "query",
                    capability: key,
                    arguments: resolvedArguments,
                    idempotencyKey: "pocket-query.\(nonce)",
                    dependencies: []
                )
            ],
            requiredPermissions: request.permissions
        )
        let permissions = permissionSet
        let preparation = try broker.prepare(plan, permissions: permissions, now: now)
        guard preparation.approvalRequest == nil else {
            throw CapabilityBrokerError.invalidPlan("query_approval")
        }
        let receipt = try await broker.execute(
            plan,
            permissions: permissions,
            approvalGrant: nil,
            now: now
        )
        guard receipt.status == .succeeded,
              let output = receipt.steps.first?.output else {
            throw CapabilityBrokerError.unavailable(key)
        }
        return output
    }

    func prepare(
        workflowID: String,
        inputs: [String: CapabilityValue],
        now: Date = Date()
    ) throws -> PocketAppWorkflowDraft {
        guard let workflow = package.workflows[workflowID] else {
            throw CapabilityBrokerError.invalidPlan("pocket_workflow")
        }
        try validateInputs(inputs, workflow: workflow)
        let nonce = UUID().uuidString.lowercased()
        let steps = try workflow.steps.map { step in
            guard Self.supportsWorkflowPresentation(step.capability) else {
                throw CapabilityBrokerError.invalidPlan("pocket_workflow_presentation")
            }
            let resolvedArguments = try step.arguments.mapValues { try resolve($0, inputs: inputs, now: now) }
            let arguments = try Self.canonicalWorkflowArguments(
                resolvedArguments,
                capability: step.capability
            )
            let request = try requestedCapability(step.capability)
            try validateScope(arguments, request: request)
            return CapabilityPlanStep(
                id: step.id,
                capability: step.capability,
                arguments: arguments,
                idempotencyKey: "pocket-workflow.\(nonce).\(step.id)",
                dependencies: step.dependencies
            )
        }
        let plan = CapabilityExecutionPlan(
            id: "pocket-workflow:\(nonce)",
            createdAt: now,
            origin: .pocketSurface,
            principal: principal,
            appContext: appContext,
            steps: steps,
            requiredPermissions: workflow.requiredPermissions
        )
        return PocketAppWorkflowDraft(
            packageID: package.manifest.id,
            workflowID: workflowID,
            plan: plan,
            preparation: try broker.prepare(plan, permissions: permissionSet, now: now)
        )
    }

    func approveAndExecute(
        _ draft: PocketAppWorkflowDraft,
        now: Date = Date()
    ) async throws -> CapabilityWorkflowReceipt {
        try validateDraft(draft)
        guard let request = draft.preparation.approvalRequest else {
            throw CapabilityBrokerError.approvalRequired
        }
        let grant = try broker.decideApproval(
            requestID: request.id,
            planDigest: draft.preparation.planDigest,
            decision: .approve,
            now: now
        )
        return try await broker.execute(
            draft.plan,
            permissions: permissionSet,
            approvalGrant: grant,
            now: now
        )
    }

    func reject(_ draft: PocketAppWorkflowDraft, now: Date = Date()) {
        do {
            try validateDraft(draft)
            guard let request = draft.preparation.approvalRequest else { return }
            _ = try broker.decideApproval(
                requestID: request.id,
                planDigest: draft.preparation.planDigest,
                decision: .reject,
                now: now
            )
        } catch CapabilityBrokerError.approvalRejected {
        } catch {
        }
    }

    private var appContext: CapabilityAppContext {
        CapabilityAppContext(
            id: package.manifest.id,
            version: package.manifest.version,
            manifestDigest: package.manifestDigest
        )
    }

    private var permissionSet: CapabilityPermissionSet {
        let requestedPermissions = package.manifest.requestedCapabilities.reduce(into: Set<String>()) {
            $0.formUnion($1.permissions)
        }
        return CapabilityPermissionSet(
            principal: principal,
            permissions: grantedPermissions.intersection(requestedPermissions)
        )
    }

    private func requestedCapability(_ key: PocketCapabilityKey) throws -> PocketAppRequestedCapability {
        guard let request = package.manifest.requestedCapabilities.first(where: { $0.key == key }) else {
            throw CapabilityBrokerError.unknownCapability(key)
        }
        return request
    }

    private func validateDraft(_ draft: PocketAppWorkflowDraft) throws {
        guard draft.packageID == package.manifest.id,
              package.workflows[draft.workflowID] != nil,
              draft.plan.principal == principal,
              draft.plan.appContext == appContext,
              draft.plan.origin == .pocketSurface else {
            throw CapabilityBrokerError.invalidPlan("pocket_draft")
        }
    }

    private func validateInputs(
        _ inputs: [String: CapabilityValue],
        workflow: PocketAppWorkflowDocument
    ) throws {
        guard Set(inputs.keys) == Set(workflow.inputs.keys) else {
            throw CapabilityBrokerError.invalidPlan("pocket_inputs")
        }
        for (name, type) in workflow.inputs {
            guard let value = inputs[name], Self.accepts(value, type: type) else {
                throw CapabilityBrokerError.invalidPlan("pocket_input_\(name)")
            }
        }
    }

    private static func accepts(_ value: CapabilityValue, type: String) -> Bool {
        switch (type, value) {
        case ("string", .string), ("entity-ref", .string), ("integer", .integer),
             ("number", .integer), ("number", .number), ("boolean", .bool):
            true
        case ("date-time", .string(let value)):
            CapabilityDateCodec.date(from: value) != nil
        default:
            false
        }
    }

    private func resolve(
        _ value: PocketJSONValue,
        inputs: [String: CapabilityValue],
        now: Date
    ) throws -> CapabilityValue {
        switch value {
        case .null:
            return .null
        case .bool(let value):
            return .bool(value)
        case .number(let value):
            if value.rounded() == value, value >= Double(Int.min), value <= Double(Int.max) {
                return .integer(Int(value))
            }
            return .number(value)
        case .string(let value):
            if value.hasPrefix("$input.") {
                let name = String(value.dropFirst("$input.".count))
                guard let resolved = inputs[name] else {
                    throw CapabilityBrokerError.invalidPlan("pocket_binding")
                }
                return resolved
            }
            if value == "$context.timezone" {
                return .string(timeZone.identifier)
            }
            if value == "$context.todayFocusStableKey" {
                return .string("today-focus:\(Self.localDateKey(now, timeZone: timeZone))")
            }
            if value.hasPrefix("$") {
                throw CapabilityBrokerError.invalidPlan("pocket_context")
            }
            return .string(value)
        case .array(let values):
            return .array(try values.map { try resolve($0, inputs: inputs, now: now) })
        case .object(let object):
            return .object(try object.mapValues { try resolve($0, inputs: inputs, now: now) })
        }
    }

    private func validateScope(
        _ arguments: CapabilityObject,
        request: PocketAppRequestedCapability
    ) throws {
        guard case .object(let scope)? = request.scope else { return }
        if case .string(let range)? = scope["range"], arguments["range"] != .string(range) {
            throw CapabilityBrokerError.invalidPlan("pocket_scope_range")
        }
        if case .string(let namespace)? = scope["namespace"] {
            guard case .string(let stableKey)? = arguments["stableKey"],
                  stableKey.hasPrefix("\(namespace):") else {
                throw CapabilityBrokerError.invalidPlan("pocket_scope_namespace")
            }
        }
    }

    private func capabilityKey(_ reference: String) throws -> PocketCapabilityKey {
        guard let marker = reference.lastIndex(of: "@"),
              let version = Int(reference[reference.index(after: marker)...]),
              version >= 1 else {
            throw CapabilityBrokerError.invalidPlan("pocket_capability")
        }
        return PocketCapabilityKey(id: String(reference[..<marker]), version: version)
    }

    private static func localDateKey(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func canonicalWorkflowArguments(
        _ arguments: CapabilityObject,
        capability: PocketCapabilityKey
    ) throws -> CapabilityObject {
        var canonical = arguments
        if capability == PocketCapabilityKeys.timerStart {
            guard case .string(let title)? = canonical["title"] else {
                throw CapabilityBrokerError.invalidPlan("pocket_workflow_presentation")
            }
            canonical["title"] = .string(TodayFocusApprovalText.sanitize(title))
        } else if capability == PocketCapabilityKeys.stickyUpsert {
            guard case .string(let title)? = canonical["title"],
                  case .string(let body)? = canonical["body"] else {
                throw CapabilityBrokerError.invalidPlan("pocket_workflow_presentation")
            }
            canonical["title"] = .string(TodayFocusApprovalText.sanitize(title))
            canonical["body"] = .string(TodayFocusApprovalText.sanitize(body))
        }
        return canonical
    }

    static func supportsWorkflowPresentation(_ capability: PocketCapabilityKey) -> Bool {
        presentableWorkflowCapabilities.contains(capability)
    }
}
