import Foundation

enum PocketCapabilityKeys {
    static let calculatorEvaluate = PocketCapabilityKey(id: "calculator.expression.evaluate", version: 1)
    static let calendarList = PocketCapabilityKey(id: "calendar.events.list", version: 1)
    static let calendarGet = PocketCapabilityKey(id: "calendar.event.get", version: 1)
    static let calendarCreate = PocketCapabilityKey(id: "calendar.event.create", version: 1)
    static let controlsAvailability = PocketCapabilityKey(id: "controls.availability.get", version: 1)
    static let controlsBrightnessSet = PocketCapabilityKey(id: "controls.brightness.set", version: 1)
    static let controlsMediaCommand = PocketCapabilityKey(id: "controls.media.command", version: 1)
    static let controlsMuteSet = PocketCapabilityKey(id: "controls.mute.set", version: 1)
    static let controlsVolumeGet = PocketCapabilityKey(id: "controls.volume.get", version: 1)
    static let controlsVolumeSet = PocketCapabilityKey(id: "controls.volume.set", version: 1)
    static let timerStart = PocketCapabilityKey(id: "timer.countdown.start", version: 1)
    static let timerGet = PocketCapabilityKey(id: "timer.countdown.get", version: 1)
    static let timerPause = PocketCapabilityKey(id: "timer.countdown.pause", version: 1)
    static let timerResume = PocketCapabilityKey(id: "timer.countdown.resume", version: 1)
    static let timerStop = PocketCapabilityKey(id: "timer.countdown.stop", version: 1)
    static let stickyUpsert = PocketCapabilityKey(id: "sticky.note.upsert", version: 1)
    static let stickyGet = PocketCapabilityKey(id: "sticky.note.get", version: 1)
    static let stickyStatus = PocketCapabilityKey(id: "sticky.note.status", version: 1)
    static let stickyArchive = PocketCapabilityKey(id: "sticky.note.archive", version: 1)
    static let stickyDelete = PocketCapabilityKey(id: "sticky.note.delete", version: 1)
    static let nativeAuthority = PocketCapabilityKey(id: "system.native.authority", version: 1)
}

struct PocketCapabilityDescriptor: Sendable {
    let key: PocketCapabilityKey
    let titleKey: String
    let effect: CapabilityEffect
    let permissions: Set<String>
    let approvalPolicy: CapabilityApprovalPolicy
    let idempotency: CapabilityIdempotencyPolicy
    let limits: CapabilityLimits
    let readback: CapabilityReadbackPolicy
    let rollbackAvailable: Bool
    private let inputValidator: @Sendable (CapabilityObject) throws -> Void
    private let outputValidator: @Sendable (CapabilityObject) throws -> Void

    init(
        key: PocketCapabilityKey,
        titleKey: String,
        effect: CapabilityEffect,
        permissions: Set<String>,
        approvalPolicy: CapabilityApprovalPolicy,
        idempotency: CapabilityIdempotencyPolicy,
        limits: CapabilityLimits,
        readback: CapabilityReadbackPolicy,
        rollbackAvailable: Bool,
        inputValidator: @escaping @Sendable (CapabilityObject) throws -> Void,
        outputValidator: @escaping @Sendable (CapabilityObject) throws -> Void
    ) {
        self.key = key
        self.titleKey = titleKey
        self.effect = effect
        self.permissions = permissions
        self.approvalPolicy = approvalPolicy
        self.idempotency = idempotency
        self.limits = limits
        self.readback = readback
        self.rollbackAvailable = rollbackAvailable
        self.inputValidator = inputValidator
        self.outputValidator = outputValidator
    }

    func validateInput(_ arguments: CapabilityObject) throws {
        do {
            try inputValidator(arguments)
            let size = try CapabilityCanonicalJSON.data(.object(arguments)).count
            guard size <= limits.maximumPayloadBytes else {
                throw CapabilityBrokerError.invalidArguments(key, "payload")
            }
        } catch let error as CapabilityBrokerError {
            throw error
        } catch {
            throw CapabilityBrokerError.invalidArguments(key, "arguments")
        }
    }

