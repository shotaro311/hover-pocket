import Foundation

struct PocketAppCapabilityMigrationReceipt: Equatable, Sendable {
    let packageID: String
    let sourceVersion: String
    let targetVersion: String
    let sourcePackageDigest: String
    let targetPackageDigest: String
    let migrationIDs: [String]
    let replacementCounts: [String: Int]
    let stateSchemaDigest: String
    let userDataStore: String
}

enum PocketAppCapabilityMigrationError: Error, Equatable, Sendable {
    case invalid(String)
}

struct PocketAppCapabilityMigrator {
    private let runtime: PocketAppPackageRuntime
    private let catalog: PocketCapabilityCompatibilityCatalog

    init(
        descriptors: [PocketCapabilityDescriptor] = PocketCapabilityDescriptors.builtIn,
        catalog: PocketCapabilityCompatibilityCatalog = .builtIn
    ) {
        self.runtime = PocketAppPackageRuntime(
            descriptors: descriptors,
            compatibilityCatalog: catalog
        )
        self.catalog = catalog
    }

    func migrate(
        sourceDirectory: URL,
        destinationDirectory: URL,
        targetVersion: String
    ) throws -> PocketAppCapabilityMigrationReceipt {
        guard sourceDirectory.standardizedFileURL != destinationDirectory.standardizedFileURL else {
            throw PocketAppCapabilityMigrationError.invalid("destination")
        }
        let sourceSnapshot = try PocketAppFileSnapshot.capture(directory: sourceDirectory)
        let sourcePackage = try runtime.loadMigrationSource(snapshot: sourceSnapshot)
        guard !sourcePackage.compatibilityIssues.isEmpty,
              Self.validVersion(targetVersion),
              Self.compareVersions(sourcePackage.manifest.version, targetVersion) == .orderedAscending else {
            throw PocketAppCapabilityMigrationError.invalid("version")
        }

        let migrations = try sourcePackage.compatibilityIssues.map { try catalog.migration(for: $0.key) }
        let rewritten = try rewrite(
            sourceSnapshot,
            package: sourcePackage,
            targetVersion: targetVersion,
            migrations: migrations,
            destinationDirectory: destinationDirectory
        )
        let validatedTarget = try runtime.load(snapshot: rewritten.snapshot)
        guard validatedTarget.manifest.id == sourcePackage.manifest.id,
              validatedTarget.manifest.version == targetVersion,
              validatedTarget.manifest.stateStore == sourcePackage.manifest.stateStore,
              validatedTarget.stateSchemaDigest == sourcePackage.stateSchemaDigest,
              validatedTarget.compatibilityIssues.isEmpty else {
            throw PocketAppCapabilityMigrationError.invalid("target_readback")
        }

        try rewritten.snapshot.materialize(at: destinationDirectory)
        let materialized = try runtime.load(directory: destinationDirectory)
        guard materialized.manifestDigest == validatedTarget.manifestDigest,
              materialized.stateSchemaDigest == sourcePackage.stateSchemaDigest,
              materialized.manifest.stateStore == sourcePackage.manifest.stateStore else {
            throw PocketAppCapabilityMigrationError.invalid("materialized_readback")
        }

        return PocketAppCapabilityMigrationReceipt(
            packageID: sourcePackage.manifest.id,
            sourceVersion: sourcePackage.manifest.version,
            targetVersion: targetVersion,
            sourcePackageDigest: sourcePackage.manifestDigest,
            targetPackageDigest: materialized.manifestDigest,
            migrationIDs: migrations.map(\.id).sorted(),
            replacementCounts: rewritten.counts,
            stateSchemaDigest: materialized.stateSchemaDigest,
            userDataStore: materialized.manifest.stateStore
        )
    }

    func rewriteForVerification(
        snapshot: PocketAppFileSnapshot,
        package: PocketAppPackage,
        targetVersion: String,
        migrations: [PocketCapabilityReferenceMigration],
        destinationDirectory: URL
    ) throws -> (snapshot: PocketAppFileSnapshot, counts: [String: Int]) {
        try rewrite(
            snapshot,
            package: package,
            targetVersion: targetVersion,
            migrations: migrations,
            destinationDirectory: destinationDirectory
        )
    }

