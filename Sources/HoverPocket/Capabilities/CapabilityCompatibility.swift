import Foundation

enum PocketCapabilityLifecycleStatus: String, Codable, Sendable {
    case active
    case deprecated
    case removed
}

struct PocketCapabilityLifecycleRecord: Equatable, Sendable {
    let key: PocketCapabilityKey
    let status: PocketCapabilityLifecycleStatus
    let introducedInHostVersion: String
    let deprecatedInHostVersion: String?
    let removalNotBeforeHostVersion: String?
    let replacement: PocketCapabilityKey?
    let migrationID: String?
    let noticeKey: String
}

struct PocketCapabilityReferenceMigration: Equatable, Sendable {
    let id: String
    let source: PocketCapabilityKey
    let target: PocketCapabilityKey
}

struct PocketCapabilityCompatibilityIssue: Equatable, Sendable {
    let key: PocketCapabilityKey
    let status: PocketCapabilityLifecycleStatus
    let replacement: PocketCapabilityKey
    let migrationID: String
    let removalNotBeforeHostVersion: String
    let noticeKey: String
}

enum PocketCapabilityCompatibilityError: Error, Equatable, Sendable {
    case invalidPolicy(String)
    case migrationUnavailable(PocketCapabilityKey)
}

struct PocketCapabilityCompatibilityCatalog: Sendable {
    static let currentHostVersion = "1.0.0"

    static let builtIn: PocketCapabilityCompatibilityCatalog = {
        do {
            return try PocketCapabilityCompatibilityCatalog(
                hostVersion: currentHostVersion,
                records: [],
                migrations: []
            )
        } catch {
            preconditionFailure("Invalid built-in capability compatibility catalog: \(error)")
        }
    }()

    let hostVersion: String
    private let records: [PocketCapabilityKey: PocketCapabilityLifecycleRecord]
    private let migrations: [PocketCapabilityKey: PocketCapabilityReferenceMigration]

    init(
        hostVersion: String,
        records: [PocketCapabilityLifecycleRecord],
        migrations: [PocketCapabilityReferenceMigration]
    ) throws {
        guard Self.semanticVersion(hostVersion) != nil else {
            throw PocketCapabilityCompatibilityError.invalidPolicy("host_version")
        }

        var recordMap: [PocketCapabilityKey: PocketCapabilityLifecycleRecord] = [:]
        for record in records {
            guard Self.validKey(record.key),
                  Self.semanticVersion(record.introducedInHostVersion) != nil,
                  recordMap[record.key] == nil else {
                throw PocketCapabilityCompatibilityError.invalidPolicy("record")
            }
            try Self.validate(record: record, hostVersion: hostVersion)
            recordMap[record.key] = record
        }

        var migrationMap: [PocketCapabilityKey: PocketCapabilityReferenceMigration] = [:]
        var migrationIDs: Set<String> = []
        for migration in migrations {
            guard Self.validMigrationID(migration.id),
                  Self.validKey(migration.source),
                  Self.validKey(migration.target),
                  migration.source != migration.target,
                  migrationMap[migration.source] == nil,
                  migrationIDs.insert(migration.id).inserted else {
                throw PocketCapabilityCompatibilityError.invalidPolicy("migration")
            }
            guard let record = recordMap[migration.source],
                  record.status != .active,
                  record.replacement == migration.target,
                  record.migrationID == migration.id else {
                throw PocketCapabilityCompatibilityError.invalidPolicy("migration_binding")
            }
            migrationMap[migration.source] = migration
        }

        for record in recordMap.values where record.status != .active {
            guard migrationMap[record.key] != nil else {
                throw PocketCapabilityCompatibilityError.invalidPolicy("migration_missing")
            }
            guard let replacement = record.replacement,
                  recordMap[replacement]?.status != .removed else {
                throw PocketCapabilityCompatibilityError.invalidPolicy("replacement_removed")
            }
        }

        for source in migrationMap.keys {
            var visited: Set<PocketCapabilityKey> = [source]
            var current = migrationMap[source]?.target
            while let key = current, let next = migrationMap[key]?.target {
                guard visited.insert(key).inserted else {
                    throw PocketCapabilityCompatibilityError.invalidPolicy("migration_cycle")
                }
                current = next
            }
        }

        self.hostVersion = hostVersion
        self.records = recordMap
        self.migrations = migrationMap
    }

