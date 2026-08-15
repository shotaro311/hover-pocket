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
    private var cachedState: [String: String]

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

    func snapshot() -> [String: String] {
        cachedState
    }

    func setString(_ value: String?, for key: String) throws {
        guard allowedKeys.contains(key) else {
            throw PocketAppUserStateStoreError.invalidKey
        }
        if let value, value.unicodeScalars.count > Self.maximumValueScalars {
            throw PocketAppUserStateStoreError.invalidValue
        }
        let previous = cachedState
        if let value {
            cachedState[key] = value
        } else {
            cachedState.removeValue(forKey: key)
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: cachedState, options: [.sortedKeys])
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

    private static func load(fileURL: URL, allowedKeys: Set<String>) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fileURL)
            guard data.count <= maximumDocumentBytes,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: allowedKeys)
            else {
                throw PocketAppUserStateStoreError.invalidDocument
            }
            var state: [String: String] = [:]
            for (key, rawValue) in object {
                guard let value = rawValue as? String,
                      value.unicodeScalars.count <= maximumValueScalars else {
                    throw PocketAppUserStateStoreError.invalidDocument
                }
                state[key] = value
            }
            return state
        } catch let error as PocketAppUserStateStoreError {
            throw error
        } catch {
            throw PocketAppUserStateStoreError.invalidDocument
        }
    }
}