    func validateOutput(_ output: CapabilityObject) throws {
        do {
            try outputValidator(output)
        } catch let error as CapabilityBrokerError {
            throw error
        } catch {
            throw CapabilityBrokerError.unavailable(key)
        }
    }
}

@MainActor
final class CapabilityRegistry {
    private let descriptors: [PocketCapabilityKey: PocketCapabilityDescriptor]
    private let handlers: PocketCapabilityHandlerSet
    private let compatibilityCatalog: PocketCapabilityCompatibilityCatalog

    init(
        descriptors: [PocketCapabilityDescriptor] = PocketCapabilityDescriptors.builtIn,
        handlers: PocketCapabilityHandlerSet,
        compatibilityCatalog: PocketCapabilityCompatibilityCatalog = .builtIn
    ) throws {
        var mapped: [PocketCapabilityKey: PocketCapabilityDescriptor] = [:]
        for descriptor in descriptors {
            guard mapped[descriptor.key] == nil else {
                throw CapabilityBrokerError.invalidPlan("duplicate_descriptor")
            }
            mapped[descriptor.key] = descriptor
        }
        self.descriptors = mapped
        self.handlers = handlers
        self.compatibilityCatalog = compatibilityCatalog
    }

    var descriptorKeys: [PocketCapabilityKey] {
        descriptors.keys.sorted()
    }

    var availableHandlerKeys: [PocketCapabilityKey] {
        handlers.keys
    }

    func resolve(_ key: PocketCapabilityKey) throws -> PocketCapabilityDescriptor {
        guard let descriptor = descriptors[key] else {
            throw CapabilityBrokerError.unknownCapability(key)
        }
        try compatibilityCatalog.requireRuntimeExecutable(key)
        guard descriptor.approvalPolicy != .runtimeProhibited else {
            throw CapabilityBrokerError.runtimeProhibited(key)
        }
        guard handlers.keys.contains(key) else {
            throw CapabilityBrokerError.unavailable(key)
        }
        return descriptor
    }

    func descriptor(_ key: PocketCapabilityKey) -> PocketCapabilityDescriptor? {
        descriptors[key]
    }

    func compatibilityIssue(_ key: PocketCapabilityKey) -> PocketCapabilityCompatibilityIssue? {
        compatibilityCatalog.issue(for: key)
    }

    func invoke(
        _ key: PocketCapabilityKey,
        arguments: CapabilityObject,
        context: CapabilityHandlerContext
    ) async throws -> CapabilityObject {
        _ = try resolve(key)
        return try await handlers.invoke(key, arguments: arguments, context: context)
    }
}

enum PocketCapabilityDescriptors {
    private static let readLimits = CapabilityLimits(
        timeoutMilliseconds: 3_000,
        maximumPayloadBytes: 4_096,
        maximumCallsPerMinute: 120
    )
    private static let calendarReadLimits = CapabilityLimits(
        timeoutMilliseconds: 15_000,
        maximumPayloadBytes: 4_096,
        maximumCallsPerMinute: 30
    )
    private static let localWriteLimits = CapabilityLimits(
        timeoutMilliseconds: 3_000,
        maximumPayloadBytes: 4_096,
        maximumCallsPerMinute: 120
    )