    func status(for key: PocketCapabilityKey) -> PocketCapabilityLifecycleStatus {
        records[key]?.status ?? .active
    }

    func issue(for key: PocketCapabilityKey) -> PocketCapabilityCompatibilityIssue? {
        guard let record = records[key],
              record.status != .active,
              let replacement = record.replacement,
              let migrationID = record.migrationID,
              let removalNotBefore = record.removalNotBeforeHostVersion else {
            return nil
        }
        return PocketCapabilityCompatibilityIssue(
            key: key,
            status: record.status,
            replacement: replacement,
            migrationID: migrationID,
            removalNotBeforeHostVersion: removalNotBefore,
            noticeKey: record.noticeKey
        )
    }

    func migration(for key: PocketCapabilityKey) throws -> PocketCapabilityReferenceMigration {
        guard let migration = migrations[key] else {
            throw PocketCapabilityCompatibilityError.migrationUnavailable(key)
        }
        return migration
    }

    func requireRuntimeExecutable(_ key: PocketCapabilityKey) throws {
        guard let record = records[key], record.status == .removed else { return }
        throw CapabilityBrokerError.removedCapability(key, record.replacement)
    }

    private static func validate(record: PocketCapabilityLifecycleRecord, hostVersion: String) throws {
        guard validNoticeKey(record.noticeKey),
              let introduced = semanticVersion(record.introducedInHostVersion),
              let host = semanticVersion(hostVersion),
              compare(introduced, host) != .orderedDescending else {
            throw PocketCapabilityCompatibilityError.invalidPolicy("record_version")
        }

        switch record.status {
        case .active:
            guard record.deprecatedInHostVersion == nil,
                  record.removalNotBeforeHostVersion == nil,
                  record.replacement == nil,
                  record.migrationID == nil else {
                throw PocketCapabilityCompatibilityError.invalidPolicy("active_fields")
            }
        case .deprecated, .removed:
            guard let deprecated = record.deprecatedInHostVersion.flatMap(semanticVersion),
                  let removal = record.removalNotBeforeHostVersion.flatMap(semanticVersion),
                  let replacement = record.replacement,
                  validKey(replacement), replacement != record.key,
                  let migrationID = record.migrationID,
                  validMigrationID(migrationID),
                  compare(introduced, deprecated) != .orderedDescending,
                  compare(deprecated, host) != .orderedDescending,
                  compare(deprecated, removal) == .orderedAscending else {
                throw PocketCapabilityCompatibilityError.invalidPolicy("deprecation_window")
            }
            if record.status == .removed, compare(host, removal) == .orderedAscending {
                throw PocketCapabilityCompatibilityError.invalidPolicy("removed_too_early")
            }
        }
    }

    private static func validKey(_ key: PocketCapabilityKey) -> Bool {
        key.version >= 1
            && key.id.range(
                of: "^[a-z][a-z0-9]*(?:\\.[a-z][a-z0-9_]*){2,}$",
                options: .regularExpression
            ) != nil
    }

    private static func validMigrationID(_ value: String) -> Bool {
        value.unicodeScalars.count <= 128
            && value.range(
                of: "^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)+$",
                options: .regularExpression
            ) != nil
    }

    private static func validNoticeKey(_ value: String) -> Bool {
        value.unicodeScalars.count <= 160
            && value.range(
                of: "^[a-z][a-z0-9]*(?:\\.[a-z0-9_-]+)+$",
                options: .regularExpression
            ) != nil
    }

    private static func semanticVersion(_ value: String) -> [Int]? {
        guard value.unicodeScalars.count <= 64,
              let match = value.wholeMatch(of: /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/),
              let major = Int(match.1),
              let minor = Int(match.2),
              let patch = Int(match.3) else {
            return nil
        }
        return [major, minor, patch]
    }

    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        for (left, right) in zip(lhs, rhs) where left != right {
            return left < right ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }
}
