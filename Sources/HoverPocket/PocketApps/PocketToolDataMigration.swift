import CryptoKit
import Foundation

struct PocketToolDataMigration: Equatable, Sendable {
    let packageID: String
    let sourceFiles: [String: Data]
    let targetFiles: [String: Data]
    let summary: [String]

    var digest: String { Self.digest(sourceFiles) + ":" + Self.digest(targetFiles) }

    @MainActor
    static func prepare(from source: PocketAppPackage, to target: PocketAppPackage, userDataRoot: URL) throws -> Self {
        guard source.manifest.id == target.manifest.id,
              source.manifest.apiVersion == "hoverpocket.app/v2", target.manifest.apiVersion == "hoverpocket.app/v2",
              source.stateProperties == target.stateProperties else { throw PocketAppLifecycleError.migrationRequired }
        return try PocketToolDataLock.withLock(rootDirectory: userDataRoot, packageID: source.manifest.id) {
            let files = try capture(directory: userDataRoot.appendingPathComponent(source.manifest.id))
            var next = files
            var summary: [String] = []
            for (id, previousSchema) in source.collections {
                let path = "Collections/" + id + ".json"
                let snapshot = try files[path].map { try PocketCollectionStore.decode($0, schema: previousSchema) }
                guard let schema = target.collections[id] else {
                    next.removeValue(forKey: path)
                    summary.append("「\(previousSchema.title)」の\(snapshot?.records.count ?? 0)件を移行前のバックアップへ退避します。")
                    continue
                }
                guard schema != previousSchema else { continue }
                let removed = Set(previousSchema.fields.keys).subtracting(schema.fields.keys)
                let added = Set(schema.fields.keys).subtracting(previousSchema.fields.keys)
                if !removed.isEmpty {
                    let titles = removed.sorted().compactMap { previousSchema.fields[$0]?.title }.joined(separator: "、")
                    summary.append("「\(previousSchema.title)」の項目「\(titles)」を画面と現在のデータから除き、元の値をバックアップへ残します。")
                }
                if !added.isEmpty {
                    summary.append("「\(schema.title)」に「\(added.sorted().compactMap { schema.fields[$0]?.title }.joined(separator: "、"))」を追加します。")
                }
                if let snapshot {
                    let records = try snapshot.records.map { record -> PocketCollectionRecord in
                        let fields = record.fields.filter { schema.fields[$0.key] != nil }
                        try schema.validate(fields)
                        return PocketCollectionRecord(id: record.id, fields: fields)
                    }
                    guard snapshot.revision < 9_007_199_254_740_991 else { throw PocketCollectionError.capacityExceeded }
                    let migrated = PocketCollectionSnapshot(schemaVersion: schema.version, revision: snapshot.revision + 1, records: records)
                    next[path] = try JSONSerialization.data(withJSONObject: migrated.json, options: [.sortedKeys])
                }
                if added.isEmpty && removed.isEmpty { summary.append("「\(schema.title)」の項目設定を更新し、入力済みの値を保持します。") }
            }
            for id in Set(target.collections.keys).subtracting(source.collections.keys).sorted() {
                guard next["Collections/" + id + ".json"] == nil else { throw PocketAppLifecycleError.migrationRequired }
                summary.append("空の「\(target.collections[id]!.title)」を追加します。")
            }
            return Self(packageID: source.manifest.id, sourceFiles: files, targetFiles: next, summary: summary)
        }
    }