    static let builtIn: [PocketCapabilityDescriptor] = [
        descriptor(
            PocketCapabilityKeys.calculatorEvaluate,
            effect: .pure,
            permissions: [],
            approval: .none,
            idempotency: .notApplicable,
            limits: CapabilityLimits(timeoutMilliseconds: 1_000, maximumPayloadBytes: 1_024, maximumCallsPerMinute: 600),
            readback: CapabilityReadbackPolicy(strategy: .none, query: nil, matchFields: ["normalizedExpression", "result"]),
            rollback: false,
            input: CapabilitySchemaValidation.calculatorInput,
            output: CapabilitySchemaValidation.calculatorOutput
        ),
        descriptor(
            PocketCapabilityKeys.calendarCreate,
            effect: .externalWrite,
            permissions: ["calendar.events.write"],
            approval: .perCall,
            idempotency: .required,
            limits: CapabilityLimits(timeoutMilliseconds: 10_000, maximumPayloadBytes: 16_384, maximumCallsPerMinute: 30),
            readback: CapabilityReadbackPolicy(strategy: .capabilityQuery, query: PocketCapabilityKeys.calendarGet, matchFields: ["eventRef", "eventId", "start", "end", "safeTitle"]),
            rollback: false,
            input: CapabilitySchemaValidation.calendarCreateInput,
            output: CapabilitySchemaValidation.calendarEventOutput
        ),
        descriptor(
            PocketCapabilityKeys.calendarGet,
            effect: .privateRead,
            permissions: ["calendar.events.read"],
            approval: .permissionGrant,
            idempotency: .optional,
            limits: calendarReadLimits,
            readback: CapabilityReadbackPolicy(strategy: .sameStoreSnapshot, query: nil, matchFields: ["eventRef", "eventId", "start", "end", "safeTitle"]),
            rollback: false,
            input: CapabilitySchemaValidation.calendarGetInput,
            output: CapabilitySchemaValidation.calendarEventOutput
        ),
        descriptor(
            PocketCapabilityKeys.calendarList,
            effect: .privateRead,
            permissions: ["calendar.events.read"],
            approval: .permissionGrant,
            idempotency: .optional,
            limits: calendarReadLimits,
            readback: CapabilityReadbackPolicy(strategy: .sameStoreSnapshot, query: nil, matchFields: ["events"]),
            rollback: false,
            input: CapabilitySchemaValidation.calendarListInput,
            output: CapabilitySchemaValidation.calendarListOutput
        ),
        controlsDescriptor(
            PocketCapabilityKeys.controlsAvailability,
            effect: .privateRead,
            approval: .permissionGrant,
            idempotency: .optional,
            input: CapabilitySchemaValidation.emptyInput,
            output: CapabilitySchemaValidation.controlsAvailabilityOutput,
            matchFields: ["volumeAvailable", "brightnessAvailable", "mediaAvailable", "displayIds"]
        ),
        controlsDescriptor(
            PocketCapabilityKeys.controlsBrightnessSet,
            effect: .reversibleLocalWrite,
            approval: .brokerPolicy,
            idempotency: .required,
            input: CapabilitySchemaValidation.controlsBrightnessInput,
            output: CapabilitySchemaValidation.controlsBrightnessOutput,
            matchFields: ["displayId", "level", "controllable"]
        ),
        controlsDescriptor(
            PocketCapabilityKeys.controlsMediaCommand,
            effect: .reversibleLocalWrite,
            approval: .brokerPolicy,
            idempotency: .required,
            input: CapabilitySchemaValidation.controlsMediaInput,
            output: CapabilitySchemaValidation.controlsMediaOutput,
            matchFields: ["command", "available", "isPlaying", "safeTitle", "safeSource"]
        ),
        controlsDescriptor(
            PocketCapabilityKeys.controlsMuteSet,
            effect: .reversibleLocalWrite,
            approval: .brokerPolicy,
            idempotency: .required,
            input: CapabilitySchemaValidation.controlsMuteInput,
            output: CapabilitySchemaValidation.controlsVolumeOutput,
            matchFields: ["level", "muted"]
        ),
        controlsDescriptor(
            PocketCapabilityKeys.controlsVolumeGet,
            effect: .privateRead,
            approval: .permissionGrant,
            idempotency: .optional,
            input: CapabilitySchemaValidation.emptyInput,
            output: CapabilitySchemaValidation.controlsVolumeOutput,
            matchFields: ["level", "muted"]
        ),
        controlsDescriptor(
            PocketCapabilityKeys.controlsVolumeSet,
            effect: .reversibleLocalWrite,
            approval: .brokerPolicy,
            idempotency: .required,
            input: CapabilitySchemaValidation.controlsVolumeInput,
            output: CapabilitySchemaValidation.controlsVolumeOutput,
            matchFields: ["level", "muted"]
        ),
        descriptor(
            PocketCapabilityKeys.stickyArchive,
            effect: .reversibleLocalWrite,
            permissions: ["sticky.write"],
            approval: .brokerPolicy,
            idempotency: .required,
            limits: localWriteLimits,
            readback: CapabilityReadbackPolicy(strategy: .capabilityQuery, query: PocketCapabilityKeys.stickyStatus, matchFields: ["noteId", "state", "updatedAt"]),
            rollback: false,
            input: CapabilitySchemaValidation.stickyIDInput,
            output: CapabilitySchemaValidation.stickyArchivedOutput
        ),
        descriptor(
            PocketCapabilityKeys.stickyDelete,
            effect: .destructiveSensitive,
            permissions: ["sticky.delete"],
            approval: .strongPerCall,
            idempotency: .required,
            limits: localWriteLimits,
            readback: CapabilityReadbackPolicy(strategy: .capabilityQuery, query: PocketCapabilityKeys.stickyStatus, matchFields: ["noteId", "state", "updatedAt"]),
            rollback: false,
            input: CapabilitySchemaValidation.stickyIDInput,
            output: CapabilitySchemaValidation.stickyDeletedOutput
        ),
        descriptor(
            PocketCapabilityKeys.stickyGet,
            effect: .privateRead,
            permissions: ["sticky.read"],
            approval: .permissionGrant,
            idempotency: .optional,
            limits: readLimits,
            readback: CapabilityReadbackPolicy(strategy: .sameStoreSnapshot, query: nil, matchFields: ["noteId", "updatedAt"]),
            rollback: false,
            input: { try CapabilitySchemaValidation.identifierInput($0, key: "noteId", maximum: 128, uuid: false) },
            output: CapabilitySchemaValidation.stickyOutput
        ),
        descriptor(
            PocketCapabilityKeys.stickyStatus,
            effect: .privateRead,
            permissions: ["sticky.read"],
            approval: .permissionGrant,
            idempotency: .optional,
            limits: readLimits,
            readback: CapabilityReadbackPolicy(strategy: .sameStoreSnapshot, query: nil, matchFields: ["noteId", "state", "updatedAt"]),
            rollback: false,
            input: CapabilitySchemaValidation.stickyIDInput,
            output: CapabilitySchemaValidation.stickyStatusOutput
        ),
        descriptor(
            PocketCapabilityKeys.stickyUpsert,
            effect: .reversibleLocalWrite,
            permissions: ["sticky.write"],
            approval: .brokerPolicy,
            idempotency: .required,
            limits: localWriteLimits,
            readback: CapabilityReadbackPolicy(strategy: .capabilityQuery, query: PocketCapabilityKeys.stickyGet, matchFields: ["noteId", "title", "body", "updatedAt"]),
            rollback: false,
            input: CapabilitySchemaValidation.stickyUpsertInput,
            output: CapabilitySchemaValidation.stickyOutput
        ),
        descriptor(
            PocketCapabilityKeys.nativeAuthority,
            effect: .nativeAuthority,
            permissions: ["system.native"],
            approval: .runtimeProhibited,
            idempotency: .required,
            limits: CapabilityLimits(timeoutMilliseconds: 3_000, maximumPayloadBytes: 4_096, maximumCallsPerMinute: 1),
            readback: CapabilityReadbackPolicy(strategy: .osState, query: nil, matchFields: ["status"]),
            rollback: false,
            input: { try CapabilitySchemaValidation.exactKeys($0, []) },
            output: { output in
                try CapabilitySchemaValidation.exactKeys(output, ["status"])
                guard try CapabilitySchemaValidation.string(output, "status", maximum: 32) == "unavailable" else {
                    throw CapabilityBrokerError.invalidArguments(PocketCapabilityKeys.nativeAuthority, "status")
                }
            }
        ),
        timerDescriptor(PocketCapabilityKeys.timerGet, effect: .privateRead, approval: .permissionGrant, idempotency: .optional, input: CapabilitySchemaValidation.timerIDInput, rollback: false),
        timerDescriptor(PocketCapabilityKeys.timerPause, effect: .reversibleLocalWrite, approval: .brokerPolicy, idempotency: .required, input: CapabilitySchemaValidation.timerIDInput, rollback: false),
        timerDescriptor(PocketCapabilityKeys.timerResume, effect: .reversibleLocalWrite, approval: .brokerPolicy, idempotency: .required, input: CapabilitySchemaValidation.timerIDInput, rollback: false),
        timerDescriptor(PocketCapabilityKeys.timerStart, effect: .reversibleLocalWrite, approval: .brokerPolicy, idempotency: .required, input: CapabilitySchemaValidation.timerStartInput, rollback: true),
        timerDescriptor(PocketCapabilityKeys.timerStop, effect: .reversibleLocalWrite, approval: .brokerPolicy, idempotency: .required, input: CapabilitySchemaValidation.timerIDInput, rollback: false)
    ].sorted { $0.key < $1.key }

