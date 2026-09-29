import Darwin
import Foundation

struct PocketCollectionRecord: Equatable, Sendable, Identifiable {
    let id: String
    var fields: [String: PocketJSONValue]
}

struct PocketCollectionSnapshot: Equatable, Sendable {
    let schemaVersion: Int
    var revision: Int
    var records: [PocketCollectionRecord]

    var json: [String: Any] {
        ["formatVersion": 1, "schemaVersion": schemaVersion, "revision": revision,
         "records": records.map { ["id": $0.id, "fields": $0.fields.mapValues(\.foundationValue)] }]
    }
}

/// Each operation reads the shared file while holding its lock, including operations from another window.
@MainActor
final class PocketCollectionStore {
    nonisolated static let maximumBytes = 8 * 1_024 * 1_024
    nonisolated static let maximumRecords = 10_000
    let schema: PocketCollectionSchema
    private let directory: PocketAppPinnedDirectory
    private let filename: String
    private let rootDirectory: URL
    private let packageID: String

    init(packageID: String, collectionID: String, schema: PocketCollectionSchema, rootDirectory: URL) throws {
        guard packageID.count <= 160,
              packageID.range(of: "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$", options: .regularExpression) != nil,
              PocketCollectionSchema.validIdentifier(collectionID) else { throw PocketCollectionError.invalidSchema }
        self.schema = schema
        self.rootDirectory = rootDirectory
        self.packageID = packageID
        self.directory = try PocketAppPinnedDirectory(url: rootDirectory
            .appendingPathComponent(packageID, isDirectory: true).appendingPathComponent("Collections", isDirectory: true))
        self.filename = collectionID + ".json"
        _ = try snapshot()
    }

    func snapshot() throws -> PocketCollectionSnapshot {
        try locked { try read(directoryDescriptor: $0) }
    }

    @discardableResult
    func insert(fields: [String: PocketJSONValue], expectedRevision: Int) throws -> PocketCollectionSnapshot {
        try schema.validate(fields)
        return try mutate(expectedRevision: expectedRevision) { snapshot in
            guard snapshot.records.count < Self.maximumRecords else { throw PocketCollectionError.capacityExceeded }
            snapshot.records.append(PocketCollectionRecord(id: UUID().uuidString.lowercased(), fields: fields))
        }
    }

    @discardableResult
    func update(id: String, fields: [String: PocketJSONValue], expectedRevision: Int) throws -> PocketCollectionSnapshot {
        try schema.validate(fields)
        return try mutate(expectedRevision: expectedRevision) { snapshot in
            guard let index = snapshot.records.firstIndex(where: { $0.id == id }) else { throw PocketCollectionError.recordNotFound }
            snapshot.records[index].fields = fields
        }
    }

    @discardableResult
    func delete(id: String, expectedRevision: Int) throws -> PocketCollectionSnapshot {
        try mutate(expectedRevision: expectedRevision) { snapshot in
            guard let index = snapshot.records.firstIndex(where: { $0.id == id }) else { throw PocketCollectionError.recordNotFound }
            snapshot.records.remove(at: index)
        }
    }

    private func mutate(expectedRevision: Int, body: (inout PocketCollectionSnapshot) throws -> Void) throws -> PocketCollectionSnapshot {
        try locked { descriptor in
            var next = try read(directoryDescriptor: descriptor)
            guard next.revision == expectedRevision else { throw PocketCollectionError.revisionConflict }
            guard next.revision < 9_007_199_254_740_991 else { throw PocketCollectionError.capacityExceeded }
            try body(&next)
            next.revision += 1
            let bytes = try JSONSerialization.data(withJSONObject: next.json, options: [.sortedKeys])
            guard bytes.count <= Self.maximumBytes else { throw PocketCollectionError.capacityExceeded }
            try write(bytes, directoryDescriptor: descriptor)
            guard try read(directoryDescriptor: descriptor) == next else { throw PocketCollectionError.persistenceFailed }
            return next
        }
    }

    private func locked<T>(_ body: (Int32) throws -> T) throws -> T {
        try PocketToolDataLock.withLock(rootDirectory: rootDirectory, packageID: packageID) {
            try directory.withValidatedDescriptor(body)
        }
    }

    private func read(directoryDescriptor: Int32) throws -> PocketCollectionSnapshot {
        let descriptor = openat(directoryDescriptor, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            guard errno == ENOENT else { throw PocketCollectionError.persistenceFailed }
            return PocketCollectionSnapshot(schemaVersion: schema.version, revision: 0, records: [])
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1, metadata.st_size >= 0, metadata.st_size <= Self.maximumBytes else {
            throw PocketCollectionError.invalidDocument
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw PocketCollectionError.persistenceFailed
            }
            guard data.count + count <= Self.maximumBytes else { throw PocketCollectionError.capacityExceeded }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try Self.decode(data, schema: schema)
    }

    nonisolated static func decode(_ data: Data, schema: PocketCollectionSchema) throws -> PocketCollectionSnapshot {
        guard data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["formatVersion", "schemaVersion", "revision", "records"],
              PocketCollectionSchema.integer(object["formatVersion"]) == 1,
              PocketCollectionSchema.integer(object["schemaVersion"]) == schema.version,
              let revision = PocketCollectionSchema.integer(object["revision"]), revision >= 0,
              let rawRecords = object["records"] as? [[String: Any]], rawRecords.count <= Self.maximumRecords else {
            throw PocketCollectionError.invalidDocument
        }
        var ids: Set<String> = []
        let records = try rawRecords.map { raw -> PocketCollectionRecord in
            guard Set(raw.keys) == ["id", "fields"], let id = raw["id"] as? String,
                  UUID(uuidString: id) != nil, id == id.lowercased(), ids.insert(id).inserted,
                  let rawFields = raw["fields"] as? [String: Any] else { throw PocketCollectionError.invalidDocument }
            let fields = try rawFields.mapValues { try PocketJSONValue(any: $0, path: "$.fields") }
            try schema.validate(fields)
            return PocketCollectionRecord(id: id, fields: fields)
        }
        return PocketCollectionSnapshot(schemaVersion: schema.version, revision: revision, records: records)
    }

    private func write(_ data: Data, directoryDescriptor: Int32) throws {
        let temporary = ".collection-\(UUID().uuidString).tmp"
        let descriptor = openat(directoryDescriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw PocketCollectionError.persistenceFailed }
        defer {
            close(descriptor)
            _ = unlinkat(directoryDescriptor, temporary, 0)
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw PocketCollectionError.persistenceFailed }
                offset += count
            }
        }
        guard fsync(descriptor) == 0,
              renameat(directoryDescriptor, temporary, directoryDescriptor, filename) == 0 else {
            throw PocketCollectionError.persistenceFailed
        }
    }
}
