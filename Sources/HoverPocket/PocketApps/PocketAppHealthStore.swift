import Darwin
import Foundation

enum PocketAppHealthStatus: String, Codable, Sendable {
    case healthy
    case attention
    case unused
    case disabled
}

struct PocketAppHealthSnapshot: Equatable, Sendable {
    let packageID: String
    let status: PocketAppHealthStatus
    let reasonCode: String
    let lastUsedAt: Date?
    let lastSuccessfulActivationAt: Date?
    let consecutiveActivationFailures: Int
    let disableSuggested: Bool
}

enum PocketAppHealthError: Error, Equatable {
    case invalid
    case storage
    case readback
}

final class PocketAppHealthStore {
    private struct Record: Codable, Equatable {
        let recordVersion: Int
        let packageID: String
        var firstActivatedAt: Date?
        var lastSuccessfulActivationAt: Date?
        var lastUsedAt: Date?
        var lastFailureAt: Date?
        var consecutiveActivationFailures: Int
        var updatedAt: Date
    }

    static let unusedInterval: TimeInterval = 30 * 24 * 60 * 60
    private static let usageWriteInterval: TimeInterval = 5 * 60
    private static let maximumRecordBytes = 16 * 1_024

    private let rootDirectory: URL

    init(rootDirectory: URL) throws {
        self.rootDirectory = rootDirectory.standardizedFileURL
        do {
            try FileManager.default.createDirectory(
                at: self.rootDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try requireSafeRoot()
        } catch let error as PocketAppHealthError {
            throw error
        } catch {
            throw PocketAppHealthError.storage
        }
    }

    func recordActivationSuccess(packageID: String, now: Date = Date()) throws {
        try update(packageID: packageID, now: now) { record in
            if record.firstActivatedAt == nil { record.firstActivatedAt = now }
            record.lastSuccessfulActivationAt = now
            record.consecutiveActivationFailures = 0
        }
    }

    func recordActivationFailure(packageID: String, now: Date = Date()) throws {
        try update(packageID: packageID, now: now) { record in
            record.lastFailureAt = now
            record.consecutiveActivationFailures = min(record.consecutiveActivationFailures + 1, 1_000)
        }
    }

    func recordUse(packageID: String, now: Date = Date()) throws {
        guard Self.validPackageID(packageID) else { throw PocketAppHealthError.invalid }
        if let current = try read(packageID: packageID),
           let lastUsedAt = current.lastUsedAt,
           now.timeIntervalSince(lastUsedAt) >= 0,
           now.timeIntervalSince(lastUsedAt) < Self.usageWriteInterval {
            return
        }
        try update(packageID: packageID, now: now) { record in
            if record.firstActivatedAt == nil { record.firstActivatedAt = now }
            record.lastUsedAt = now
        }
    }

    func snapshots(
        packages: [PocketAppManagedPackage],
        issues: [PocketAppManagementIssue],
        now: Date = Date()
    ) -> [PocketAppHealthSnapshot] {
        var result: [PocketAppHealthSnapshot] = []
        for package in packages where package.state != .removed {
            do {
                let record = try read(packageID: package.packageID)
                result.append(Self.snapshot(package: package, record: record, now: now))
            } catch {
                result.append(PocketAppHealthSnapshot(
                    packageID: package.packageID,
                    status: .attention,
                    reasonCode: "HEALTH_METADATA_CORRUPT",
                    lastUsedAt: nil,
                    lastSuccessfulActivationAt: nil,
                    consecutiveActivationFailures: 0,
                    disableSuggested: false
                ))
            }
        }
        for issue in issues {
            let record = try? read(packageID: issue.packageID)
            result.append(PocketAppHealthSnapshot(
                packageID: issue.packageID,
                status: .attention,
                reasonCode: issue.errorCode,
                lastUsedAt: record?.lastUsedAt,
                lastSuccessfulActivationAt: record?.lastSuccessfulActivationAt,
                consecutiveActivationFailures: record?.consecutiveActivationFailures ?? 0,
                disableSuggested: false
            ))
        }
        return result.sorted { $0.packageID < $1.packageID }
    }

    private func update(
        packageID: String,
        now: Date,
        mutate: (inout Record) -> Void
    ) throws {
        guard Self.validPackageID(packageID), now.timeIntervalSince1970.isFinite else {
            throw PocketAppHealthError.invalid
        }
        var record = try read(packageID: packageID) ?? Record(
            recordVersion: 1,
            packageID: packageID,
            firstActivatedAt: nil,
            lastSuccessfulActivationAt: nil,
            lastUsedAt: nil,
            lastFailureAt: nil,
            consecutiveActivationFailures: 0,
            updatedAt: now
        )
        mutate(&record)
        record.updatedAt = now
        guard Self.valid(record) else { throw PocketAppHealthError.invalid }
        try write(record)
    }

    private func read(packageID: String) throws -> Record? {
        guard Self.validPackageID(packageID) else { throw PocketAppHealthError.invalid }
        try requireSafeRoot()
        let url = recordURL(packageID: packageID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try PocketAppFileSnapshot.readFileNoFollow(
                rootDirectory: rootDirectory,
                relativePath: "\(packageID).json",
                maximumBytes: Self.maximumRecordBytes
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let record = try decoder.decode(Record.self, from: data)
            guard Self.valid(record), record.packageID == packageID else {
                throw PocketAppHealthError.invalid
            }
            return record
        } catch let error as PocketAppHealthError {
            throw error
        } catch {
            throw PocketAppHealthError.invalid
        }
    }

    private func write(_ record: Record) throws {
        try requireSafeRoot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumRecordBytes else { throw PocketAppHealthError.invalid }

        let temporary = rootDirectory.appendingPathComponent(".health-\(UUID().uuidString.lowercased()).tmp")
        let destination = recordURL(packageID: record.packageID)
        do {
            try data.write(to: temporary, options: [.withoutOverwriting])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw PocketAppHealthError.storage
            }
            let observed = try PocketAppFileSnapshot.readFileNoFollow(
                rootDirectory: rootDirectory,
                relativePath: "\(record.packageID).json",
                maximumBytes: Self.maximumRecordBytes
            )
            guard observed == data else { throw PocketAppHealthError.readback }
        } catch let error as PocketAppHealthError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw PocketAppHealthError.storage
        }
    }