    private static func descriptor(
        _ key: PocketCapabilityKey,
        effect: CapabilityEffect,
        permissions: Set<String>,
        approval: CapabilityApprovalPolicy,
        idempotency: CapabilityIdempotencyPolicy,
        limits: CapabilityLimits,
        readback: CapabilityReadbackPolicy,
        rollback: Bool,
        input: @escaping @Sendable (CapabilityObject) throws -> Void,
        output: @escaping @Sendable (CapabilityObject) throws -> Void
    ) -> PocketCapabilityDescriptor {
        PocketCapabilityDescriptor(
            key: key,
            titleKey: "capability.\(key.id)",
            effect: effect,
            permissions: permissions,
            approvalPolicy: approval,
            idempotency: idempotency,
            limits: limits,
            readback: readback,
            rollbackAvailable: rollback,
            inputValidator: input,
            outputValidator: output
        )
    }

    private static func timerDescriptor(
        _ key: PocketCapabilityKey,
        effect: CapabilityEffect,
        approval: CapabilityApprovalPolicy,
        idempotency: CapabilityIdempotencyPolicy,
        input: @escaping @Sendable (CapabilityObject) throws -> Void,
        rollback: Bool
    ) -> PocketCapabilityDescriptor {
        descriptor(
            key,
            effect: effect,
            permissions: [effect == .privateRead ? "timer.read" : "timer.write"],
            approval: approval,
            idempotency: idempotency,
            limits: effect == .privateRead ? readLimits : localWriteLimits,
            readback: CapabilityReadbackPolicy(
                strategy: effect == .privateRead ? .sameStoreSnapshot : .capabilityQuery,
                query: effect == .privateRead ? nil : PocketCapabilityKeys.timerGet,
                matchFields: ["timerId", "state", "endAt"]
            ),
            rollback: rollback,
            input: input,
            output: CapabilitySchemaValidation.timerOutput
        )
    }