    private func rewrite(
        _ snapshot: PocketAppFileSnapshot,
        package: PocketAppPackage,
        targetVersion: String,
        migrations: [PocketCapabilityReferenceMigration],
        destinationDirectory: URL
    ) throws -> (snapshot: PocketAppFileSnapshot, counts: [String: Int]) {
        var files = snapshot.files
        var counts = Dictionary(uniqueKeysWithValues: migrations.map { ($0.id, 0) })
        let bySource = Dictionary(uniqueKeysWithValues: migrations.map { ($0.source, $0) })
        let referenceMap = Dictionary(uniqueKeysWithValues: migrations.map {
            (Self.reference($0.source), Self.reference($0.target))
        })

        guard let manifestData = files["manifest.json"],
              var manifest = try Self.object(manifestData),
              var requested = manifest["requestedCapabilities"] as? [[String: Any]] else {
            throw PocketAppCapabilityMigrationError.invalid("manifest")
        }
        manifest["version"] = targetVersion
        for index in requested.indices {
            guard let id = requested[index]["id"] as? String,
                  let version = Self.integer(requested[index]["version"]) else {
                throw PocketAppCapabilityMigrationError.invalid("manifest_capability")
            }
            let key = PocketCapabilityKey(id: id, version: version)
            guard let migration = bySource[key] else { continue }
            requested[index]["id"] = migration.target.id
            requested[index]["version"] = migration.target.version
            counts[migration.id, default: 0] += 1
        }
        manifest["requestedCapabilities"] = requested
        files["manifest.json"] = try Self.canonicalJSON(manifest)

        for path in package.manifest.workflows.values.sorted() {
            guard let data = files[path], var workflow = try Self.object(data),
                  var steps = workflow["steps"] as? [[String: Any]] else {
                throw PocketAppCapabilityMigrationError.invalid("workflow")
            }
            for index in steps.indices {
                guard let reference = steps[index]["use"] as? String else {
                    throw PocketAppCapabilityMigrationError.invalid("workflow_reference")
                }
                if let target = referenceMap[reference],
                   let migration = migrations.first(where: { Self.reference($0.source) == reference }) {
                    steps[index]["use"] = target
                    counts[migration.id, default: 0] += 1
                }
            }
            workflow["steps"] = steps
            files[path] = try Self.canonicalJSON(workflow)
        }

        for path in package.manifest.surfaces.values.sorted() {
            guard let data = files[path], var surface = try Self.object(data) else {
                throw PocketAppCapabilityMigrationError.invalid("surface")
            }
            try Self.rewriteQueries(&surface, referenceMap: referenceMap, migrations: migrations, counts: &counts)
            files[path] = try Self.canonicalJSON(surface)
        }

        guard counts.values.allSatisfy({ $0 > 0 }),
              files[package.manifest.stateSchemaPath] == snapshot.files[package.manifest.stateSchemaPath] else {
            throw PocketAppCapabilityMigrationError.invalid("migration_coverage")
        }
        return (
            PocketAppFileSnapshot(
                rootDirectory: destinationDirectory.standardizedFileURL,
                files: files,
                identities: [:]
            ),
            counts
        )
    }

    private static func rewriteQueries(
        _ object: inout [String: Any],
        referenceMap: [String: String],
        migrations: [PocketCapabilityReferenceMigration],
        counts: inout [String: Int]
    ) throws {
        for key in object.keys.sorted() {
            if key == "query", let reference = object[key] as? String,
               let target = referenceMap[reference],
               let migration = migrations.first(where: { Self.reference($0.source) == reference }) {
                object[key] = target
                counts[migration.id, default: 0] += 1
            } else if var child = object[key] as? [String: Any] {
                try rewriteQueries(&child, referenceMap: referenceMap, migrations: migrations, counts: &counts)
                object[key] = child
            } else if var array = object[key] as? [Any] {
                for index in array.indices where array[index] is [String: Any] {
                    var child = array[index] as! [String: Any]
                    try rewriteQueries(&child, referenceMap: referenceMap, migrations: migrations, counts: &counts)
                    array[index] = child
                }
                object[key] = array
            }
        }
    }

    private static func object(_ data: Data) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private static func canonicalJSON(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.intValue
    }

    private static func reference(_ key: PocketCapabilityKey) -> String {
        "\(key.id)@\(key.version)"
    }

    private static func validVersion(_ value: String) -> Bool {
        value.range(
            of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$",
            options: .regularExpression
        ) != nil
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: "-", maxSplits: 1)[0].split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: "-", maxSplits: 1)[0].split(separator: ".").compactMap { Int($0) }
        for (a, b) in zip(left, right) where a != b {
            return a < b ? .orderedAscending : .orderedDescending
        }
        if lhs == rhs { return .orderedSame }
        return lhs.contains("-") && !rhs.contains("-") ? .orderedAscending : .orderedDescending
    }
}
