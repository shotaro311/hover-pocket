import Darwin
import Foundation

struct PocketToolCheckpoint: Codable, Equatable, Identifiable, Sendable {
    let formatVersion: Int
    let id: String
    let packageID: String
    let name: String
    let version: String
    let packageDigest: String
    let createdAt: Date
    let summary: String
    let kind: String
    let validation: String
    let byteCount: Int
}

enum PocketToolHistoryError: Error { case invalid, capacityExceeded, busy }

@MainActor
final class PocketToolHistoryStore {
    static let maximumCount = 20
    static let maximumBytes = 100 * 1_024 * 1_024
    private let root: PocketAppPinnedDirectory
    private let countLimit: Int
    private let byteLimit: Int
    private let moveToTrash: (URL) throws -> Void

    init(rootDirectory: URL, countLimit: Int = maximumCount, byteLimit: Int = maximumBytes,
         moveToTrash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        guard countLimit >= 2, byteLimit > 0 else { throw PocketToolHistoryError.invalid }
        root = try PocketAppPinnedDirectory(url: rootDirectory)
        self.countLimit = countLimit
        self.byteLimit = byteLimit
        self.moveToTrash = moveToTrash
    }

    func withRemovalLock<T>(_ body: () throws -> T) throws -> T {
        try locked(body)
    }