    private static func controlsDescriptor(
        _ key: PocketCapabilityKey,
        effect: CapabilityEffect,
        approval: CapabilityApprovalPolicy,
        idempotency: CapabilityIdempotencyPolicy,
        input: @escaping @Sendable (CapabilityObject) throws -> Void,
        output: @escaping @Sendable (CapabilityObject) throws -> Void,
        matchFields: [String]
    ) -> PocketCapabilityDescriptor {
        descriptor(
            key,
            effect: effect,
            permissions: [effect == .privateRead ? "controls.read" : "controls.write"],
            approval: approval,
            idempotency: idempotency,
            limits: effect == .privateRead ? readLimits : localWriteLimits,
            readback: CapabilityReadbackPolicy(
                strategy: effect == .privateRead ? .sameStoreSnapshot : .osState,
                query: nil,
                matchFields: matchFields
            ),
            rollback: false,
            input: input,
            output: output
        )
    }
}

enum CapabilitySchemaValidation {
    static func exactKeys(_ object: CapabilityObject, _ expected: Set<String>) throws {
        guard Set(object.keys) == expected else {
            throw CapabilityBrokerError.invalidPlan("schema_keys")
        }
    }

    static func string(
        _ object: CapabilityObject,
        _ key: String,
        minimum: Int = 0,
        maximum: Int,
        allowed: Set<String>? = nil
    ) throws -> String {
        guard case .string(let value)? = object[key],
              (minimum...maximum).contains(value.unicodeScalars.count),
              allowed?.contains(value) ?? true else {
            throw CapabilityBrokerError.invalidPlan("schema_\(key)")
        }
        return value
    }