    private func requireSafeRoot() throws {
        let values = try rootDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw PocketAppHealthError.storage
        }
    }

    private func recordURL(packageID: String) -> URL {
        rootDirectory.appendingPathComponent("\(packageID).json", isDirectory: false)
    }

    private static func snapshot(
        package: PocketAppManagedPackage,
        record: Record?,
        now: Date
    ) -> PocketAppHealthSnapshot {
        if package.state == .disabled {
            return PocketAppHealthSnapshot(
                packageID: package.packageID,
                status: .disabled,
                reasonCode: "APP_DISABLED",
                lastUsedAt: record?.lastUsedAt,
                lastSuccessfulActivationAt: record?.lastSuccessfulActivationAt,
                consecutiveActivationFailures: record?.consecutiveActivationFailures ?? 0,
                disableSuggested: false
            )
        }
        if let record, record.consecutiveActivationFailures >= 3 {
            return PocketAppHealthSnapshot(
                packageID: package.packageID,
                status: .attention,
                reasonCode: "ACTIVATION_FAILURES",
                lastUsedAt: record.lastUsedAt,
                lastSuccessfulActivationAt: record.lastSuccessfulActivationAt,
                consecutiveActivationFailures: record.consecutiveActivationFailures,
                disableSuggested: false
            )
        }
        let inactivityReference = record?.lastUsedAt ?? record?.firstActivatedAt
        let unused = inactivityReference.map {
            now.timeIntervalSince($0) >= Self.unusedInterval
        } ?? false
        return PocketAppHealthSnapshot(
            packageID: package.packageID,
            status: unused ? .unused : .healthy,
            reasonCode: unused ? "UNUSED_30_DAYS" : "HEALTHY",
            lastUsedAt: record?.lastUsedAt,
            lastSuccessfulActivationAt: record?.lastSuccessfulActivationAt,
            consecutiveActivationFailures: record?.consecutiveActivationFailures ?? 0,
            disableSuggested: unused
        )
    }

    private static func valid(_ record: Record) -> Bool {
        let dates = [
            record.firstActivatedAt,
            record.lastSuccessfulActivationAt,
            record.lastUsedAt,
            record.lastFailureAt
        ].compactMap { $0 }
        guard record.recordVersion == 1,
              validPackageID(record.packageID),
              (0...1_000).contains(record.consecutiveActivationFailures),
              dates.allSatisfy({ $0.timeIntervalSince1970.isFinite && $0 <= record.updatedAt }) else {
            return false
        }
        if let first = record.firstActivatedAt,
           let success = record.lastSuccessfulActivationAt,
           success < first {
            return false
        }
        return true
    }

    private static func validPackageID(_ value: String) -> Bool {
        value.unicodeScalars.count <= 160
            && value.range(
                of: "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$",
                options: .regularExpression
            ) != nil
    }
}
