import CryptoKit
import Foundation

struct CodexVoiceCapabilityApprovalField: Equatable, Sendable {
    let key: String
    let value: String
}

struct CodexVoiceCapabilityApproval: Equatable, Sendable {
    let toolName: String
    let fields: [CodexVoiceCapabilityApprovalField]
}

struct CodexVoiceToolAuthorization: Equatable, Sendable {
    let isAllowed: Bool
    let epoch: UInt64
    let grantedPermissions: Set<String>
}

struct CodexVoiceToolRequestContext: Equatable, Sendable {
    let rootThreadID: String
    let clientGeneration: UInt64
}

@MainActor
protocol CodexVoiceCapabilityToolAdapterProtocol: AnyObject {
    var dynamicTools: [CodexJSONValue] { get }

    func handle(
        request: CodexAppServerRequest,
        context: CodexVoiceToolRequestContext
    ) async -> CodexAppServerReply
}

@MainActor
final class CodexVoiceCapabilityToolAdapter: CodexVoiceCapabilityToolAdapterProtocol {
    static let calendarTodayTool = "hoverpocket_calendar_today"
    static let timerStartTool = "hoverpocket_timer_start"
    static let calendarCreateTool = "hoverpocket_calendar_create"
    static let todayFocusTool = "hoverpocket_today_focus"

    typealias ApprovalRequester = (CodexVoiceCapabilityApproval) async -> Bool
    typealias AuthorizationProvider = () -> CodexVoiceToolAuthorization

    private static let maximumToolRequestBytes = 20 * 1_024
    private static let maximumToolArgumentBytes = 16 * 1_024
    private static let maximumPendingCalls = 8
    private static let maximumCachedCalls = 128

    private let broker: CapabilityBroker
    private let todayFocus: TodayFocusTextAdapter
    private let requestApproval: ApprovalRequester
    private let authorization: AuthorizationProvider
    private let now: () -> Date
    private let callGate = CodexVoiceToolCallGate()
    private var pendingCalls = 0
    private var completedCalls: [String: CachedToolReply] = [:]
    private var completedCallOrder: [String] = []