    func list(packageID: String? = nil) throws -> [PocketToolCheckpoint] {
        try root.validate()
        let ids: [String]
        if let packageID { ids = [packageID] }
        else {
            ids = try FileManager.default.contentsOfDirectory(atPath: root.url.path).filter { !$0.hasPrefix(".") }
        }
        let items = try ids.flatMap { id -> [PocketToolCheckpoint] in
            guard Self.validPackageID(id) else { throw PocketToolHistoryError.invalid }
            let tool = root.url.appendingPathComponent(id)
            guard FileManager.default.fileExists(atPath: tool.path) else { return [] }
            let pin = try PocketAppPinnedDirectory(url: tool)
            let entries = pin.url.appendingPathComponent("Entries")
            guard FileManager.default.fileExists(atPath: entries.path) else { return [] }
            _ = try PocketAppPinnedDirectory(url: entries)
            return try FileManager.default.contentsOfDirectory(atPath: entries.path).map { name in
                guard name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(5))) != nil else { throw PocketToolHistoryError.invalid }
                let data = try PocketAppFileSnapshot.readFileNoFollow(rootDirectory: entries, relativePath: name, maximumBytes: 8_192)
                let entry = try Self.decoder().decode(PocketToolCheckpoint.self, from: data)
                guard entry.formatVersion == 1, entry.packageID == id, entry.id + ".json" == name,
                      Self.validDigest(entry.packageDigest), (0...PocketAppPackageRuntime.maximumPackageBytes).contains(entry.byteCount),
                      ["preview", "restored", "installed"].contains(entry.kind), entry.validation == "contract-passed" else {
                    throw PocketToolHistoryError.invalid
                }
                return entry
            }
        }
        try root.validate()
        return items.sorted { $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func record(package: PocketAppPackage, summary: String, kind: String = "preview",
                installedDigest: String? = nil, reservedDefinitionBytes: Int = 0, now: Date = Date()) throws -> PocketToolCheckpoint {
        guard reservedDefinitionBytes >= 0, Self.validPackageID(package.manifest.id), ["preview", "restored", "installed"].contains(kind) else { throw PocketToolHistoryError.invalid }
        return try locked {
            let previous = try list(packageID: package.manifest.id)
            if kind == "preview", let latest = previous.first, latest.packageDigest == package.manifestDigest { return latest }
            let source = try PocketAppFileSnapshot.capture(directory: package.rootDirectory)
            guard try PocketAppPackageRuntime().load(snapshot: source).manifestDigest == package.manifestDigest else { throw PocketToolHistoryError.invalid }
            let entry = PocketToolCheckpoint(formatVersion: 1, id: UUID().uuidString.lowercased(), packageID: package.manifest.id,
                name: package.manifest.name, version: package.manifest.version, packageDigest: package.manifestDigest,
                createdAt: Self.timestamp.date(from: Self.timestamp.string(from: now))!, summary: String(summary.prefix(240)), kind: kind, validation: "contract-passed",
                byteCount: source.files.values.reduce(0) { $0 + $1.count })
            var retained = [entry] + previous
            let protected = Set([entry.id] + Array(previous.prefix(1)).map(\.id)
                + previous.filter { $0.packageDigest == installedDigest }.prefix(1).map(\.id))
            var removed: [PocketToolCheckpoint] = []
            while retained.count > countLimit || Self.bytes(retained) + reservedDefinitionBytes > byteLimit {
                guard let index = retained.lastIndex(where: { !protected.contains($0.id) }) else { throw PocketToolHistoryError.capacityExceeded }
                removed.append(retained.remove(at: index))
            }
            let tool = try PocketAppPinnedDirectory(url: root.url.appendingPathComponent(package.manifest.id))
            let objects = try PocketAppPinnedDirectory(url: tool.url.appendingPathComponent("Objects"))
            let entries = try PocketAppPinnedDirectory(url: tool.url.appendingPathComponent("Entries"))
            // Reclaim eligible history before allocating a new entry, so a failed Trash operation cannot grow history on retry.
            for obsolete in removed { try moveToTrash(entries.url.appendingPathComponent(obsolete.id + ".json")) }
            let referenced = Set(retained.map(\.packageDigest))
            for name in try FileManager.default.contentsOfDirectory(atPath: objects.url.path) {
                guard !name.hasPrefix("."), Self.validDigest("sha256:" + name) else { continue }
                if !referenced.contains("sha256:" + name) { try moveToTrash(objects.url.appendingPathComponent(name)) }
            }
            let objectURL = objects.url.appendingPathComponent(Self.digestName(entry.packageDigest))
            if FileManager.default.fileExists(atPath: objectURL.path) {
                guard try PocketAppPackageRuntime().load(directory: objectURL).manifestDigest == entry.packageDigest else { throw PocketToolHistoryError.invalid }
            } else {
                let staging = objects.url.appendingPathComponent(".pending-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                do {
                    for (path, data) in source.files {
                        let target = staging.appendingPathComponent(path)
                        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        try data.write(to: target, options: .withoutOverwriting)
                    }
                    guard try PocketAppPackageRuntime().load(directory: staging).manifestDigest == entry.packageDigest else { throw PocketToolHistoryError.invalid }
                    try objects.validate()
                    try FileManager.default.moveItem(at: staging, to: objectURL)
                } catch { try? FileManager.default.removeItem(at: staging); throw error }
            }
            let entryURL = entries.url.appendingPathComponent(entry.id + ".json")
            try Self.encoder().encode(entry).write(to: entryURL, options: .withoutOverwriting)
            guard try list(packageID: entry.packageID).contains(entry) else { throw PocketToolHistoryError.invalid }
            try root.validate()
            return entry
        }
    }

    func package(for entry: PocketToolCheckpoint) throws -> PocketAppPackage {
        guard try list(packageID: entry.packageID).contains(entry) else { throw PocketToolHistoryError.invalid }
        let directory = root.url.appendingPathComponent(entry.packageID).appendingPathComponent("Objects")
            .appendingPathComponent(Self.digestName(entry.packageDigest))
        let pin = try PocketAppPinnedDirectory(url: directory)
        let package = try PocketAppPackageRuntime().load(directory: pin.url)
        guard package.manifestDigest == entry.packageDigest, package.manifest.id == entry.packageID else { throw PocketToolHistoryError.invalid }
        return package
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try root.withValidatedDescriptor { descriptor in
            let lock = openat(descriptor, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard lock >= 0 else { throw PocketToolHistoryError.busy }
            defer { close(lock) }
            var stat = stat()
            guard fstat(lock, &stat) == 0, stat.st_nlink == 1, (stat.st_mode & S_IFMT) == S_IFREG,
                  flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw PocketToolHistoryError.busy }
            defer { _ = flock(lock, LOCK_UN) }
            return try body()
        }
    }

    private static var timestamp: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard value.hasSuffix("Z"), let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid UTC timestamp")
            }
            return date
        }
        return decoder
    }

    private static func bytes(_ entries: [PocketToolCheckpoint]) -> Int {
        var digests: Set<String> = []
        return entries.reduce(entries.count * 8_192) { total, entry in
            total + (digests.insert(entry.packageDigest).inserted ? entry.byteCount : 0)
        }
    }
    private static func validPackageID(_ value: String) -> Bool {
        value.count <= 160 && value.range(of: "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$", options: .regularExpression) != nil
    }
    private static func validDigest(_ value: String) -> Bool {
        value.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil
    }
    private static func digestName(_ value: String) -> String { String(value.dropFirst(7)) }
}