    static func capture(directory: URL) throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        let pin = try PocketAppPinnedDirectory(url: directory)
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: pin.url.path) {
            if name == "state.json" {
                files[name] = try PocketAppFileSnapshot.readFileNoFollow(rootDirectory: pin.url, relativePath: name, maximumBytes: 256 * 1_024)
            } else if name == "Collections" {
                let collections = try PocketAppPinnedDirectory(url: pin.url.appendingPathComponent(name))
                for filename in try FileManager.default.contentsOfDirectory(atPath: collections.url.path) {
                    if filename.hasSuffix(".lock") { continue }
                    guard filename.hasSuffix(".json"), PocketCollectionSchema.validIdentifier(String(filename.dropLast(5))) else {
                        throw PocketAppLifecycleError.migrationRequired
                    }
                    let path = name + "/" + filename
                    files[path] = try PocketAppFileSnapshot.readFileNoFollow(rootDirectory: pin.url, relativePath: path, maximumBytes: PocketCollectionStore.maximumBytes)
                }
            } else { throw PocketAppLifecycleError.migrationRequired }
        }
        guard files.count <= 17, files.values.reduce(0, { $0 + $1.count }) <= 128 * 1_024 * 1_024 else {
            throw PocketCollectionError.capacityExceeded
        }
        try pin.validate()
        return files
    }

    static func digest(_ files: [String: Data]) -> String {
        var hash = SHA256()
        for path in files.keys.sorted() {
            hash.update(data: Data((path + "\0" + String(files[path]!.count) + "\0").utf8))
            hash.update(data: files[path]!)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class PocketToolDataMigrationTransaction {
    struct Journal: Codable {
        var formatVersion = 1
        let packageID: String
        let sourceDigest: String
        let targetDigest: String
        let previousActiveRecord: Data
        var phase: String
    }
    let directory: URL
    private let userDataRoot: URL
    private(set) var journal: Journal

    private init(directory: URL, userDataRoot: URL, journal: Journal) {
        self.directory = directory
        self.userDataRoot = userDataRoot
        self.journal = journal
    }

    static func begin(plan: PocketToolDataMigration, previousActiveRecord: Data, userDataRoot: URL, journalRoot: URL) throws -> PocketToolDataMigrationTransaction {
        let target = userDataRoot.appendingPathComponent(plan.packageID)
        guard try PocketToolDataMigration.capture(directory: target) == plan.sourceFiles else { throw PocketCollectionError.revisionConflict }
        let root = try PocketAppPinnedDirectory(url: journalRoot)
        let directory = root.url.appendingPathComponent(UUID().uuidString.lowercased())
        _ = try PocketAppPinnedDirectory(url: directory)
        let candidate = directory.appendingPathComponent("NewData")
        _ = try PocketAppPinnedDirectory(url: candidate)
        for (path, data) in plan.targetFiles {
            let file = candidate.appendingPathComponent(path)
            _ = try PocketAppPinnedDirectory(url: file.deletingLastPathComponent())
            try data.write(to: file, options: .withoutOverwriting)
        }
        guard try PocketToolDataMigration.capture(directory: candidate) == plan.targetFiles else { throw PocketCollectionError.persistenceFailed }
        let transaction = PocketToolDataMigrationTransaction(directory: directory, userDataRoot: userDataRoot,
            journal: Journal(packageID: plan.packageID, sourceDigest: PocketToolDataMigration.digest(plan.sourceFiles),
                targetDigest: PocketToolDataMigration.digest(plan.targetFiles), previousActiveRecord: previousActiveRecord, phase: "prepared"))
        try transaction.saveJournal()
        do {
            let before = directory.appendingPathComponent("BeforeData")
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.moveItem(at: target, to: before) }
            else { _ = try PocketAppPinnedDirectory(url: before) }
            try FileManager.default.moveItem(at: candidate, to: target)
            guard try PocketToolDataMigration.capture(directory: target) == plan.targetFiles else { throw PocketCollectionError.persistenceFailed }
            return transaction
        } catch {
            try transaction.rollback()
            try transaction.finishRollback()
            throw error
        }
    }

    static func pending(journalRoot: URL, userDataRoot: URL) throws -> [PocketToolDataMigrationTransaction] {
        guard FileManager.default.fileExists(atPath: journalRoot.path) else { return [] }
        let root = try PocketAppPinnedDirectory(url: journalRoot)
        return try FileManager.default.contentsOfDirectory(atPath: root.url.path).compactMap { id in
            guard UUID(uuidString: id) != nil else { throw PocketCollectionError.invalidDocument }
            let directory = root.url.appendingPathComponent(id)
            let journalURL = directory.appendingPathComponent("journal.json")
            guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
            let data = try PocketAppFileSnapshot.readFileNoFollow(rootDirectory: root.url, relativePath: id + "/journal.json", maximumBytes: 32_768)
            let journal = try JSONDecoder().decode(Journal.self, from: data)
            guard journal.formatVersion == 1,
                  journal.packageID.range(of: "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$", options: .regularExpression) != nil,
                  journal.packageID.count <= 160,
                  ["prepared", "committed", "rolledBack"].contains(journal.phase) else { throw PocketCollectionError.invalidDocument }
            guard journal.phase == "prepared" else { return nil }
            return PocketToolDataMigrationTransaction(directory: directory, userDataRoot: userDataRoot, journal: journal)
        }
    }

    func commit() throws { journal.phase = "committed"; try saveJournal() }

    func rollback() throws {
        let target = userDataRoot.appendingPathComponent(journal.packageID)
        let before = directory.appendingPathComponent("BeforeData")
        if FileManager.default.fileExists(atPath: before.path) {
            guard try PocketToolDataMigration.digest(PocketToolDataMigration.capture(directory: before)) == journal.sourceDigest else {
                throw PocketCollectionError.invalidDocument
            }
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.moveItem(at: target, to: directory.appendingPathComponent("FailedData-" + UUID().uuidString))
            }
            // Copy keeps the original backup available after a rollback as well.
            try FileManager.default.copyItem(at: before, to: target)
        }
        guard try PocketToolDataMigration.digest(PocketToolDataMigration.capture(directory: target)) == journal.sourceDigest else {
            throw PocketCollectionError.persistenceFailed
        }
    }

    func finishRollback() throws { journal.phase = "rolledBack"; try saveJournal() }

    private func saveJournal() throws {
        let pin = try PocketAppPinnedDirectory(url: directory)
        let url = pin.url.appendingPathComponent("journal.json")
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
        try pin.validate()
    }
}