    static func nullableString(_ object: CapabilityObject, _ key: String, maximum: Int) throws {
        switch object[key] {
        case .some(.null):
            return
        case .some(.string(let value)) where value.unicodeScalars.count <= maximum:
            return
        default:
            throw CapabilityBrokerError.invalidPlan("schema_\(key)")
        }
    }

    static func integer(_ object: CapabilityObject, _ key: String, range: ClosedRange<Int>) throws -> Int {
        guard case .integer(let value)? = object[key], range.contains(value) else {
            throw CapabilityBrokerError.invalidPlan("schema_\(key)")
        }
        return value
    }

    static func number(_ object: CapabilityObject, _ key: String, range: ClosedRange<Double>) throws -> Double {
        let value: Double
        switch object[key] {
        case .some(.number(let number)):
            value = number
        case .some(.integer(let integer)):
            value = Double(integer)
        default:
            throw CapabilityBrokerError.invalidPlan("schema_\(key)")
        }
        guard value.isFinite, range.contains(value) else {
            throw CapabilityBrokerError.invalidPlan("schema_\(key)")
        }
        return value
    }

    static func boolean(_ object: CapabilityObject, _ key: String) throws -> Bool {
        guard case .bool(let value)? = object[key] else {
            throw CapabilityBrokerError.invalidPlan("schema_\(key)")
        }
        return value
    }

    static func identifierInput(_ object: CapabilityObject, key: String, maximum: Int, uuid: Bool) throws {
        try exactKeys(object, [key])
        let value = try string(object, key, minimum: 1, maximum: maximum)
        if uuid, UUID(uuidString: value) == nil {
            throw CapabilityBrokerError.invalidPlan("schema_\(key)")
        }
    }

    static func calendarListInput(_ object: CapabilityObject) throws {
        try exactKeys(object, ["range", "timezone"])
        _ = try string(object, "range", minimum: 1, maximum: 16, allowed: ["today"])
        let timezone = try string(object, "timezone", minimum: 1, maximum: 64)
        guard TimeZone(identifier: timezone) != nil else {
            throw CapabilityBrokerError.invalidPlan("schema_timezone")
        }
    }

    static func emptyInput(_ object: CapabilityObject) throws {
        try exactKeys(object, [])
    }

    static func controlsVolumeInput(_ object: CapabilityObject) throws {
        try exactKeys(object, ["level"])
        _ = try number(object, "level", range: 0...1)
    }

    static func controlsMuteInput(_ object: CapabilityObject) throws {
        try exactKeys(object, ["muted"])
        _ = try boolean(object, "muted")
    }

    static func controlsBrightnessInput(_ object: CapabilityObject) throws {
        try exactKeys(object, ["displayId", "level"])
        _ = try string(object, "displayId", minimum: 1, maximum: 128)
        _ = try number(object, "level", range: 0.05...1)
    }

    static func controlsMediaInput(_ object: CapabilityObject) throws {
        try exactKeys(object, ["command"])
        _ = try string(object, "command", minimum: 1, maximum: 16, allowed: ["play_pause", "next", "previous"])
    }

    static func controlsVolumeOutput(_ object: CapabilityObject) throws {
        try exactKeys(object, ["level", "muted"])
        _ = try number(object, "level", range: 0...1)
        _ = try boolean(object, "muted")
    }

    static func controlsBrightnessOutput(_ object: CapabilityObject) throws {
        try exactKeys(object, ["displayId", "level", "controllable"])
        _ = try string(object, "displayId", minimum: 1, maximum: 128)
        _ = try number(object, "level", range: 0...1)
        guard try boolean(object, "controllable") else {
            throw CapabilityBrokerError.invalidPlan("schema_controllable")
        }
    }

