import CryptoKit
import Foundation

extension CapabilityValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Non-finite number")
            }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CapabilityValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: CapabilityValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

enum CapabilityOrigin: String, Codable, CaseIterable, Sendable {
    case nativeUI = "native_ui"
    case voice
    case text
    case pocketSurface = "pocket_surface"
    case mcp
    case connector
}

struct CapabilityPrincipal: Codable, Equatable, Sendable {
    let userID: String
    let pocketAppID: String?
    let agentSessionID: String?

    init(userID: String, pocketAppID: String? = nil, agentSessionID: String? = nil) {
        self.userID = userID
        self.pocketAppID = pocketAppID
        self.agentSessionID = agentSessionID
    }
}

struct CapabilityAppContext: Codable, Equatable, Sendable {
    let id: String
    let version: String
    let manifestDigest: String
}

enum CapabilityEffect: String, Codable, Sendable {
    case pure
    case privateRead = "private_read"
    case reversibleLocalWrite = "reversible_local_write"
    case externalWrite = "external_write"
    case destructiveSensitive = "destructive_sensitive"
    case nativeAuthority = "native_authority"

    var isWrite: Bool {
        switch self {
        case .pure, .privateRead:
            false
        case .reversibleLocalWrite, .externalWrite, .destructiveSensitive, .nativeAuthority:
            true
        }
    }
}

enum CapabilityApprovalPolicy: String, Codable, Sendable {
    case none
    case permissionGrant = "permission_grant"
    case brokerPolicy = "broker_policy"
    case perCall = "per_call"
    case strongPerCall = "strong_per_call"
    case runtimeProhibited = "runtime_prohibited"

    var requiresExecutionApproval: Bool {
        switch self {
        case .brokerPolicy, .perCall, .strongPerCall:
            true
        case .none, .permissionGrant, .runtimeProhibited:
            false
        }
    }
}

enum CapabilityIdempotencyPolicy: String, Codable, Sendable {
    case notApplicable = "not_applicable"
    case optional
    case required
}

enum CapabilityReadbackStrategy: String, Codable, Sendable {
    case none
    case entityGetByID = "entity_get_by_id"
    case capabilityQuery = "capability_query"
    case sameStoreSnapshot = "same_store_snapshot"
    case osState = "os_state"
    case contentDigest = "content_digest"
}

struct CapabilityLimits: Codable, Equatable, Sendable {
    let timeoutMilliseconds: Int
    let maximumPayloadBytes: Int
    let maximumCallsPerMinute: Int
}

struct CapabilityReadbackPolicy: Codable, Equatable, Sendable {
    let strategy: CapabilityReadbackStrategy
    let query: PocketCapabilityKey?
    let matchFields: [String]
}

struct CapabilityPlanStep: Codable, Equatable, Sendable {
    let id: String
    let capability: PocketCapabilityKey
    let arguments: CapabilityObject
    let idempotencyKey: String
    let dependencies: [String]
}

struct CapabilityExecutionPlan: Codable, Equatable, Sendable {
    let id: String
    let createdAt: Date
    let origin: CapabilityOrigin
    let principal: CapabilityPrincipal
    let appContext: CapabilityAppContext?
    let steps: [CapabilityPlanStep]
    let requiredPermissions: Set<String>
}

struct CapabilityPermissionSet: Equatable, Sendable {
    let principal: CapabilityPrincipal
    let permissions: Set<String>

    func contains(_ required: Set<String>) -> Bool {
        required.isSubset(of: permissions)
    }
}

struct CapabilityApprovalEffect: Codable, Equatable, Sendable {
    let stepID: String
    let capability: PocketCapabilityKey
    let effect: CapabilityEffect
    let argumentDigest: String
    let summaryKey: String
    let rollbackAvailable: Bool
}

struct CapabilityApprovalRequest: Codable, Equatable, Sendable {
    let id: String
    let planID: String
    let planDigest: String
    let principal: CapabilityPrincipal
    let appContext: CapabilityAppContext?
    let createdAt: Date
    let expiresAt: Date
    let nonce: String
    let effects: [CapabilityApprovalEffect]
    let requiredPermissions: Set<String>
}

struct CapabilityBrokerPreparation: Equatable, Sendable {
    let planDigest: String
    let approvalRequest: CapabilityApprovalRequest?
    let approvalPresentations: [CapabilityApprovalPresentation]
}

struct CapabilityApprovalGrant: Equatable, Sendable {
    let token: String
}

enum CapabilityReceiptStatus: String, Codable, Sendable {
    case succeeded
    case rejected
    case failed
    case partial
    case unknown
}

enum CapabilityReadbackStatus: String, Codable, Sendable {
    case verified
    case mismatch
    case unavailable
}

struct CapabilityReadbackReceipt: Codable, Equatable, Sendable {
    let status: CapabilityReadbackStatus
    let strategy: CapabilityReadbackStrategy
    let observedAt: Date?
    let observed: CapabilityObject?
    let evidenceDigest: String?
}

struct CapabilitySafeError: Codable, Equatable, Sendable {
    let code: String
    let retryable: Bool
    let messageKey: String
}

struct CapabilityReceipt: Codable, Equatable, Sendable {
    let invocationID: String
    let planID: String
    let planDigest: String
    let capability: PocketCapabilityKey
    let status: CapabilityReceiptStatus
    let output: CapabilityObject?
    let readback: CapabilityReadbackReceipt
    let rollbackAvailable: Bool
    let rollbackStatus: String?
    let auditEntryID: String
    let safeError: CapabilitySafeError?
    let completedAt: Date
    let replayed: Bool