    init(
        broker: CapabilityBroker,
        todayFocus: TodayFocusTextAdapter,
        requestApproval: @escaping ApprovalRequester,
        authorization: @escaping AuthorizationProvider = {
            CodexVoiceToolAuthorization(
                isAllowed: true,
                epoch: 0,
                grantedPermissions: []
            )
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.broker = broker
        self.todayFocus = todayFocus
        self.requestApproval = requestApproval
        self.authorization = authorization
        self.now = now
    }

    var dynamicTools: [CodexJSONValue] {
        guard authorization().grantedPermissions.contains("calendar.events.read") else {
            return Self.toolSpecs.filter { spec in
                guard let name = spec.objectValue?["name"]?.stringValue else { return false }
                return name != Self.calendarTodayTool && name != Self.todayFocusTool
            }
        }
        return Self.toolSpecs
    }

    func handle(
        request: CodexAppServerRequest,
        context: CodexVoiceToolRequestContext
    ) async -> CodexAppServerReply {
        guard request.method == "item/tool/call" else {
            return .failure(
                code: -32601,
                message: "HoverPocket has no handler for app-server request: \(request.method)"
            )
        }
        let expectedAuthorization = authorization()
        guard expectedAuthorization.isAllowed, context.clientGeneration > 0 else {
            return toolReply(
                success: false,
                payload: ["status": .string("rejected"), "code": .string("CAPABILITY_REQUEST_DENIED")]
            )
        }
        guard pendingCalls < Self.maximumPendingCalls else {
            return toolReply(
                success: false,
                payload: ["status": .string("rejected"), "code": .string("CAPABILITY_OVERLOADED")]
            )
        }

        pendingCalls += 1
        defer { pendingCalls -= 1 }
        let call: DynamicToolCall
        do {
            call = try parseCall(request.params, expectedRootThreadID: context.rootThreadID)
        } catch let error as CodexVoiceToolError {
            return toolErrorReply(error.code)
        } catch {
            return toolErrorReply("CAPABILITY_REQUEST_INVALID")
        }

        await callGate.acquire()
        let reply = await handleSerialized(
            call: call,
            context: context,
            expectedAuthorization: expectedAuthorization
        )
        await callGate.release()
        return reply
    }

    private func handleSerialized(
        call: DynamicToolCall,
        context: CodexVoiceToolRequestContext,
        expectedAuthorization: CodexVoiceToolAuthorization
    ) async -> CodexAppServerReply {
        guard isAuthorizationCurrent(expectedAuthorization) else {
            return toolErrorReply("CAPABILITY_REQUEST_DENIED")
        }
        do {
            let token = Self.callToken(call)
            let cacheKey = "\(context.clientGeneration):\(expectedAuthorization.epoch):\(token)"
            let argumentDigest = try CapabilityCanonicalJSON.digest(call.arguments)
            let fingerprint = "\(call.tool):\(argumentDigest)"
            if let cached = completedCalls[cacheKey] {
                return cached.callFingerprint == fingerprint
                    ? cached.reply
                    : toolErrorReply("CAPABILITY_IDEMPOTENCY_CONFLICT")
            }

            let reply: CodexAppServerReply
            switch call.tool {
            case Self.calendarTodayTool:
                reply = try await listToday(call, authorization: expectedAuthorization)
            case Self.timerStartTool:
                reply = try await startTimer(call, authorization: expectedAuthorization)
            case Self.calendarCreateTool:
                reply = try await createCalendarEvent(call, authorization: expectedAuthorization)
            case Self.todayFocusTool:
                reply = try await startTodayFocus(call, authorization: expectedAuthorization)
            default:
                reply = toolErrorReply("CAPABILITY_UNKNOWN")
            }

            guard isAuthorizationCurrent(expectedAuthorization) else {
                return toolErrorReply("CAPABILITY_REQUEST_DENIED")
            }
            cacheReply(cacheKey, fingerprint: fingerprint, reply: reply)
            return reply
        } catch let error as CodexVoiceToolError {
            return toolErrorReply(error.code)
        } catch let error as CapabilityBrokerError {
            return toolErrorReply(Self.errorCode(error), status: "failed")
        } catch let error as CapabilityHandlerError {
            return toolErrorReply(error.code, status: "failed")
        } catch {
            return toolErrorReply("CAPABILITY_FAILED", status: "failed")
        }
    }

    private func listToday(
        _ call: DynamicToolCall,
        authorization: CodexVoiceToolAuthorization
    ) async throws -> CodexAppServerReply {
        try requireOnlyKeys(call.arguments, allowed: [])
        let principal = Self.principal(call.threadID)
        let permissions = try calendarReadPermissions(
            principal: principal,
            authorization: authorization
        )
        let events = try await todayFocus.listToday(
            timezone: .current,
            principal: principal,
            permissions: permissions,
            now: now(),
            origin: .voice
        )
        let safeEvents = events.prefix(64).map { event in
            CodexJSONValue.object([
                "eventRef": .string(event.eventRef),
                "safeTitle": .string(event.safeTitle),
                "start": .string(CapabilityDateCodec.string(from: event.start)),
                "end": .string(CapabilityDateCodec.string(from: event.end))
            ])
        }
        return toolReply(
            success: true,
            payload: ["status": .string("succeeded"), "events": .array(safeEvents)]
        )
    }

    private func startTimer(
        _ call: DynamicToolCall,
        authorization: CodexVoiceToolAuthorization
    ) async throws -> CodexAppServerReply {
        try requireOnlyKeys(call.arguments, allowed: ["durationSeconds", "title"])
        let duration = try requiredInteger(call.arguments, "durationSeconds", range: 1...86_400)
        let rawTitle = try optionalString(call.arguments, "title", maximum: 80)
        let title = TodayFocusApprovalText.sanitize(
            rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? rawTitle!
                : "タイマー"
        )
        let timestamp = now()
        let principal = Self.principal(call.threadID)
        let permissionSet = Self.permissions(principal, ["timer.write"])
        let token = Self.callToken(call)
        let plan = CapabilityExecutionPlan(
            id: "voice-timer:\(token)",
            createdAt: timestamp,
            origin: .voice,
            principal: principal,
            appContext: nil,
            steps: [CapabilityPlanStep(
                id: "startTimer",
                capability: PocketCapabilityKeys.timerStart,
                arguments: [
                    "durationSeconds": .integer(duration),
                    "title": .string(title),
                    "sourceRef": .string("voice:\(call.threadID)")
                ],
                idempotencyKey: "voice-timer.\(token)",
                dependencies: []
            )],
            requiredPermissions: ["timer.write"]
        )
        let receipt = try await approveAndExecute(
            plan: plan,
            permissions: permissionSet,
            approval: CodexVoiceCapabilityApproval(
                toolName: Self.timerStartTool,
                fields: [
                    CodexVoiceCapabilityApprovalField(key: "title", value: title),
                    CodexVoiceCapabilityApprovalField(key: "durationSeconds", value: String(duration))
                ]
            ),
            authorization: authorization
        )
        return receiptReply(receipt)
    }

    private func createCalendarEvent(
        _ call: DynamicToolCall,
        authorization: CodexVoiceToolAuthorization
    ) async throws -> CodexAppServerReply {
        try requireOnlyKeys(call.arguments, allowed: ["title", "start", "end", "isAllDay"])
        let title = TodayFocusApprovalText.sanitize(
            try requiredString(call.arguments, "title", maximum: 80)
        )
        let start = try requiredDate(call.arguments, "start")
        let end = try requiredDate(call.arguments, "end")
        let isAllDay = try requiredBool(call.arguments, "isAllDay")
        let canonicalStart = CapabilityDateCodec.string(from: start)
        let canonicalEnd = CapabilityDateCodec.string(from: end)
        let timestamp = now()
        let principal = Self.principal(call.threadID)
        let permissionSet = Self.permissions(principal, ["calendar.events.write"])
        let token = Self.callToken(call)
        let plan = CapabilityExecutionPlan(
            id: "voice-calendar-create:\(token)",
            createdAt: timestamp,
            origin: .voice,
            principal: principal,
            appContext: nil,
            steps: [CapabilityPlanStep(
                id: "createCalendar",
                capability: PocketCapabilityKeys.calendarCreate,
                arguments: [
                    "calendarId": .null,
                    "title": .string(title),
                    "start": .string(canonicalStart),
                    "end": .string(canonicalEnd),
                    "isAllDay": .bool(isAllDay),
                    "location": .null,
                    "notes": .null
                ],
                idempotencyKey: "voice-calendar.\(token)",
                dependencies: []
            )],
            requiredPermissions: ["calendar.events.write"]
        )
        let receipt = try await approveAndExecute(
            plan: plan,
            permissions: permissionSet,
            approval: CodexVoiceCapabilityApproval(
                toolName: Self.calendarCreateTool,
                fields: [
                    CodexVoiceCapabilityApprovalField(key: "title", value: title),
                    CodexVoiceCapabilityApprovalField(key: "start", value: canonicalStart),
                    CodexVoiceCapabilityApprovalField(key: "end", value: canonicalEnd),
                    CodexVoiceCapabilityApprovalField(key: "isAllDay", value: isAllDay ? "true" : "false")
                ]
            ),
            authorization: authorization
        )
        return receiptReply(receipt)
    }

    private func startTodayFocus(
        _ call: DynamicToolCall,
        authorization: CodexVoiceToolAuthorization
    ) async throws -> CodexAppServerReply {
        try requireOnlyKeys(call.arguments, allowed: ["eventRef", "durationSeconds", "purpose"])
        let eventRef = try requiredString(call.arguments, "eventRef", maximum: 256)
        let duration = call.arguments["durationSeconds"] == nil
            ? 1_500
            : try requiredInteger(call.arguments, "durationSeconds", range: 1...86_400)
        let requestedPurpose = try optionalString(call.arguments, "purpose", maximum: 10_000)
        let timestamp = now()
        let principal = Self.principal(call.threadID)
        let calendarReadPermissions = try calendarReadPermissions(
            principal: principal,
            authorization: authorization
        )
        let events = try await todayFocus.listToday(
            timezone: .current,
            principal: principal,
            permissions: calendarReadPermissions,
            now: timestamp,
            origin: .voice
        )
        guard let selected = events.first(where: { $0.eventRef == eventRef }) else {
            throw CodexVoiceToolError("CAPABILITY_UNAVAILABLE")
        }
        let purpose = requestedPurpose?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? requestedPurpose!
            : (selected.safeTitle.isEmpty ? "今日の予定" : selected.safeTitle)
        let permissionSet = Self.permissions(principal, ["sticky.write", "timer.write"])
        let draft = try todayFocus.prepareFocus(
            event: selected,
            durationSeconds: duration,
            purpose: purpose,
            principal: principal,
            permissions: permissionSet,
            now: timestamp,
            timeZone: .current,
            origin: .voice,
            operationToken: Self.callToken(call)
        )
        let receipt = try await approveAndExecute(
            plan: draft.plan,
            permissions: permissionSet,
            approval: CodexVoiceCapabilityApproval(
                toolName: Self.todayFocusTool,
                fields: [
                    CodexVoiceCapabilityApprovalField(
                        key: "event",
                        value: TodayFocusApprovalText.sanitize(selected.safeTitle)
                    ),
                    CodexVoiceCapabilityApprovalField(key: "purpose", value: draft.approvalText),
                    CodexVoiceCapabilityApprovalField(key: "durationSeconds", value: String(duration))
                ]
            ),
            authorization: authorization,
            preparation: draft.preparation
        )
        return receiptReply(receipt)
    }

    private func approveAndExecute(
        plan: CapabilityExecutionPlan,
        permissions: CapabilityPermissionSet,
        approval: CodexVoiceCapabilityApproval,
        authorization expectedAuthorization: CodexVoiceToolAuthorization,
        preparation: CapabilityBrokerPreparation? = nil
    ) async throws -> CapabilityWorkflowReceipt {
        guard isAuthorizationCurrent(expectedAuthorization) else {
            throw CodexVoiceToolError("CAPABILITY_REQUEST_DENIED")
        }
        let prepared = try preparation ?? broker.prepare(plan, permissions: permissions, now: now())
        guard let request = prepared.approvalRequest else {
            throw CodexVoiceToolError("CAPABILITY_APPROVAL_REQUIRED")
        }
        let approved = await requestApproval(approval)
        guard approved, isAuthorizationCurrent(expectedAuthorization) else {
            do {
                _ = try broker.decideApproval(
                    requestID: request.id,
                    planDigest: prepared.planDigest,
                    decision: .reject,
                    now: now()
                )
            } catch CapabilityBrokerError.approvalRejected {
            }
            throw CodexVoiceToolError("CAPABILITY_APPROVAL_REJECTED")
        }
        let grant = try broker.decideApproval(
            requestID: request.id,
            planDigest: prepared.planDigest,
            decision: .approve,
            now: now()
        )
        guard isAuthorizationCurrent(expectedAuthorization) else {
            throw CodexVoiceToolError("CAPABILITY_REQUEST_DENIED")
        }
        return try await broker.execute(
            plan,
            permissions: permissions,
            approvalGrant: grant,
            now: now()
        )
    }

    private func receiptReply(_ receipt: CapabilityWorkflowReceipt) -> CodexAppServerReply {
        let readbackVerified = receipt.steps.allSatisfy { $0.readback.status == .verified }
        let succeeded = receipt.status == .succeeded && readbackVerified
        let steps = receipt.steps.map { step in
            CodexJSONValue.object([
                "capability": .string(step.capability.id),
                "status": .string(step.status.rawValue),
                "output": step.output.map(Self.codexValue) ?? .null,
                "errorCode": step.safeError.map { .string($0.code) } ?? .null
            ])
        }
        return toolReply(
            success: succeeded,
            payload: [
                "status": .string(receipt.status.rawValue),
                "replayed": .bool(receipt.replayed),
                "readbackVerified": .bool(readbackVerified),
                "steps": .array(steps)
            ]
        )
    }

    private func toolErrorReply(_ code: String, status: String = "rejected") -> CodexAppServerReply {
        toolReply(
            success: false,
            payload: ["status": .string(status), "code": .string(code)]
        )
    }

    private func toolReply(
        success: Bool,
        payload: [String: CodexJSONValue]
    ) -> CodexAppServerReply {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(CodexJSONValue.object(payload)))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"status":"failed","code":"CAPABILITY_FAILED"}"#
        return .success(.object([
            "success": .bool(success),
            "contentItems": .array([.object([
                "type": .string("inputText"),
                "text": .string(text)
            ])])
        ]))
    }

    private func parseCall(
        _ params: CodexJSONValue?,
        expectedRootThreadID: String
    ) throws -> DynamicToolCall {
        guard Self.validIdentifier(expectedRootThreadID),
              let params,
              Self.encodedSize(params) <= Self.maximumToolRequestBytes,
              let object = params.objectValue else {
            throw CodexVoiceToolError("CAPABILITY_REQUEST_INVALID")
        }
        try requireOnlyKeys(
            object,
            allowed: ["arguments", "callId", "namespace", "threadId", "tool", "turnId"]
        )
        let callID = try requiredIdentifier(object, "callId")
        let threadID = try requiredIdentifier(object, "threadId")
        let tool = try requiredIdentifier(object, "tool")
        let turnID = try requiredIdentifier(object, "turnId")
        guard threadID == expectedRootThreadID,
              object["namespace"] == nil || object["namespace"] == .null else {
            throw CodexVoiceToolError("CAPABILITY_REQUEST_DENIED")
        }
        guard case .object(let arguments)? = object["arguments"],
              Self.encodedSize(.object(arguments)) <= Self.maximumToolArgumentBytes else {
            throw CodexVoiceToolError("CAPABILITY_ARGUMENT_INVALID")
        }
        return DynamicToolCall(
            callID: callID,
            threadID: threadID,
            tool: tool,
            turnID: turnID,
            arguments: try Self.capabilityObject(arguments)
        )
    }

    private func requireOnlyKeys(_ value: CapabilityObject, allowed: Set<String>) throws {
        guard Set(value.keys).isSubset(of: allowed) else {
            throw CodexVoiceToolError("CAPABILITY_ARGUMENT_INVALID")
        }
    }

    private func requireOnlyKeys(_ value: [String: CodexJSONValue], allowed: Set<String>) throws {
        guard Set(value.keys).isSubset(of: allowed) else {
            throw CodexVoiceToolError("CAPABILITY_REQUEST_INVALID")
        }
    }

    private func requiredIdentifier(_ value: [String: CodexJSONValue], _ key: String) throws -> String {
        guard let text = value[key]?.stringValue, Self.validIdentifier(text) else {
            throw CodexVoiceToolError("CAPABILITY_REQUEST_INVALID")
        }
        return text
    }

    private func requiredString(
        _ value: CapabilityObject,
        _ key: String,
        maximum: Int
    ) throws -> String {
        guard case .string(let text)? = value[key],
              !text.isEmpty,
              text.unicodeScalars.count <= maximum else {
            throw CodexVoiceToolError("CAPABILITY_ARGUMENT_INVALID")
        }
        return text
    }

    private func optionalString(
        _ value: CapabilityObject,
        _ key: String,
        maximum: Int
    ) throws -> String? {
        switch value[key] {
        case nil, .some(.null):
            return nil
        case .some(.string(let text)) where text.unicodeScalars.count <= maximum:
            return text
        default:
            throw CodexVoiceToolError("CAPABILITY_ARGUMENT_INVALID")
        }
    }

    private func requiredInteger(
        _ value: CapabilityObject,
        _ key: String,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard case .integer(let number)? = value[key], range.contains(number) else {
            throw CodexVoiceToolError("CAPABILITY_ARGUMENT_INVALID")
        }
        return number
    }

    private func requiredBool(_ value: CapabilityObject, _ key: String) throws -> Bool {
        guard case .bool(let result)? = value[key] else {
            throw CodexVoiceToolError("CAPABILITY_ARGUMENT_INVALID")
        }
        return result
    }

    private func requiredDate(_ value: CapabilityObject, _ key: String) throws -> Date {
        let text = try requiredString(value, key, maximum: 64)
        guard let date = CapabilityDateCodec.date(from: text) else {
            throw CodexVoiceToolError("CAPABILITY_ARGUMENT_INVALID")
        }
        return date
    }

    private func isAuthorizationCurrent(_ expected: CodexVoiceToolAuthorization) -> Bool {
        let current = authorization()
        return current.isAllowed
            && current.epoch == expected.epoch
            && current.grantedPermissions == expected.grantedPermissions
    }

    private func calendarReadPermissions(
        principal: CapabilityPrincipal,
        authorization: CodexVoiceToolAuthorization
    ) throws -> CapabilityPermissionSet {
        guard authorization.grantedPermissions.contains("calendar.events.read") else {
            throw CodexVoiceToolError("CAPABILITY_PERMISSION_DENIED")
        }
        return Self.permissions(principal, ["calendar.events.read"])
    }

    private func cacheReply(_ key: String, fingerprint: String, reply: CodexAppServerReply) {
        completedCalls[key] = CachedToolReply(callFingerprint: fingerprint, reply: reply)
        completedCallOrder.append(key)
        while completedCallOrder.count > Self.maximumCachedCalls {
            completedCalls.removeValue(forKey: completedCallOrder.removeFirst())
        }
    }

    private static func principal(_ threadID: String) -> CapabilityPrincipal {
        CapabilityPrincipal(userID: "local-user", agentSessionID: threadID)
    }

    private static func permissions(
        _ principal: CapabilityPrincipal,
        _ values: Set<String>
    ) -> CapabilityPermissionSet {
        CapabilityPermissionSet(principal: principal, permissions: values)
    }

    private static func callToken(_ call: DynamicToolCall) -> String {
        let data = Data("\(call.threadID)\n\(call.turnID)\n\(call.callID)".utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validIdentifier(_ value: String) -> Bool {
        guard (1...128).contains(value.unicodeScalars.count),
              let first = value.unicodeScalars.first,
              Self.isASCIIAlphaNumeric(first) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            Self.isASCIIAlphaNumeric(scalar) || [45, 46, 58, 95].contains(scalar.value)
        }
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
            || (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
    }

    private static func encodedSize(_ value: CodexJSONValue) -> Int {
        (try? JSONEncoder().encode(value).count) ?? Int.max
    }

    private static func capabilityObject(
        _ object: [String: CodexJSONValue]
    ) throws -> CapabilityObject {
        try object.mapValues(capabilityValue)
    }

    private static func capabilityValue(_ value: CodexJSONValue) throws -> CapabilityValue {
        switch value {
        case .null:
            return .null
        case .bool(let value):
            return .bool(value)
        case .integer(let value):
            guard let converted = Int(exactly: value) else {
                throw CodexVoiceToolError("CAPABILITY_ARGUMENT_INVALID")
            }
            return .integer(converted)
        case .number(let value):
            guard value.isFinite else { throw CodexVoiceToolError("CAPABILITY_ARGUMENT_INVALID") }
            return .number(value)
        case .string(let value):
            return .string(value)
        case .array(let values):
            return .array(try values.map(capabilityValue))
        case .object(let object):
            return .object(try capabilityObject(object))
        }
    }

    private static func codexValue(_ object: CapabilityObject) -> CodexJSONValue {
        .object(object.mapValues(codexValue))
    }

    private static func codexValue(_ value: CapabilityValue) -> CodexJSONValue {
        switch value {
        case .null: .null
        case .bool(let value): .bool(value)
        case .integer(let value): .integer(Int64(value))
        case .number(let value): .number(value)
        case .string(let value): .string(value)
        case .array(let values): .array(values.map(codexValue))
        case .object(let object): codexValue(object)
        }
    }

    private static func errorCode(_ error: CapabilityBrokerError) -> String {
        switch error {
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

    private static let toolSpecs: [CodexJSONValue] = [
        functionTool(
            name: calendarTodayTool,
            description: "Read today's Calendar events through HoverPocket. Use eventRef for Today Focus.",
            required: [],
            properties: [:]
        ),
        functionTool(
            name: timerStartTool,
            description: "Start a HoverPocket countdown after approval.",
            required: ["durationSeconds"],
            properties: [
                "durationSeconds": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(86_400)]),
                "title": .object(["type": .string("string"), "maxLength": .integer(80)])
            ]
        ),
        functionTool(
            name: calendarCreateTool,
            description: "Create a Calendar event after approval.",
            required: ["title", "start", "end", "isAllDay"],
            properties: [
                "title": .object(["type": .string("string"), "minLength": .integer(1), "maxLength": .integer(80)]),
                "start": .object(["type": .string("string"), "format": .string("date-time"), "maxLength": .integer(64)]),
                "end": .object(["type": .string("string"), "format": .string("date-time"), "maxLength": .integer(64)]),
                "isAllDay": .object(["type": .string("boolean")])
            ]
        ),
        functionTool(
            name: todayFocusTool,
            description: "Start a Timer and save today's purpose for a Calendar event after one approval.",
            required: ["eventRef"],
            properties: [
                "eventRef": .object(["type": .string("string"), "minLength": .integer(1), "maxLength": .integer(256)]),
                "durationSeconds": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(86_400)]),
                "purpose": .object(["type": .string("string"), "maxLength": .integer(10_000)])
            ]
        )
    ]

    private static func functionTool(
        name: String,
        description: String,
        required: [String],
        properties: [String: CodexJSONValue]
    ) -> CodexJSONValue {
        .object([
            "type": .string("function"),
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map(CodexJSONValue.string)),
                "additionalProperties": .bool(false)
            ]),
            "deferLoading": .bool(false)
        ])
    }

    private struct DynamicToolCall {
        let callID: String
        let threadID: String
        let tool: String
        let turnID: String
        let arguments: CapabilityObject
    }

    private struct CachedToolReply {
        let callFingerprint: String
        let reply: CodexAppServerReply
    }
}

private actor CodexVoiceToolCallGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

private struct CodexVoiceToolError: Error {
    let code: String

    init(_ code: String) {
        self.code = code
    }
}