    static func controlsAvailabilityOutput(_ object: CapabilityObject) throws {
        try exactKeys(object, ["volumeAvailable", "brightnessAvailable", "mediaAvailable", "displayIds"])
        _ = try boolean(object, "volumeAvailable")
        _ = try boolean(object, "brightnessAvailable")
        _ = try boolean(object, "mediaAvailable")
        guard case .array(let ids)? = object["displayIds"], ids.count <= 16 else {
            throw CapabilityBrokerError.invalidPlan("schema_displayIds")
        }
        for id in ids {
            guard case .string(let value) = id,
                  !value.isEmpty,
                  value.unicodeScalars.count <= 128 else {
                throw CapabilityBrokerError.invalidPlan("schema_displayIds")
            }
        }
    }

    static func controlsMediaOutput(_ object: CapabilityObject) throws {
        try exactKeys(object, ["command", "available", "isPlaying", "safeTitle", "safeSource"])
        _ = try string(object, "command", minimum: 1, maximum: 16, allowed: ["play_pause", "next", "previous"])
        guard try boolean(object, "available") else {
            throw CapabilityBrokerError.invalidPlan("schema_available")
        }
        _ = try boolean(object, "isPlaying")
        _ = try string(object, "safeTitle", maximum: 160)
        _ = try string(object, "safeSource", maximum: 120)
    }

    static func calculatorInput(_ object: CapabilityObject) throws {
        try exactKeys(object, ["expression"])
        _ = try string(object, "expression", minimum: 1, maximum: 256)
    }

    static func calculatorOutput(_ object: CapabilityObject) throws {
        try exactKeys(object, ["normalizedExpression", "result"])
        _ = try string(object, "normalizedExpression", minimum: 1, maximum: 512)
        let result = try string(object, "result", minimum: 1, maximum: 32)
        guard result.range(
            of: "^-?(?:0|[1-9][0-9]{0,17})(?:\\.[0-9]{1,12})?$",
            options: .regularExpression
        ) != nil else {
            throw CapabilityBrokerError.invalidPlan("schema_result")
        }
    }

    static func calendarGetInput(_ object: CapabilityObject) throws {
        try identifierInput(object, key: "eventRef", maximum: 256, uuid: false)
    }

    static func calendarCreateInput(_ object: CapabilityObject) throws {
        try exactKeys(object, ["calendarId", "title", "start", "end", "isAllDay", "location", "notes"])
        try nullableString(object, "calendarId", maximum: 256)
        _ = try string(object, "title", minimum: 1, maximum: 160)
        let start = try string(object, "start", minimum: 1, maximum: 64)
        let end = try string(object, "end", minimum: 1, maximum: 64)
        _ = try boolean(object, "isAllDay")
        try nullableString(object, "location", maximum: 500)
        try nullableString(object, "notes", maximum: 10_000)
        guard let startDate = CapabilityDateCodec.date(from: start),
              let endDate = CapabilityDateCodec.date(from: end),
              endDate > startDate else {
            throw CapabilityBrokerError.invalidPlan("schema_start_end")
        }
    }

    static func calendarEventOutput(_ object: CapabilityObject) throws {
        try exactKeys(object, ["eventRef", "eventId", "start", "end", "safeTitle"])
        _ = try string(object, "eventRef", minimum: 1, maximum: 256)
        _ = try string(object, "eventId", minimum: 1, maximum: 256)
        try dateFields(object)
        _ = try string(object, "safeTitle", maximum: 160)
    }

    static func calendarListOutput(_ object: CapabilityObject) throws {
        try exactKeys(object, ["events"])
        guard case .array(let events)? = object["events"], events.count <= 128 else {
            throw CapabilityBrokerError.invalidPlan("schema_events")
        }
        for event in events {
            guard case .object(let value) = event else {
                throw CapabilityBrokerError.invalidPlan("schema_events")
            }
            try exactKeys(value, ["eventRef", "start", "end", "safeTitle"])
            _ = try string(value, "eventRef", minimum: 1, maximum: 256)
            try dateFields(value)
            _ = try string(value, "safeTitle", maximum: 160)
        }
    }

