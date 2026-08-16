import CoreFoundation
import Foundation

enum PocketAppUserStateStoreError: Error, Equatable {
    case invalidPackageID
    case invalidKey
    case invalidValue
    case invalidDocument
    case persistenceFailed
}

@MainActor
final class PocketAppUserStateStore {
    static let maximumDocumentBytes = 256 * 1024
    static let maximumValueScalars = 4_096

    private let allowedKeys: Set<String>
    private let fileURL: URL
    private var cachedState: [String: CapabilityValue]

    init(packageID: String, allowedKeys: Set<String>, rootDirectory: URL) throws {
        guard packageID.range(
            of: "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$",
            options: .regularExpression
        ) != nil else {
            throw PocketAppUserStateStoreError.invalidPackageID
        }
        self.allowedKeys = allowedKeys
        let packageDirectory = rootDirectory.appendingPathComponent(packageID, isDirectory: true)
        self.fileURL = packageDirectory.appendingPathComponent("state.json", isDirectory: false)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        self.cachedState = [:]
        self.cachedState = try Self.load(fileURL: fileURL, allowedKeys: allowedKeys)
    }

    func snapshot() -> [String: CapabilityValue] {
        cachedState
    }

    func setString(_ value: String?, for key: String) throws {
        try setValue(value.map(CapabilityValue.string), for: key)
    }

    func setValue(_ value: CapabilityValue?, for key: String) throws {
        guard allowedKeys.contains(key) else {
            throw PocketAppUserStateStoreError.invalidKey
        }
        if let value {
            try Self.validate(value)
        }
        let previous = cachedState
        if let value {
            cachedState[key] = value
        } else {
            cachedState.removeValue(forKey: key)
        }
        do {
            let object = try cachedState.mapValues(Self.jsonValue)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard data.count <= Self.maximumDocumentBytes else {
                throw PocketAppUserStateStoreError.invalidDocument
            }
            try data.write(to: fileURL, options: .atomic)
        } catch let error as PocketAppUserStateStoreError {
            cachedState = previous
            throw error
        } catch {
            cachedState = previous
            throw PocketAppUserStateStoreError.persistenceFailed
        }
    }

    private static func load(fileURL: URL, allowedKeys: Set<String>) throws -> [String: CapabilityValue] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fileURL)
            guard data.count <= maximumDocumentBytes,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: allowedKeys)
            else {
                throw PocketAppUserStateStoreError.invalidDocument
            }
            var state: [String: CapabilityValue] = [:]
            for (key, rawValue) in object {
                let value = try capabilityValue(rawValue)
                try validate(value)
                state[key] = value
            }
            return state
        } catch let error as PocketAppUserStateStoreError {
            throw error
        } catch {
            throw PocketAppUserStateStoreError.invalidDocument
        }
    }

    private static func validate(_ value: CapabilityValue) throws {
        switch value {
        case .null, .bool, .integer:
            return
        case .number(let number):
            guard number.isFinite else {
                throw PocketAppUserStateStoreError.invalidValue
            }
        case .string(let string):
            guard string.unicodeScalars.count <= maximumValueScalars else {
                throw PocketAppUserStateStoreError.invalidValue
            }
        case .array, .object:
            throw PocketAppUserStateStoreError.invalidValue
        }
    }

    private static func jsonValue(_ value: CapabilityValue) throws -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .integer(let value):
            return value
        case .number(let value) where value.isFinite:
            return value
        case .string(let value):
            return value
        default:
            throw PocketAppUserStateStoreError.invalidValue
        }
    }

    private static func capabilityValue(_ value: Any) throws -> CapabilityValue {
        if value is NSNull {
            return .null
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let doubleValue = number.doubleValue
            guard doubleValue.isFinite else {
                throw PocketAppUserStateStoreError.invalidDocument
            }
            let type = String(cString: number.objCType)
            if !["f", "d"].contains(type),
               let integerValue = Int(exactly: number.int64Value) {
                return .integer(integerValue)
            }
            return .number(doubleValue)
        }
        if let value = value as? String {
            return .string(value)
        }
        throw PocketAppUserStateStoreError.invalidDocument
    }
}
