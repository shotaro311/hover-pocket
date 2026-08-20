import CoreFoundation
import Darwin
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
    private let propertyTypes: [String: Set<String>]
    private let packageDirectory: PocketAppPinnedDirectory
    private var cachedState: [String: CapabilityValue]

    convenience init(packageID: String, allowedKeys: Set<String>, rootDirectory: URL) throws {
        let scalarTypes: Set<String> = ["string", "integer", "number", "boolean", "null"]
        try self.init(
            packageID: packageID,
            propertyTypes: Dictionary(uniqueKeysWithValues: allowedKeys.map { ($0, scalarTypes) }),
            rootDirectory: rootDirectory
        )
    }

    init(packageID: String, propertyTypes: [String: Set<String>], rootDirectory: URL) throws {
        guard packageID.range(
            of: "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$",
            options: .regularExpression
        ) != nil else {
            throw PocketAppUserStateStoreError.invalidPackageID
        }
        self.allowedKeys = Set(propertyTypes.keys)
        self.propertyTypes = propertyTypes
        do {
            self.packageDirectory = try PocketAppPinnedDirectory(
                url: rootDirectory.appendingPathComponent(packageID, isDirectory: true)
            )
        } catch {
            throw PocketAppUserStateStoreError.persistenceFailed
        }
        self.cachedState = [:]
        let loaded = try Self.load(directory: packageDirectory, propertyTypes: propertyTypes)
        self.cachedState = loaded.state
        if loaded.needsRepair {
            let object = try cachedState.mapValues(Self.jsonValue)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try Self.persist(data, directory: packageDirectory)
        }
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
            guard let acceptedTypes = propertyTypes[key], Self.accepts(value, types: acceptedTypes) else {
                throw PocketAppUserStateStoreError.invalidValue
            }
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
            try Self.persist(data, directory: packageDirectory)
        } catch let error as PocketAppUserStateStoreError {
            cachedState = previous
            throw error
        } catch {
            cachedState = previous
            throw PocketAppUserStateStoreError.persistenceFailed
        }
    }

    private static func load(
        directory: PocketAppPinnedDirectory,
        propertyTypes: [String: Set<String>]
    ) throws -> (state: [String: CapabilityValue], needsRepair: Bool) {
        do {
            let data = try directory.withValidatedDescriptor { descriptor in
                return try readStateFile(directoryDescriptor: descriptor)
            }
            guard let data else { return ([:], false) }
            guard data.count <= maximumDocumentBytes,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw PocketAppUserStateStoreError.invalidDocument
            }
            var state: [String: CapabilityValue] = [:]
            var needsRepair = false
            for (key, rawValue) in object {
                guard let acceptedTypes = propertyTypes[key] else {
                    needsRepair = true
                    continue
                }
                do {
                    let value = try capabilityValue(rawValue)
                    try validate(value)
                    guard accepts(value, types: acceptedTypes) else {
                        needsRepair = true
                        continue
                    }
                    state[key] = value
                } catch {
                    needsRepair = true
                }
            }
            return (state, needsRepair)
        } catch let error as PocketAppUserStateStoreError {
            throw error
        } catch {
            throw PocketAppUserStateStoreError.persistenceFailed
        }
    }

    private static func readStateFile(directoryDescriptor: Int32) throws -> Data? {
        let descriptor = "state.json".withCString { pointer in
            openat(directoryDescriptor, pointer, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw PocketAppUserStateStoreError.persistenceFailed
        }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= maximumDocumentBytes else {
            throw PocketAppUserStateStoreError.invalidDocument
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw PocketAppUserStateStoreError.persistenceFailed
            }
            guard data.count + count <= maximumDocumentBytes else {
                throw PocketAppUserStateStoreError.invalidDocument
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private static func persist(_ data: Data, directory: PocketAppPinnedDirectory) throws {
        do {
            try directory.withValidatedDescriptor { directoryDescriptor in
                let temporaryName = ".state-\(UUID().uuidString.lowercased()).tmp"
                let descriptor = temporaryName.withCString { pointer in
                    openat(
                        directoryDescriptor,
                        pointer,
                        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                        S_IRUSR | S_IWUSR
                    )
                }
                guard descriptor >= 0 else {
                    throw PocketAppUserStateStoreError.persistenceFailed
                }
                var descriptorOpen = true
                var temporaryExists = true
                defer {
                    if descriptorOpen { close(descriptor) }
                    if temporaryExists {
                        _ = temporaryName.withCString { pointer in
                            unlinkat(directoryDescriptor, pointer, 0)
                        }
                    }
                }

                try data.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else { return }
                    var offset = 0
                    while offset < bytes.count {
                        let written = Darwin.write(
                            descriptor,
                            baseAddress.advanced(by: offset),
                            bytes.count - offset
                        )
                        if written < 0 {
                            if errno == EINTR { continue }
                            throw PocketAppUserStateStoreError.persistenceFailed
                        }
                        offset += written
                    }
                }
                guard fsync(descriptor) == 0, close(descriptor) == 0 else {
                    descriptorOpen = false
                    throw PocketAppUserStateStoreError.persistenceFailed
                }
                descriptorOpen = false
                let renamed = temporaryName.withCString { source in
                    "state.json".withCString { destination in
                        renameat(directoryDescriptor, source, directoryDescriptor, destination)
                    }
                }
                guard renamed == 0 else {
                    throw PocketAppUserStateStoreError.persistenceFailed
                }
                temporaryExists = false
            }
        } catch let error as PocketAppUserStateStoreError {
            throw error
        } catch {
            throw PocketAppUserStateStoreError.persistenceFailed
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

    private static func accepts(_ value: CapabilityValue, types: Set<String>) -> Bool {
        switch value {
        case .null:
            types.contains("null")
        case .bool:
            types.contains("boolean")
        case .integer:
            types.contains("integer") || types.contains("number")
        case .number(let value):
            types.contains("number") || (types.contains("integer") && value.rounded() == value)
        case .string:
            types.contains("string")
        case .array, .object:
            false
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