    static func timerIDInput(_ object: CapabilityObject) throws {
        try identifierInput(object, key: "timerId", maximum: 36, uuid: true)
    }

    static func timerStartInput(_ object: CapabilityObject) throws {
        try exactKeys(object, ["durationSeconds", "title", "sourceRef"])
        _ = try integer(object, "durationSeconds", range: 1...86_400)
        _ = try string(object, "title", minimum: 1, maximum: 80)
        try nullableString(object, "sourceRef", maximum: 256)
    }

    static func timerOutput(_ object: CapabilityObject) throws {
        try exactKeys(object, ["timerId", "state", "endAt"])
        _ = try string(object, "timerId", minimum: 1, maximum: 36)
        _ = try string(object, "state", minimum: 1, maximum: 16, allowed: ["running", "paused", "stopped"])
        switch object["endAt"] {
        case .some(.null):
            return
        case .some(.string(let value)) where CapabilityDateCodec.date(from: value) != nil:
            return
        default:
            throw CapabilityBrokerError.invalidPlan("schema_endAt")
        }
    }

    static func stickyUpsertInput(_ object: CapabilityObject) throws {
        try exactKeys(object, ["stableKey", "title", "body", "color"])
        _ = try PocketStableKey.validate(string(object, "stableKey", minimum: 1, maximum: PocketStableKey.maximumScalars))
        _ = try string(object, "title", maximum: 120)
        _ = try string(object, "body", maximum: 10_000)
        _ = try string(object, "color", minimum: 1, maximum: 16, allowed: ["yellow", "blue", "green", "pink", "gray"])
    }

    static func stickyIDInput(_ object: CapabilityObject) throws {
        try identifierInput(object, key: "noteId", maximum: 128, uuid: true)
    }

    static func stickyStatusOutput(_ object: CapabilityObject) throws {
        try exactKeys(object, ["noteId", "state", "updatedAt"])
        _ = try string(object, "noteId", minimum: 1, maximum: 128)
        let state = try string(object, "state", minimum: 1, maximum: 16, allowed: ["active", "archived", "missing"])
        switch object["updatedAt"] {
        case .some(.null) where state == "missing":
            return
        case .some(.string(let value))
            where state != "missing" && CapabilityDateCodec.date(from: value) != nil:
            return
        default:
            throw CapabilityBrokerError.invalidPlan("schema_updatedAt")
        }
    }

    static func stickyArchivedOutput(_ object: CapabilityObject) throws {
        try stickyStatusOutput(object)
        guard object["state"] == .string("archived") else {
            throw CapabilityBrokerError.invalidPlan("schema_state")
        }
    }

    static func stickyDeletedOutput(_ object: CapabilityObject) throws {
        try stickyStatusOutput(object)
        guard object["state"] == .string("missing") else {
            throw CapabilityBrokerError.invalidPlan("schema_state")
        }
    }

    static func stickyOutput(_ object: CapabilityObject) throws {
        try exactKeys(object, ["noteId", "title", "body", "updatedAt"])
        _ = try string(object, "noteId", minimum: 1, maximum: 128)
        _ = try string(object, "title", maximum: 120)
        _ = try string(object, "body", maximum: 10_000)
        let updated = try string(object, "updatedAt", minimum: 1, maximum: 64)
        guard CapabilityDateCodec.date(from: updated) != nil else {
            throw CapabilityBrokerError.invalidPlan("schema_updatedAt")
        }
    }

    private static func dateFields(_ object: CapabilityObject) throws {
        let start = try string(object, "start", minimum: 1, maximum: 64)
        let end = try string(object, "end", minimum: 1, maximum: 64)
        guard CapabilityDateCodec.date(from: start) != nil,
              CapabilityDateCodec.date(from: end) != nil else {
            throw CapabilityBrokerError.invalidPlan("schema_start_end")
        }
    }
}
