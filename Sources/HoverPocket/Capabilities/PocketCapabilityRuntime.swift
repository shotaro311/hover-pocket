import Foundation

struct PocketCapabilityKey: Hashable, Sendable, Comparable {
    let id: String
    let version: Int

    static func < (lhs: PocketCapabilityKey, rhs: PocketCapabilityKey) -> Bool {
        lhs.id == rhs.id ? lhs.version < rhs.version : lhs.id < rhs.id
    }
}

enum CapabilityValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([CapabilityValue])
    case object([String: CapabilityValue])
}

typealias CapabilityObject = [String: CapabilityValue]

struct CapabilityHandlerContext: Sendable {
    let idempotencyKey: String?
    let now: Date

    init(idempotencyKey: String? = nil, now: Date = Date()) {
        self.idempotencyKey = idempotencyKey
        self.now = now
    }

    func requiredIdempotencyKey() throws -> String {
        guard let idempotencyKey,
              (16...128).contains(idempotencyKey.count),
              let first = idempotencyKey.unicodeScalars.first,
              Self.isASCIIAlphaNumeric(first),
              idempotencyKey.unicodeScalars.allSatisfy(Self.isAllowedIdempotencyScalar)
        else {
            throw CapabilityHandlerError.invalidArgument("idempotencyKey")
        }
        return idempotencyKey
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
            || (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
    }

    private static func isAllowedIdempotencyScalar(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIAlphaNumeric(scalar) || [45, 46, 58, 95].contains(scalar.value)
    }
}

enum CapabilityHandlerError: Error, Equatable, Sendable {
    case duplicateHandler(PocketCapabilityKey)
    case unknownCapability(PocketCapabilityKey)
    case invalidArgument(String)
    case unavailable(String)
    case readbackMismatch(String)

    var code: String {
        switch self {
        case .duplicateHandler:
            return "CAPABILITY_HANDLER_DUPLICATE"
        case .unknownCapability:
            return "CAPABILITY_UNKNOWN"
        case .invalidArgument:
            return "CAPABILITY_ARGUMENT_INVALID"
        case .unavailable:
            return "CAPABILITY_UNAVAILABLE"
        case .readbackMismatch:
            return "CAPABILITY_READBACK_MISMATCH"
        }
    }
}

@MainActor
protocol PocketCapabilityHandler: AnyObject {
    var key: PocketCapabilityKey { get }
    func handle(arguments: CapabilityObject, context: CapabilityHandlerContext) async throws -> CapabilityObject
}

@MainActor
final class PocketCapabilityHandlerSet {
    private var handlers: [PocketCapabilityKey: any PocketCapabilityHandler] = [:]

    init(handlers: [any PocketCapabilityHandler] = []) throws {
        for handler in handlers {
            try register(handler)
        }
    }

    var keys: [PocketCapabilityKey] {
        handlers.keys.sorted()
    }

    func register(_ handler: any PocketCapabilityHandler) throws {
        guard handlers[handler.key] == nil else {
            throw CapabilityHandlerError.duplicateHandler(handler.key)
        }
        handlers[handler.key] = handler
    }

    func invoke(
        _ key: PocketCapabilityKey,
        arguments: CapabilityObject,
        context: CapabilityHandlerContext = CapabilityHandlerContext()
    ) async throws -> CapabilityObject {
        guard let handler = handlers[key] else {
            throw CapabilityHandlerError.unknownCapability(key)
        }
        return try await handler.handle(arguments: arguments, context: context)
    }
}

extension Dictionary where Key == String, Value == CapabilityValue {
    func requiredString(_ key: String, maxLength: Int, allowEmpty: Bool = false) throws -> String {
        guard case .string(let value)? = self[key],
              value.unicodeScalars.count <= maxLength,
              allowEmpty || !value.isEmpty
        else {
            throw CapabilityHandlerError.invalidArgument(key)
        }
        return value
    }

    func optionalString(_ key: String, maxLength: Int) throws -> String? {
        switch self[key] {
        case .none, .some(.null):
            return nil
        case .some(.string(let value)) where value.unicodeScalars.count <= maxLength:
            return value
        default:
            throw CapabilityHandlerError.invalidArgument(key)
        }
    }

    func requiredInteger(_ key: String, range: ClosedRange<Int>) throws -> Int {
        guard case .integer(let value)? = self[key], range.contains(value) else {
            throw CapabilityHandlerError.invalidArgument(key)
        }
        return value
    }

    func requiredNumber(_ key: String, range: ClosedRange<Double>) throws -> Double {
        let value: Double
        switch self[key] {
        case .some(.number(let number)):
            value = number
        case .some(.integer(let integer)):
            value = Double(integer)
        default:
            throw CapabilityHandlerError.invalidArgument(key)
        }
        guard value.isFinite, range.contains(value) else {
            throw CapabilityHandlerError.invalidArgument(key)
        }
        return value
    }

    func requiredBool(_ key: String) throws -> Bool {
        guard case .bool(let value)? = self[key] else {
            throw CapabilityHandlerError.invalidArgument(key)
        }
        return value
    }
}

enum CapabilityDateCodec {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) {
            return parsed
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

extension String {
    func prefixingUnicodeScalars(_ maximumCount: Int) -> String {
        String(unicodeScalars.prefix(maximumCount))
    }
}