    func replayCopy() -> CapabilityReceipt {
        CapabilityReceipt(
            invocationID: invocationID,
            planID: planID,
            planDigest: planDigest,
            capability: capability,
            status: status,
            output: output,
            readback: readback,
            rollbackAvailable: rollbackAvailable,
            rollbackStatus: rollbackStatus,
            auditEntryID: auditEntryID,
            safeError: safeError,
            completedAt: completedAt,
            replayed: true
        )
    }

    func durableCopy() -> CapabilityReceipt {
        CapabilityReceipt(
            invocationID: invocationID,
            planID: planID,
            planDigest: planDigest,
            capability: capability,
            status: status,
            output: nil,
            readback: CapabilityReadbackReceipt(
                status: readback.status,
                strategy: readback.strategy,
                observedAt: readback.observedAt,
                observed: nil,
                evidenceDigest: readback.evidenceDigest
            ),
            rollbackAvailable: rollbackAvailable,
            rollbackStatus: rollbackStatus,
            auditEntryID: auditEntryID,
            safeError: safeError,
            completedAt: completedAt,
            replayed: replayed
        )
    }

    func withRollbackStatus(_ status: String) -> CapabilityReceipt {
        CapabilityReceipt(
            invocationID: invocationID,
            planID: planID,
            planDigest: planDigest,
            capability: capability,
            status: self.status,
            output: output,
            readback: readback,
            rollbackAvailable: rollbackAvailable,
            rollbackStatus: status,
            auditEntryID: auditEntryID,
            safeError: safeError,
            completedAt: completedAt,
            replayed: replayed
        )
    }
}

struct CapabilityWorkflowReceipt: Codable, Equatable, Sendable {
    let planID: String
    let planDigest: String
    let status: CapabilityReceiptStatus
    let steps: [CapabilityReceipt]
    let completedAt: Date
    let replayed: Bool

    func replayCopy() -> CapabilityWorkflowReceipt {
        CapabilityWorkflowReceipt(
            planID: planID,
            planDigest: planDigest,
            status: status,
            steps: steps.map { $0.replayCopy() },
            completedAt: completedAt,
            replayed: true
        )
    }

    func durableCopy() -> CapabilityWorkflowReceipt {
        CapabilityWorkflowReceipt(
            planID: planID,
            planDigest: planDigest,
            status: status,
            steps: steps.map { $0.durableCopy() },
            completedAt: completedAt,
            replayed: replayed
        )
    }
}

enum CapabilityBrokerError: Error, Equatable, Sendable {
    case invalidPlan(String)
    case unknownCapability(PocketCapabilityKey)
    case removedCapability(PocketCapabilityKey, PocketCapabilityKey?)
    case unavailable(PocketCapabilityKey)
    case runtimeProhibited(PocketCapabilityKey)
    case invalidArguments(PocketCapabilityKey, String)
    case permissionDenied(String)
    case approvalRequired
    case approvalRejected
    case approvalExpired
    case approvalInvalid
    case approvalReplayed
    case idempotencyConflict(String)
    case executionUnknown(String)
    case rateLimited(PocketCapabilityKey)
    case timedOut(PocketCapabilityKey)
    case ledgerUnavailable
}

enum CapabilityCanonicalJSON {
    static func digest(_ value: CapabilityValue) throws -> String {
        let data = try data(value)
        return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ object: CapabilityObject) throws -> String {
        try digest(.object(object))
    }

    static func data(_ value: CapabilityValue) throws -> Data {
        try JSONSerialization.data(withJSONObject: foundation(value), options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func planDigest(_ plan: CapabilityExecutionPlan) throws -> String {
        let steps = plan.steps.map { step in
            CapabilityValue.object([
                "arguments": .object(step.arguments),
                "capabilityId": .string(step.capability.id),
                "capabilityVersion": .integer(step.capability.version),
                "dependsOn": .array(step.dependencies.sorted().map(CapabilityValue.string)),
                "idempotencyKey": .string(step.idempotencyKey),
                "stepId": .string(step.id)
            ])
        }
        var principal: CapabilityObject = ["userId": .string(plan.principal.userID)]
        if let value = plan.principal.pocketAppID { principal["pocketAppId"] = .string(value) }
        if let value = plan.principal.agentSessionID { principal["agentSessionId"] = .string(value) }
        var root: CapabilityObject = [
            "createdAt": .string(CapabilityDateCodec.string(from: plan.createdAt)),
            "origin": .string(plan.origin.rawValue),
            "planId": .string(plan.id),
            "planVersion": .integer(1),
            "principal": .object(principal),
            "requiredPermissions": .array(plan.requiredPermissions.sorted().map(CapabilityValue.string)),
            "steps": .array(steps)
        ]
        if let app = plan.appContext {
            root["appContext"] = .object([
                "id": .string(app.id),
                "manifestDigest": .string(app.manifestDigest),
                "version": .string(app.version)
            ])
        }
        return try digest(root)
    }

    private static func foundation(_ value: CapabilityValue) -> Any {
        switch value {
        case .null:
            NSNull()
        case .bool(let value):
            value
        case .integer(let value):
            value
        case .number(let value):
            value
        case .string(let value):
            value
        case .array(let values):
            values.map(foundation)
        case .object(let object):
            object.mapValues(foundation)
        }
    }
}

extension PocketCapabilityKey: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            version: try container.decode(Int.self, forKey: .version)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(version, forKey: .version)
    }
}
