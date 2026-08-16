import CryptoKit
import Darwin
import Foundation

enum PocketAppLifecycleAction: String, Codable, Sendable {
    case install
    case update
    case rollback
}

enum PocketAppDataDisposition: String, Codable, Sendable {
    case preserve
    case delete
}

enum PocketAppLifecycleState: String, Codable, Sendable {
    case enabled
    case disabled
    case removed
}

enum PocketAppHostContract {
    static let version = "1.0.0"
}

struct PocketAppPermissionDiff: Codable, Equatable, Sendable {
    let added: [String]
    let removed: [String]
}

struct PocketAppCapabilityGrantDiff: Codable, Equatable, Sendable {
    let added: [String]
    let removed: [String]
}

struct PocketAppPreviewSurface: Codable, Equatable, Sendable {
    let id: String
    let renderDigest: String
    let canonicalRenderModel: Data
}

struct PocketAppStagingTestResult: Codable, Equatable, Sendable {
    let id: String
    let expected: String
    let status: String
}

struct PocketAppLifecycleProposal: Equatable, Sendable {
    let requestID: String
    let action: PocketAppLifecycleAction
    let packageID: String
    let version: String
    let packageDigest: String
    let currentDigest: String?
    let currentState: PocketAppLifecycleState?
    let previewDigest: String
    let previews: [PocketAppPreviewSurface]
    let permissionDiff: PocketAppPermissionDiff
    let capabilityGrantDiff: PocketAppCapabilityGrantDiff
    let tests: [PocketAppStagingTestResult]
    let bindingDigest: String
    let createdAt: Date
    let expiresAt: Date
    let approvalRequired: Bool
    let stagingDirectory: URL
    let stateSchemaDigest: String
    let statePropertyNames: Set<String>
}

struct PocketAppLifecycleApprovalGrant: Equatable, Sendable {
    fileprivate let token: String
}

struct PocketAppLifecycleReceipt: Codable, Equatable, Sendable {
    let action: String
    let packageID: String
    let version: String?
    let packageDigest: String?
    let effectivePermissions: [String]
    let state: PocketAppLifecycleState
    let readbackVerified: Bool
    let dataDisposition: PocketAppDataDisposition?
}

struct PocketAppManagedPackage: Equatable, Sendable {
    let packageID: String
    let state: PocketAppLifecycleState
    let version: String?
    let packageDigest: String?
    let installedVersions: [String]
}

struct PocketAppManagementIssue: Equatable, Sendable {
    let packageID: String
    let errorCode: String
    let removalAllowed: Bool
}

struct PocketAppManagementSnapshot: Equatable, Sendable {
    let packages: [PocketAppManagedPackage]
    let issues: [PocketAppManagementIssue]
}

enum PocketAppLifecycleError: Error, Equatable {
    case invalidPackage
    case hostVersionUnsupported
    case stagingTestFailed
    case approvalRequired
    case approvalInvalid
    case approvalExpired
    case approvalReplayed
    case packageChanged
    case permissionChanged
    case activeChanged
    case versionConflict
    case downgradeRequiresRollback
    case corruptVersion
    case migrationRequired
    case pendingLimitExceeded
    case storageFailure
    case readbackFailed
}

@MainActor
final class PocketAppLifecycleManager {
    private final class LiveStagingRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []

        func insert(_ path: String) {
            _ = lock.withLock { paths.insert(path) }
        }

        func remove(_ path: String) {
            _ = lock.withLock { paths.remove(path) }
        }

        func contains(_ path: String) -> Bool {
            lock.withLock { paths.contains(path) }
        }

        func count(under rootPath: String) -> Int {
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            return lock.withLock {
                paths.lazy.filter { $0.hasPrefix(prefix) }.count
            }
        }
    }

    private nonisolated static let liveStagingRegistry = LiveStagingRegistry()

    private struct ActiveRecord: Codable, Equatable {
        var recordVersion = 1
        let packageID: String
        let version: String?
        let packageDigest: String?
        let permissions: [String]
        let stateSchemaDigest: String?
        let statePropertyNames: [String]
        let state: PocketAppLifecycleState
        let updatedAt: Date
    }

    private struct PendingApproval {
        let bindingDigest: String
        let expiresAt: Date
        let stagingDirectory: URL
        let disposableStaging: Bool
    }

    private struct IssuedApproval {
        let requestID: String
        let bindingDigest: String
        let expiresAt: Date
    }

    private let rootDirectory: URL
    private let userDataRoot: URL
    private let runtime: PocketAppPackageRuntime
    private let stagingTestRunner: PocketAppStagingTestRunner
    private let hostVersion: String
    private let failureInjection: ((String) -> Bool)?
    private let activationReadback: ((PocketAppLifecycleReceipt) throws -> PocketAppRuntimeReadback)?
    private var pendingApprovals: [String: PendingApproval] = [:]
    private var decidedRequests: Set<String> = []
    private var grants: [String: IssuedApproval] = [:]
    private var consumedGrants: Set<String> = []
    private let approvalLifetime: TimeInterval = 300
    private let maxPendingStagingSnapshots = 4

    init(
        rootDirectory: URL,
        userDataRoot: URL,
        runtime: PocketAppPackageRuntime = PocketAppPackageRuntime(),
        failureInjection: ((String) -> Bool)? = nil,
        hostVersion: String = PocketAppHostContract.version,
        performStartupRecovery: Bool = true,
        activationReadback: ((PocketAppLifecycleReceipt) throws -> PocketAppRuntimeReadback)? = nil
    ) throws {
        guard Self.validVersion(hostVersion) else { throw PocketAppLifecycleError.invalidPackage }
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.userDataRoot = userDataRoot.standardizedFileURL
        self.runtime = runtime
        self.stagingTestRunner = PocketAppStagingTestRunner()
        self.hostVersion = hostVersion
        self.failureInjection = failureInjection
        self.activationReadback = activationReadback
        do {
            try FileManager.default.createDirectory(
                at: self.rootDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.createDirectory(
                at: self.userDataRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if performStartupRecovery {
                try recoverInterruptedTransactions()
            }
        } catch let error as PocketAppLifecycleError {
            throw error
        } catch {
            throw PocketAppLifecycleError.storageFailure
        }
    }

    deinit {
        for pending in pendingApprovals.values where pending.disposableStaging {
            let stagingParent = pending.stagingDirectory.deletingLastPathComponent()
            Self.liveStagingRegistry.remove(stagingParent.standardizedFileURL.path)
            try? FileManager.default.removeItem(at: stagingParent)
        }
    }

    func stage(draftDirectory: URL, now: Date = Date()) throws -> PocketAppLifecycleProposal {
        var cleanupDirectory: URL?
        do {
            try purgeExpiredApprovals(now: now)
            guard Self.liveStagingRegistry.count(under: stagingRoot.standardizedFileURL.path) < maxPendingStagingSnapshots else {
                throw PocketAppLifecycleError.pendingLimitExceeded
            }
            let sourceSnapshot = try PocketAppFileSnapshot.capture(directory: draftDirectory)
            let stagingID = UUID().uuidString.lowercased()
            let stagingDirectory = stagingRoot
                .appendingPathComponent(stagingID, isDirectory: true)
                .appendingPathComponent("package", isDirectory: true)
            cleanupDirectory = stagingDirectory.deletingLastPathComponent()
            try sourceSnapshot.materialize(at: stagingDirectory)
            let stagedSnapshot = try PocketAppFileSnapshot.capture(directory: stagingDirectory)
            let package = try runtime.load(snapshot: stagedSnapshot)
            try requireSnapshotMatches(source: sourceSnapshot, staged: stagedSnapshot)
            try validateHostCompatibility(package)
            let previews = try makePreviews(package)
            let previewDigest = try Self.previewDigest(previews)
            let tests = try stagingTestRunner.run(package)
            let current = try readActiveRecord(packageID: package.manifest.id)
            try validateMigration(package: package, current: current)
            let action: PocketAppLifecycleAction = current == nil || current?.state == .removed ? .install : .update
            let currentPackage = try verifiedCurrentPackage(record: current)
            if let currentPackage,
               Self.compareSemanticVersions(package.manifest.version, currentPackage.manifest.version) == .orderedAscending {
                throw PocketAppLifecycleError.downgradeRequiresRollback
            }
            let targetPermissions = permissions(package)
            let currentEffectivePackage = current?.state == .enabled ? currentPackage : nil
            let currentPermissions = currentEffectivePackage.map(permissions) ?? Set<String>()
            let diff = permissionDiff(from: currentPermissions, to: targetPermissions)
            let grantDiff = capabilityGrantDiff(
                from: try currentEffectivePackage.map(capabilityGrants) ?? Set<String>(),
                to: try capabilityGrants(package)
            )
            let currentDigest = current.flatMap { $0.state == .removed ? nil : $0.packageDigest }
            let binding = Self.approvalBindingDigest(
                action: action,
                packageID: package.manifest.id,
                version: package.manifest.version,
                packageDigest: package.manifestDigest,
                currentDigest: currentDigest,
                currentState: current?.state,
                previewDigest: previewDigest,
                permissionDiff: diff,
                capabilityGrantDiff: grantDiff
            )
            let requestID = "install-approval:\(UUID().uuidString.lowercased())"
            let proposal = PocketAppLifecycleProposal(
                requestID: requestID,
                action: action,
                packageID: package.manifest.id,
                version: package.manifest.version,
                packageDigest: package.manifestDigest,
                currentDigest: currentDigest,
                currentState: current?.state,
                previewDigest: previewDigest,
                previews: previews,
                permissionDiff: diff,
                capabilityGrantDiff: grantDiff,
                tests: tests,
                bindingDigest: binding,
                createdAt: now,
                expiresAt: now.addingTimeInterval(approvalLifetime),
                approvalRequired: true,
                stagingDirectory: stagingDirectory,
                stateSchemaDigest: package.stateSchemaDigest,
                statePropertyNames: package.statePropertyNames
            )
            pendingApprovals[requestID] = PendingApproval(
                bindingDigest: binding,
                expiresAt: proposal.expiresAt,
                stagingDirectory: stagingDirectory,
                disposableStaging: true
            )
            Self.liveStagingRegistry.insert(stagingDirectory.deletingLastPathComponent().standardizedFileURL.path)
            cleanupDirectory = nil
            return proposal
        } catch let error as PocketAppLifecycleError {
            if let cleanupDirectory { try? FileManager.default.removeItem(at: cleanupDirectory) }
            throw error
        } catch {
            if let cleanupDirectory { try? FileManager.default.removeItem(at: cleanupDirectory) }
            throw PocketAppLifecycleError.invalidPackage
        }
    }

    func approve(
        requestID: String,
        bindingDigest: String,
        now: Date = Date()
    ) throws -> PocketAppLifecycleApprovalGrant {
        guard !decidedRequests.contains(requestID),
              let pending = pendingApprovals[requestID],
              pending.bindingDigest == bindingDigest else {
            throw PocketAppLifecycleError.approvalInvalid
        }
        guard now <= pending.expiresAt else {
            try discardPendingApproval(requestID: requestID, pending: pending)
            throw PocketAppLifecycleError.approvalExpired
        }
        decidedRequests.insert(requestID)
        let token = "install-grant:\(UUID().uuidString.lowercased())"
        grants[token] = IssuedApproval(
            requestID: requestID,
            bindingDigest: bindingDigest,
            expiresAt: pending.expiresAt
        )
        return PocketAppLifecycleApprovalGrant(token: token)
    }

    func reject(requestID: String, bindingDigest: String) throws {
        guard let pending = pendingApprovals[requestID],
              pending.bindingDigest == bindingDigest else {
            throw PocketAppLifecycleError.approvalInvalid
        }
        try discardPendingApproval(requestID: requestID, pending: pending)
    }

    func install(
        _ proposal: PocketAppLifecycleProposal,
        approvalGrant: PocketAppLifecycleApprovalGrant?,
        now: Date = Date()
    ) throws -> PocketAppLifecycleReceipt {
        try activateProposal(proposal, approvalGrant: approvalGrant, now: now)
    }

    func prepareRollback(
        packageID: String,
        version: String,
        now: Date = Date()
    ) throws -> PocketAppLifecycleProposal {
        guard Self.validPackageID(packageID), Self.validVersion(version) else { throw PocketAppLifecycleError.invalidPackage }
        let current = try readActiveRecord(packageID: packageID)
        guard let current, current.state != .removed else { throw PocketAppLifecycleError.invalidPackage }
        let targetDirectory = try uniqueVersionDirectory(packageID: packageID, version: version)
        let targetPackage = try verifiedInstalledPackage(at: targetDirectory)
        guard targetPackage.manifest.id == packageID,
              targetPackage.manifest.version == version,
              targetDirectory.deletingLastPathComponent().lastPathComponent
                == String(targetPackage.manifestDigest.dropFirst("sha256:".count)) else {
            throw PocketAppLifecycleError.corruptVersion
        }
        try validateHostCompatibility(targetPackage)
        let currentPackage = try verifiedCurrentPackage(record: current)
        guard let currentPackage,
              Self.compareSemanticVersions(targetPackage.manifest.version, currentPackage.manifest.version) == .orderedAscending else {
            throw PocketAppLifecycleError.invalidPackage
        }
        try validateMigration(package: targetPackage, current: current)
        let previews = try makePreviews(targetPackage)
        let previewDigest = try Self.previewDigest(previews)
        let currentEffectivePackage = current.state == .enabled ? currentPackage : nil
        let diff = permissionDiff(
            from: currentEffectivePackage.map(permissions) ?? Set<String>(),
            to: permissions(targetPackage)
        )
        let grantDiff = capabilityGrantDiff(
            from: try currentEffectivePackage.map(capabilityGrants) ?? Set<String>(),
            to: try capabilityGrants(targetPackage)
        )
        let binding = Self.approvalBindingDigest(
            action: .rollback,
            packageID: packageID,
            version: targetPackage.manifest.version,
            packageDigest: targetPackage.manifestDigest,
            currentDigest: current.packageDigest,
            currentState: current.state,
            previewDigest: previewDigest,
            permissionDiff: diff,
            capabilityGrantDiff: grantDiff
        )
        let requestID = "rollback-approval:\(UUID().uuidString.lowercased())"
        let proposal = PocketAppLifecycleProposal(
            requestID: requestID,
            action: .rollback,
            packageID: packageID,
            version: targetPackage.manifest.version,
            packageDigest: targetPackage.manifestDigest,
            currentDigest: current.packageDigest,
            currentState: current.state,
            previewDigest: previewDigest,
            previews: previews,
            permissionDiff: diff,
            capabilityGrantDiff: grantDiff,
            tests: try stagingTestRunner.run(targetPackage),
            bindingDigest: binding,
            createdAt: now,
            expiresAt: now.addingTimeInterval(approvalLifetime),
            approvalRequired: true,
            stagingDirectory: targetDirectory,
            stateSchemaDigest: targetPackage.stateSchemaDigest,
            statePropertyNames: targetPackage.statePropertyNames
        )
        pendingApprovals[requestID] = PendingApproval(
            bindingDigest: binding,
            expiresAt: proposal.expiresAt,
            stagingDirectory: targetDirectory,
            disposableStaging: false
        )
        return proposal
    }

    func rollback(
        _ proposal: PocketAppLifecycleProposal,
        approvalGrant: PocketAppLifecycleApprovalGrant?,
        now: Date = Date()
    ) throws -> PocketAppLifecycleReceipt {
        guard proposal.action == .rollback else { throw PocketAppLifecycleError.invalidPackage }
        return try activateProposal(proposal, approvalGrant: approvalGrant, now: now)
    }

    func disable(packageID: String, now: Date = Date()) throws -> PocketAppLifecycleReceipt {
        guard var current = try readActiveRecord(packageID: packageID), current.state != .removed else {
            throw PocketAppLifecycleError.invalidPackage
        }
        current = ActiveRecord(
            packageID: packageID,
            version: current.version,
            packageDigest: current.packageDigest,
            permissions: current.permissions,
            stateSchemaDigest: current.stateSchemaDigest,
            statePropertyNames: current.statePropertyNames,
            state: .disabled,
            updatedAt: now
        )
        try writeAndVerify(record: current)
        return try verifyActivationReadback(PocketAppLifecycleReceipt(
            action: "disable",
            packageID: packageID,
            version: current.version,
            packageDigest: current.packageDigest,
            effectivePermissions: [],
            state: .disabled,
            readbackVerified: true,
            dataDisposition: nil
        ))
    }

    func enable(packageID: String, now: Date = Date()) throws -> PocketAppLifecycleReceipt {
        guard let current = try readActiveRecord(packageID: packageID),
              current.state == .disabled,
              let version = current.version,
              let digest = current.packageDigest else {
            throw PocketAppLifecycleError.invalidPackage
        }
        let package = try verifiedInstalledPackage(
            at: installedPackageDirectory(packageID: packageID, version: version, digest: digest)
        )
        guard package.manifest.id == packageID,
              package.manifest.version == version,
              package.manifestDigest == digest,
              current.permissions == permissions(package).sorted(),
              current.stateSchemaDigest == package.stateSchemaDigest,
              current.statePropertyNames == package.statePropertyNames.sorted() else {
            throw PocketAppLifecycleError.corruptVersion
        }
        try validateHostCompatibility(package)
        let enabled = ActiveRecord(
            packageID: packageID,
            version: version,
            packageDigest: digest,
            permissions: current.permissions,
            stateSchemaDigest: current.stateSchemaDigest,
            statePropertyNames: current.statePropertyNames,
            state: .enabled,
            updatedAt: now
        )
        do {
            try writeAndVerify(record: enabled)
            if failureInjection?("enable_readback") == true {
                throw PocketAppLifecycleError.readbackFailed
            }
            guard try activePackage(packageID: packageID)?.manifestDigest == digest else {
                throw PocketAppLifecycleError.readbackFailed
            }
        } catch {
            do {
                try writeAndVerify(record: current)
            } catch {
                throw PocketAppLifecycleError.readbackFailed
            }
            throw error
        }
        let receipt = PocketAppLifecycleReceipt(
            action: "enable",
            packageID: packageID,
            version: version,
            packageDigest: digest,
            effectivePermissions: current.permissions,
            state: .enabled,
            readbackVerified: true,
            dataDisposition: nil
        )
        do {
            return try verifyActivationReadback(receipt)
        } catch {
            try? recoverAfterActivationFailure(
                previous: current,
                committed: enabled,
                now: now
            )
            throw PocketAppLifecycleError.readbackFailed
        }
    }

    func remove(
        packageID: String,
        dataDisposition: PocketAppDataDisposition,
        now: Date = Date()
    ) throws -> PocketAppLifecycleReceipt {
        guard Self.validPackageID(packageID) else { throw PocketAppLifecycleError.invalidPackage }
        guard dataDisposition == .preserve else { throw PocketAppLifecycleError.approvalRequired }
        let previous = try readActiveRecord(packageID: packageID)
        let removed = ActiveRecord(
            packageID: packageID,
            version: nil,
            packageDigest: nil,
            permissions: [],
            stateSchemaDigest: previous?.stateSchemaDigest,
            statePropertyNames: previous?.statePropertyNames ?? [],
            state: .removed,
            updatedAt: now
        )
        let versions = versionsRoot(packageID: packageID)
        let tombstone = appRoot(packageID: packageID)
            .appendingPathComponent(".removed-Versions-\(UUID().uuidString.lowercased())", isDirectory: true)
        var movedVersions = false
        do {
            if FileManager.default.fileExists(atPath: versions.path) {
                if failureInjection?("remove_stage") == true { throw PocketAppLifecycleError.storageFailure }
                try FileManager.default.moveItem(at: versions, to: tombstone)
                movedVersions = true
            }
            try writeAndVerify(record: removed)
        } catch {
            if movedVersions,
               FileManager.default.fileExists(atPath: tombstone.path),
               !FileManager.default.fileExists(atPath: versions.path) {
                try? FileManager.default.moveItem(at: tombstone, to: versions)
            }
            do {
                if FileManager.default.fileExists(atPath: versions.path) {
                    try makeImmutable(directory: versions)
                    try verifyImmutable(directory: versions)
                }
                try restore(record: previous, packageID: packageID)
            } catch {}
            throw PocketAppLifecycleError.storageFailure
        }
        if movedVersions {
            try? makeMutable(directory: tombstone)
            try? FileManager.default.removeItem(at: tombstone)
        }
        guard try readActiveRecord(packageID: packageID)?.state == .removed,
              !FileManager.default.fileExists(atPath: versions.path) else {
            throw PocketAppLifecycleError.readbackFailed
        }
        return try verifyActivationReadback(PocketAppLifecycleReceipt(
            action: "remove",
            packageID: packageID,
            version: nil,
            packageDigest: nil,
            effectivePermissions: [],
            state: .removed,
            readbackVerified: true,
            dataDisposition: dataDisposition
        ))
    }

    func managedPackages() throws -> [PocketAppManagedPackage] {
        guard FileManager.default.fileExists(atPath: appsRoot.path) else { return [] }
        return try safeChildDirectories(of: appsRoot).compactMap { directory in
            let packageID = directory.lastPathComponent
            guard Self.validPackageID(packageID) else { throw PocketAppLifecycleError.corruptVersion }
            return try managedPackage(packageID: packageID)
        }.sorted { $0.packageID < $1.packageID }
    }

    func managementSnapshot() throws -> PocketAppManagementSnapshot {
        guard FileManager.default.fileExists(atPath: appsRoot.path) else {
            return PocketAppManagementSnapshot(packages: [], issues: [])
        }
        var packages: [PocketAppManagedPackage] = []
        var issues: [PocketAppManagementIssue] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = try FileManager.default.contentsOfDirectory(
            at: appsRoot,
            includingPropertiesForKeys: Array(keys),
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for directory in entries {
            let packageID = directory.lastPathComponent
            guard Self.validPackageID(packageID) else {
                throw PocketAppLifecycleError.corruptVersion
            }
            do {
                let values = try directory.resourceValues(forKeys: keys)
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw PocketAppLifecycleError.corruptVersion
                }
                if let package = try managedPackage(packageID: packageID) {
                    packages.append(package)
                }
            } catch {
                let removalAllowed: Bool
                do {
                    _ = try readActiveRecord(packageID: packageID)
                    removalAllowed = true
                } catch {
                    removalAllowed = false
                }
                issues.append(PocketAppManagementIssue(
                    packageID: packageID,
                    errorCode: "LIFECYCLE_PACKAGE_CORRUPT",
                    removalAllowed: removalAllowed
                ))
            }
        }
        return PocketAppManagementSnapshot(
            packages: packages.sorted { $0.packageID < $1.packageID },
            issues: issues.sorted { $0.packageID < $1.packageID }
        )
    }

    func managedPackage(packageID: String) throws -> PocketAppManagedPackage? {
        guard Self.validPackageID(packageID) else { throw PocketAppLifecycleError.invalidPackage }
        guard let record = try readActiveRecord(packageID: packageID) else { return nil }
        if record.state == .removed {
            return PocketAppManagedPackage(
                packageID: packageID,
                state: .removed,
                version: nil,
                packageDigest: nil,
                installedVersions: []
            )
        }
        guard let version = record.version, let digest = record.packageDigest else {
            throw PocketAppLifecycleError.readbackFailed
        }
        let package = try verifiedInstalledPackage(
            at: installedPackageDirectory(packageID: packageID, version: version, digest: digest)
        )
        guard package.manifest.id == packageID,
              package.manifest.version == version,
              package.manifestDigest == digest else {
            throw PocketAppLifecycleError.corruptVersion
        }
        return PocketAppManagedPackage(
            packageID: packageID,
            state: record.state,
            version: version,
            packageDigest: digest,
            installedVersions: try installedVersions(packageID: packageID)
        )
    }

    func durableManagedPackage(packageID: String) throws -> PocketAppManagedPackage? {
        guard Self.validPackageID(packageID) else { throw PocketAppLifecycleError.invalidPackage }
        guard let record = try readActiveRecord(packageID: packageID) else { return nil }
        return PocketAppManagedPackage(
            packageID: packageID,
            state: record.state,
            version: record.state == .removed ? nil : record.version,
            packageDigest: record.state == .removed ? nil : record.packageDigest,
            installedVersions: []
        )
    }

    private func installedVersions(packageID: String) throws -> [String] {
        let root = versionsRoot(packageID: packageID)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var versions: Set<String> = []
        for versionDirectory in try safeChildDirectories(of: root) {
            for digestDirectory in try safeChildDirectories(of: versionDirectory)
                where !digestDirectory.lastPathComponent.hasPrefix(".installing-") {
                try verifyImmutable(directory: digestDirectory)
                let package = try verifiedInstalledPackage(
                    at: digestDirectory.appendingPathComponent("package", isDirectory: true)
                )
                guard package.manifest.id == packageID else {
                    throw PocketAppLifecycleError.corruptVersion
                }
                versions.insert(package.manifest.version)
            }
        }
        return versions.sorted { Self.compareSemanticVersions($0, $1) == .orderedAscending }
    }

    func activePackage(packageID: String) throws -> PocketAppPackage? {
        guard let record = try readActiveRecord(packageID: packageID), record.state == .enabled else { return nil }
        guard let version = record.version, let digest = record.packageDigest else {
            throw PocketAppLifecycleError.readbackFailed
        }
        let directory = installedPackageDirectory(packageID: packageID, version: version, digest: digest)
        let package = try verifiedInstalledPackage(at: directory)
        guard package.manifest.id == packageID,
              package.manifest.version == version,
              package.manifestDigest == digest else {
            throw PocketAppLifecycleError.corruptVersion
        }
        try validateHostCompatibility(package)
        return package
    }

    func activePackageForActivation(packageID: String) throws -> PocketAppPackage? {
        guard let package = try activePackage(packageID: packageID),
              let record = try readActiveRecord(packageID: packageID) else { return nil }
        guard permissions(package).sorted() == record.permissions.sorted() else {
            throw PocketAppLifecycleError.corruptVersion
        }
        return package
    }

    private func activateProposal(
        _ proposal: PocketAppLifecycleProposal,
        approvalGrant: PocketAppLifecycleApprovalGrant?,
        now: Date
    ) throws -> PocketAppLifecycleReceipt {
        guard let pending = pendingApprovals[proposal.requestID],
              pending.bindingDigest == proposal.bindingDigest,
              pending.expiresAt == proposal.expiresAt,
              pending.stagingDirectory == proposal.stagingDirectory else {
            throw PocketAppLifecycleError.approvalInvalid
        }
        guard now <= proposal.expiresAt else {
            try discardPendingApproval(requestID: proposal.requestID, pending: pending)
            throw PocketAppLifecycleError.approvalExpired
        }
        let current = try readActiveRecord(packageID: proposal.packageID)
        let currentDigest = current.flatMap { $0.state == .removed ? nil : $0.packageDigest }
        guard currentDigest == proposal.currentDigest,
              current?.state == proposal.currentState else {
            throw PocketAppLifecycleError.activeChanged
        }

        let sourceSnapshot = try PocketAppFileSnapshot.capture(directory: proposal.stagingDirectory)
        let package = try runtime.load(snapshot: sourceSnapshot)
        guard package.manifest.id == proposal.packageID,
              package.manifest.version == proposal.version,
              package.manifestDigest == proposal.packageDigest,
              package.stateSchemaDigest == proposal.stateSchemaDigest,
              package.statePropertyNames == proposal.statePropertyNames else {
            throw PocketAppLifecycleError.packageChanged
        }
        try validateHostCompatibility(package)
        guard try Self.previewDigest(proposal.previews) == proposal.previewDigest else {
            throw PocketAppLifecycleError.packageChanged
        }
        let previews = try makePreviews(package)
        guard try Self.previewDigest(previews) == proposal.previewDigest else {
            throw PocketAppLifecycleError.packageChanged
        }
        guard try stagingTestRunner.run(package) == proposal.tests else {
            throw PocketAppLifecycleError.packageChanged
        }
        try validateMigration(package: package, current: current)
        let currentPackage = try verifiedCurrentPackage(record: current)
        let currentEffectivePackage = current?.state == .enabled ? currentPackage : nil
        let currentPermissions = currentEffectivePackage.map(permissions) ?? Set<String>()
        let observedDiff = permissionDiff(from: currentPermissions, to: permissions(package))
        let observedGrantDiff = capabilityGrantDiff(
            from: try currentEffectivePackage.map(capabilityGrants) ?? Set<String>(),
            to: try capabilityGrants(package)
        )
        guard observedDiff == proposal.permissionDiff,
              observedGrantDiff == proposal.capabilityGrantDiff,
              proposal.approvalRequired else {
            throw PocketAppLifecycleError.permissionChanged
        }
        let observedBinding = Self.approvalBindingDigest(
            action: proposal.action,
            packageID: proposal.packageID,
            version: proposal.version,
            packageDigest: proposal.packageDigest,
            currentDigest: proposal.currentDigest,
            currentState: proposal.currentState,
            previewDigest: proposal.previewDigest,
            permissionDiff: observedDiff,
            capabilityGrantDiff: observedGrantDiff
        )
        guard observedBinding == proposal.bindingDigest else { throw PocketAppLifecycleError.approvalInvalid }
        guard let approvalGrant else { throw PocketAppLifecycleError.approvalRequired }
        try consume(
            approvalGrant,
            requestID: proposal.requestID,
            bindingDigest: proposal.bindingDigest,
            now: now
        )

        let targetDirectory: URL
        if proposal.action == .rollback {
            targetDirectory = proposal.stagingDirectory
            let snapshotRoot = targetDirectory.deletingLastPathComponent()
            let verified = try verifiedInstalledPackage(at: targetDirectory)
            guard verified.manifestDigest == proposal.packageDigest else { throw PocketAppLifecycleError.corruptVersion }
            try makeImmutable(directory: snapshotRoot)
            try verifyImmutable(directory: snapshotRoot)
            let hardened = try verifiedInstalledPackage(at: targetDirectory)
            guard hardened.manifestDigest == proposal.packageDigest else { throw PocketAppLifecycleError.readbackFailed }
            try verifyImmutable(directory: snapshotRoot)
        } else {
            targetDirectory = try installImmutableSnapshot(sourceSnapshot, package: package)
        }
        let previous = current
        let record = ActiveRecord(
            packageID: proposal.packageID,
            version: proposal.version,
            packageDigest: proposal.packageDigest,
            permissions: permissions(package).sorted(),
            stateSchemaDigest: package.stateSchemaDigest,
            statePropertyNames: package.statePropertyNames.sorted(),
            state: .enabled,
            updatedAt: now
        )
        do {
            try writeAndVerify(record: record)
            let readback = try verifiedInstalledPackage(at: targetDirectory)
            guard readback.manifest.id == record.packageID,
                  readback.manifest.version == record.version,
                  readback.manifestDigest == record.packageDigest else {
                throw PocketAppLifecycleError.readbackFailed
            }
        } catch {
            try? restore(record: previous, packageID: proposal.packageID)
            throw error
        }
        if proposal.action != .rollback {
            let stagingParent = proposal.stagingDirectory.deletingLastPathComponent()
            Self.liveStagingRegistry.remove(stagingParent.standardizedFileURL.path)
            try? FileManager.default.removeItem(at: stagingParent)
        }
        pendingApprovals.removeValue(forKey: proposal.requestID)
        decidedRequests.remove(proposal.requestID)
        let receipt = PocketAppLifecycleReceipt(
            action: proposal.action.rawValue,
            packageID: proposal.packageID,
            version: proposal.version,
            packageDigest: proposal.packageDigest,
            effectivePermissions: permissions(package).sorted(),
            state: .enabled,
            readbackVerified: true,
            dataDisposition: nil
        )
        do {
            return try verifyActivationReadback(receipt)
        } catch {
            try? recoverAfterActivationFailure(
                previous: previous,
                committed: record,
                now: now
            )
            throw PocketAppLifecycleError.readbackFailed
        }
    }

    private func recoverAfterActivationFailure(
        previous: ActiveRecord?,
        committed: ActiveRecord,
        now: Date
    ) throws {
        let fallbackSource = previous ?? committed
        let fallback: ActiveRecord
        if fallbackSource.state == .removed {
            fallback = fallbackSource
        } else {
            fallback = ActiveRecord(
                packageID: fallbackSource.packageID,
                version: fallbackSource.version,
                packageDigest: fallbackSource.packageDigest,
                permissions: fallbackSource.permissions,
                stateSchemaDigest: fallbackSource.stateSchemaDigest,
                statePropertyNames: fallbackSource.statePropertyNames,
                state: .disabled,
                updatedAt: now
            )
        }
        try writeAndVerify(record: fallback)
        guard let activationReadback else { return }
        let recoveryReceipt = PocketAppLifecycleReceipt(
            action: "activation_failure_recovery",
            packageID: fallback.packageID,
            version: fallback.version,
            packageDigest: fallback.packageDigest,
            effectivePermissions: [],
            state: fallback.state,
            readbackVerified: true,
            dataDisposition: fallback.state == .removed ? .preserve : nil
        )
        _ = try? activationReadback(recoveryReceipt)
    }

    private func verifyActivationReadback(
        _ receipt: PocketAppLifecycleReceipt
    ) throws -> PocketAppLifecycleReceipt {
        guard let activationReadback else { return receipt }
        do {
            let observed = try activationReadback(receipt)
            guard observed.matches(receipt) else {
                throw PocketAppLifecycleError.readbackFailed
            }
            return receipt
        } catch {
            throw PocketAppLifecycleError.readbackFailed
        }
    }

    private func installImmutableSnapshot(
        _ snapshot: PocketAppFileSnapshot,
        package: PocketAppPackage
    ) throws -> URL {
        let versionRoot = versionsRoot(packageID: package.manifest.id)
            .appendingPathComponent(Self.versionStorageKey(package.manifest.version), isDirectory: true)
        try FileManager.default.createDirectory(
            at: versionRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let digestName = String(package.manifestDigest.dropFirst("sha256:".count))
        let finalRoot = versionRoot.appendingPathComponent(digestName, isDirectory: true)
        let finalPackage = finalRoot.appendingPathComponent("package", isDirectory: true)
        let existing = try FileManager.default.contentsOfDirectory(at: versionRoot, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".installing-") }
        if !existing.isEmpty {
            guard existing.count == 1, existing[0].lastPathComponent == digestName else {
                throw PocketAppLifecycleError.versionConflict
            }
            let installed = try verifiedInstalledPackage(at: finalPackage)
            guard installed.manifestDigest == package.manifestDigest else {
                throw PocketAppLifecycleError.corruptVersion
            }
            try makeImmutable(directory: finalRoot)
            try verifyImmutable(directory: finalRoot)
            let hardened = try verifiedInstalledPackage(at: finalPackage)
            guard hardened.manifestDigest == package.manifestDigest else {
                throw PocketAppLifecycleError.readbackFailed
            }
            try durablySynchronizeInstalledSnapshot(
                finalRoot: finalRoot,
                versionRoot: versionRoot,
                packageID: package.manifest.id
            )
            return finalPackage
        }

        let temporaryRoot = versionRoot.appendingPathComponent(".installing-\(UUID().uuidString.lowercased())", isDirectory: true)
        let temporaryPackage = temporaryRoot.appendingPathComponent("package", isDirectory: true)
        var movedToFinal = false
        do {
            if failureInjection?("snapshot_write") == true { throw PocketAppLifecycleError.storageFailure }
            try snapshot.materialize(at: temporaryPackage)
            let installedSnapshot = try PocketAppFileSnapshot.capture(directory: temporaryPackage)
            let installed = try runtime.load(snapshot: installedSnapshot)
            guard installed.manifest.id == package.manifest.id,
                  installed.manifest.version == package.manifest.version,
                  installed.manifestDigest == package.manifestDigest else {
                throw PocketAppLifecycleError.packageChanged
            }
            try FileManager.default.moveItem(at: temporaryRoot, to: finalRoot)
            movedToFinal = true
            try makeImmutable(directory: finalRoot)
            try verifyImmutable(directory: finalRoot)
            let readback = try verifiedInstalledPackage(at: finalPackage)
            guard readback.manifestDigest == package.manifestDigest else {
                throw PocketAppLifecycleError.readbackFailed
            }
            try durablySynchronizeInstalledSnapshot(
                finalRoot: finalRoot,
                versionRoot: versionRoot,
                packageID: package.manifest.id
            )
            return finalPackage
        } catch {
            let cleanupRoot = movedToFinal ? finalRoot : temporaryRoot
            try? makeMutable(directory: cleanupRoot)
            try? FileManager.default.removeItem(at: cleanupRoot)
            throw error
        }
    }

    private func verifiedInstalledPackage(at directory: URL) throws -> PocketAppPackage {
        do {
            return try runtime.load(snapshot: PocketAppFileSnapshot.capture(directory: directory))
        } catch {
            throw PocketAppLifecycleError.corruptVersion
        }
    }

    private func validateMigration(package: PocketAppPackage, current: ActiveRecord?) throws {
        guard let current else { return }
        let preservedData = FileManager.default.fileExists(
            atPath: userDataRoot.appendingPathComponent(package.manifest.id, isDirectory: true).path
        )
        guard current.state != .removed || preservedData else { return }
        guard current.stateSchemaDigest == package.stateSchemaDigest,
              Set(current.statePropertyNames) == package.statePropertyNames else {
            throw PocketAppLifecycleError.migrationRequired
        }
    }

    private func validateHostCompatibility(_ package: PocketAppPackage) throws {
        guard Self.compareSemanticVersions(package.manifest.minimumHostVersion, hostVersion) != .orderedDescending else {
            throw PocketAppLifecycleError.hostVersionUnsupported
        }
    }

    private func purgeExpiredApprovals(now: Date) throws {
        let expired = pendingApprovals.filter { now > $0.value.expiresAt }
        for (requestID, pending) in expired {
            try discardPendingApproval(requestID: requestID, pending: pending)
        }
        let orphanedTokens = grants.compactMap { token, issued in
            now > issued.expiresAt ? token : nil
        }
        for token in orphanedTokens {
            grants.removeValue(forKey: token)
            consumedGrants.remove(token)
        }
    }

    private func discardPendingApproval(requestID: String, pending: PendingApproval) throws {
        if pending.disposableStaging {
            let stagingParent = pending.stagingDirectory.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: stagingParent.path) {
                do {
                    try FileManager.default.removeItem(at: stagingParent)
                } catch {
                    throw PocketAppLifecycleError.storageFailure
                }
            }
            Self.liveStagingRegistry.remove(stagingParent.standardizedFileURL.path)
        }
        pendingApprovals.removeValue(forKey: requestID)
        decidedRequests.remove(requestID)
        let issuedTokens = grants.compactMap { token, issued in
            issued.requestID == requestID ? token : nil
        }
        for token in issuedTokens {
            grants.removeValue(forKey: token)
            consumedGrants.remove(token)
        }
    }

    private func consume(
        _ grant: PocketAppLifecycleApprovalGrant,
        requestID: String,
        bindingDigest: String,
        now: Date
    ) throws {
        guard !consumedGrants.contains(grant.token) else { throw PocketAppLifecycleError.approvalReplayed }
        guard let issued = grants[grant.token],
              issued.requestID == requestID,
              issued.bindingDigest == bindingDigest else {
            throw PocketAppLifecycleError.approvalInvalid
        }
        grants.removeValue(forKey: grant.token)
        consumedGrants.insert(grant.token)
        guard now <= issued.expiresAt else { throw PocketAppLifecycleError.approvalExpired }
    }

    private func makePreviews(_ package: PocketAppPackage) throws -> [PocketAppPreviewSurface] {
        try package.surfaces.keys.sorted().map { id in
            guard let surface = package.surfaces[id] else { throw PocketAppLifecycleError.invalidPackage }
            let data = try surface.canonicalRenderModelData()
            let repeated = try surface.canonicalRenderModelData()
            guard data == repeated else { throw PocketAppLifecycleError.packageChanged }
            return PocketAppPreviewSurface(
                id: id,
                renderDigest: Self.sha256(data),
                canonicalRenderModel: data
            )
        }
    }

    private func permissions(_ package: PocketAppPackage) -> Set<String> {
        package.manifest.requestedCapabilities.reduce(into: Set<String>()) { result, request in
            result.formUnion(request.permissions)
        }
    }

    private func capabilityGrants(_ package: PocketAppPackage) throws -> Set<String> {
        try Set(package.manifest.requestedCapabilities.map { request in
            let object: [String: Any] = [
                "capabilityId": request.key.id,
                "capabilityVersion": request.key.version,
                "effect": request.effect.rawValue,
                "permissions": request.permissions.sorted(),
                "scope": request.scope?.foundationValue ?? NSNull()
            ]
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            guard let value = String(data: data, encoding: .utf8) else {
                throw PocketAppLifecycleError.invalidPackage
            }
            return value
        })
    }

    private func permissionDiff(from current: Set<String>, to target: Set<String>) -> PocketAppPermissionDiff {
        PocketAppPermissionDiff(
            added: target.subtracting(current).sorted(),
            removed: current.subtracting(target).sorted()
        )
    }

    private func capabilityGrantDiff(
        from current: Set<String>,
        to target: Set<String>
    ) -> PocketAppCapabilityGrantDiff {
        PocketAppCapabilityGrantDiff(
            added: target.subtracting(current).sorted(),
            removed: current.subtracting(target).sorted()
        )
    }

    private func verifiedCurrentPackage(record: ActiveRecord?) throws -> PocketAppPackage? {
        guard let record, record.state != .removed else { return nil }
        guard let version = record.version, let digest = record.packageDigest else {
            throw PocketAppLifecycleError.readbackFailed
        }
        let package = try verifiedInstalledPackage(
            at: installedPackageDirectory(packageID: record.packageID, version: version, digest: digest)
        )
        guard package.manifest.id == record.packageID,
              package.manifest.version == version,
              package.manifestDigest == digest else {
            throw PocketAppLifecycleError.corruptVersion
        }
        return package
    }

    private func requireSnapshotMatches(
        source: PocketAppFileSnapshot,
        staged: PocketAppFileSnapshot
    ) throws {
        guard Set(source.files.keys) == Set(staged.files.keys),
              source.files.allSatisfy({ staged.files[$0.key] == $0.value }) else {
            throw PocketAppLifecycleError.packageChanged
        }
    }

    private func writeAndVerify(record: ActiveRecord) throws {
        try write(record: record)
        guard let observed = try readActiveRecord(packageID: record.packageID),
              Self.activeRecordEquivalent(observed, record) else {
            throw PocketAppLifecycleError.readbackFailed
        }
    }

    private func write(record: ActiveRecord) throws {
        if failureInjection?("active_write") == true { throw PocketAppLifecycleError.storageFailure }
        let directory = appRoot(packageID: record.packageID)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(record)
            let activeRecordURL = activeRecordURL(packageID: record.packageID)
            try data.write(to: activeRecordURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: activeRecordURL.path
            )
            try Self.durablySynchronize(file: activeRecordURL, parentDirectory: directory)
        } catch {
            throw PocketAppLifecycleError.storageFailure
        }
    }

    private static func durablySynchronize(file: URL, parentDirectory: URL) throws {
        let fileDescriptor = open(file.path, O_RDONLY)
        guard fileDescriptor >= 0 else { throw PocketAppLifecycleError.storageFailure }
        defer { close(fileDescriptor) }
        guard fsync(fileDescriptor) == 0 else { throw PocketAppLifecycleError.storageFailure }

        let directoryDescriptor = open(parentDirectory.path, O_RDONLY)
        guard directoryDescriptor >= 0 else { throw PocketAppLifecycleError.storageFailure }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else { throw PocketAppLifecycleError.storageFailure }
    }

    private func durablySynchronizeInstalledSnapshot(
        finalRoot: URL,
        versionRoot: URL,
        packageID: String
    ) throws {
        if failureInjection?("snapshot_sync") == true { throw PocketAppLifecycleError.storageFailure }
        try ensureNoSymlinks(in: finalRoot)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: finalRoot,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            throw PocketAppLifecycleError.storageFailure
        }
        var files: [URL] = []
        var directories: [URL] = [finalRoot]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw PocketAppLifecycleError.storageFailure }
            if values.isDirectory == true {
                directories.append(url)
            } else if values.isRegularFile == true {
                files.append(url)
            } else {
                throw PocketAppLifecycleError.storageFailure
            }
        }
        for file in files.sorted(by: { $0.path < $1.path }) {
            try Self.durablySynchronize(node: file, isDirectory: false)
        }
        for directory in directories.sorted(by: {
            $0.pathComponents.count == $1.pathComponents.count
                ? $0.path > $1.path
                : $0.pathComponents.count > $1.pathComponents.count
        }) {
            try Self.durablySynchronize(node: directory, isDirectory: true)
        }
        for directory in [
            versionRoot,
            versionsRoot(packageID: packageID),
            appRoot(packageID: packageID),
            appsRoot,
            rootDirectory
        ] {
            try Self.durablySynchronize(node: directory, isDirectory: true)
        }
    }

    private static func durablySynchronize(node: URL, isDirectory: Bool) throws {
        var flags = O_RDONLY | O_NOFOLLOW
        if isDirectory { flags |= O_DIRECTORY }
        let descriptor = open(node.path, flags)
        guard descriptor >= 0 else { throw PocketAppLifecycleError.storageFailure }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw PocketAppLifecycleError.storageFailure }
    }

    private func restore(record: ActiveRecord?, packageID: String) throws {
        if let record {
            try write(record: record)
        } else {
            let url = activeRecordURL(packageID: packageID)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func readActiveRecord(packageID: String) throws -> ActiveRecord? {
        guard Self.validPackageID(packageID) else { throw PocketAppLifecycleError.invalidPackage }
        let url = activeRecordURL(packageID: packageID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let relativePath = "Apps/\(packageID)/active.json"
            let data = try PocketAppFileSnapshot.readFileNoFollow(
                rootDirectory: rootDirectory,
                relativePath: relativePath,
                maximumBytes: 64 * 1_024
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let record = try decoder.decode(ActiveRecord.self, from: data)
            let activeShapeValid = record.state == .removed
                ? record.version == nil && record.packageDigest == nil && record.permissions.isEmpty
                : record.version.map(Self.validVersion) == true
                    && record.packageDigest.map(Self.validDigest) == true
                    && record.stateSchemaDigest.map(Self.validDigest) == true
            guard record.recordVersion == 1, record.packageID == packageID,
                  activeShapeValid,
                  record.permissions == record.permissions.sorted(),
                  Set(record.permissions).count == record.permissions.count,
                  record.permissions.allSatisfy(Self.validPermission),
                  record.stateSchemaDigest.map(Self.validDigest) ?? true,
                  record.statePropertyNames == record.statePropertyNames.sorted(),
                  Set(record.statePropertyNames).count == record.statePropertyNames.count,
                  record.statePropertyNames.allSatisfy(Self.validStateProperty) else {
                throw PocketAppLifecycleError.readbackFailed
            }
            return record
        } catch let error as PocketAppLifecycleError {
            throw error
        } catch {
            throw PocketAppLifecycleError.readbackFailed
        }
    }

    private func uniqueVersionDirectory(packageID: String, version: String) throws -> URL {
        let versionRoot = versionsRoot(packageID: packageID)
            .appendingPathComponent(Self.versionStorageKey(version), isDirectory: true)
        let candidates = try FileManager.default.contentsOfDirectory(at: versionRoot, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".installing-") }
        guard candidates.count == 1 else { throw PocketAppLifecycleError.corruptVersion }
        return candidates[0].appendingPathComponent("package", isDirectory: true)
    }

    private func recoverInterruptedTransactions() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: stagingRoot.path) {
            try ensureNoSymlinks(in: stagingRoot)
            for stagingDirectory in try safeChildDirectories(of: stagingRoot)
                where !Self.liveStagingRegistry.contains(stagingDirectory.standardizedFileURL.path) {
                try fileManager.removeItem(at: stagingDirectory)
            }
        }
        try fileManager.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard fileManager.fileExists(atPath: appsRoot.path) else { return }
        for appDirectory in try safeChildDirectories(of: appsRoot) {
            let tombstones = try safeChildDirectories(of: appDirectory)
                .filter { $0.lastPathComponent.hasPrefix(".removed-Versions-") }
            if !tombstones.isEmpty {
                guard Self.validPackageID(appDirectory.lastPathComponent) else {
                    throw PocketAppLifecycleError.corruptVersion
                }
                let active = try readActiveRecord(packageID: appDirectory.lastPathComponent)
                let versions = appDirectory.appendingPathComponent("Versions", isDirectory: true)
                for tombstone in tombstones {
                    if active?.state == .removed {
                        try makeMutable(directory: tombstone)
                        try fileManager.removeItem(at: tombstone)
                    } else if tombstones.count == 1, !fileManager.fileExists(atPath: versions.path) {
                        try fileManager.moveItem(at: tombstone, to: versions)
                        try makeImmutable(directory: versions)
                        try verifyImmutable(directory: versions)
                    } else {
                        throw PocketAppLifecycleError.corruptVersion
                    }
                }
            }
            let versions = appDirectory.appendingPathComponent("Versions", isDirectory: true)
            guard fileManager.fileExists(atPath: versions.path) else { continue }
            for versionDirectory in try safeChildDirectories(of: versions) {
                for candidate in try safeChildDirectories(of: versionDirectory) {
                    if candidate.lastPathComponent.hasPrefix(".installing-") {
                        try makeMutable(directory: candidate)
                        try fileManager.removeItem(at: candidate)
                    } else {
                        try makeImmutable(directory: candidate)
                        try verifyImmutable(directory: candidate)
                    }
                }
            }
        }
    }

    private func safeChildDirectories(of directory: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        ).compactMap { url in
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw PocketAppLifecycleError.corruptVersion }
            return values.isDirectory == true ? url : nil
        }
    }

    private func ensureNoSymlinks(in directory: URL) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let rootValues = try directory.resourceValues(forKeys: keys)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw PocketAppLifecycleError.corruptVersion
        }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            throw PocketAppLifecycleError.storageFailure
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                throw PocketAppLifecycleError.corruptVersion
            }
        }
    }

    private func makeImmutable(directory: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try ensureNoSymlinks(in: directory)
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw PocketAppLifecycleError.storageFailure
        }
        var directories: [URL] = [directory]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                directories.append(url)
            } else {
                try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
            }
        }
        for url in directories.reversed() {
            try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.path)
        }
    }

    private func makeMutable(directory: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try ensureNoSymlinks(in: directory)
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw PocketAppLifecycleError.storageFailure
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            try fileManager.setAttributes(
                [.posixPermissions: values.isDirectory == true ? 0o700 : 0o600],
                ofItemAtPath: url.path
            )
        }
    }

    private func verifyImmutable(directory: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            throw PocketAppLifecycleError.readbackFailed
        }
        try ensureNoSymlinks(in: directory)
        let rootAttributes = try fileManager.attributesOfItem(atPath: directory.path)
        guard let rootPermissions = (rootAttributes[.posixPermissions] as? NSNumber)?.intValue,
              rootPermissions & 0o222 == 0 else {
            throw PocketAppLifecycleError.readbackFailed
        }
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw PocketAppLifecycleError.readbackFailed
        }
        for case let url as URL in enumerator {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
                  permissions & 0o222 == 0 else {
                throw PocketAppLifecycleError.readbackFailed
            }
        }
    }

    private var stagingRoot: URL { rootDirectory.appendingPathComponent("Staging", isDirectory: true) }
    private var appsRoot: URL { rootDirectory.appendingPathComponent("Apps", isDirectory: true) }
    private func appRoot(packageID: String) -> URL { appsRoot.appendingPathComponent(packageID, isDirectory: true) }
    private func versionsRoot(packageID: String) -> URL { appRoot(packageID: packageID).appendingPathComponent("Versions", isDirectory: true) }
    private func activeRecordURL(packageID: String) -> URL { appRoot(packageID: packageID).appendingPathComponent("active.json") }
    private func installedPackageDirectory(packageID: String, version: String, digest: String) -> URL {
        versionsRoot(packageID: packageID)
            .appendingPathComponent(Self.versionStorageKey(version), isDirectory: true)
            .appendingPathComponent(String(digest.dropFirst("sha256:".count)), isDirectory: true)
            .appendingPathComponent("package", isDirectory: true)
    }

    private static func versionStorageKey(_ version: String) -> String {
        "v-" + version.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private static func approvalBindingDigest(
        action: PocketAppLifecycleAction,
        packageID: String,
        version: String,
        packageDigest: String,
        currentDigest: String?,
        currentState: PocketAppLifecycleState?,
        previewDigest: String,
        permissionDiff: PocketAppPermissionDiff,
        capabilityGrantDiff: PocketAppCapabilityGrantDiff
    ) -> String {
        var hasher = SHA256()
        func field(_ value: String) {
            hasher.update(data: Data(value.utf8))
            hasher.update(data: Data([0]))
        }
        field("hoverpocket.lifecycle-approval/v2")
        field(action.rawValue)
        field(packageID)
        field(version)
        field(packageDigest)
        field(currentDigest ?? "none")
        field(currentState?.rawValue ?? "none")
        field(previewDigest)
        for item in permissionDiff.added.sorted() { field("+\(item)") }
        for item in permissionDiff.removed.sorted() { field("-\(item)") }
        for item in capabilityGrantDiff.added.sorted() { field("grant+:\(item)") }
        for item in capabilityGrantDiff.removed.sorted() { field("grant-:\(item)") }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func previewDigest(_ previews: [PocketAppPreviewSurface]) throws -> String {
        var hasher = SHA256()
        hasher.update(data: Data("hoverpocket.preview/v1\0".utf8))
        for preview in previews.sorted(by: { $0.id < $1.id }) {
            guard sha256(preview.canonicalRenderModel) == preview.renderDigest else {
                throw PocketAppLifecycleError.packageChanged
            }
            hasher.update(data: Data(preview.id.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(preview.renderDigest.utf8))
            hasher.update(data: Data([0]))
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func activeRecordEquivalent(_ lhs: ActiveRecord, _ rhs: ActiveRecord) -> Bool {
        lhs.recordVersion == rhs.recordVersion
            && lhs.packageID == rhs.packageID
            && lhs.version == rhs.version
            && lhs.packageDigest == rhs.packageDigest
            && lhs.permissions == rhs.permissions
            && lhs.stateSchemaDigest == rhs.stateSchemaDigest
            && lhs.statePropertyNames == rhs.statePropertyNames
            && lhs.state == rhs.state
    }

    private static func validVersion(_ value: String) -> Bool {
        value.unicodeScalars.count <= 64
            && value.range(
                of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$",
                options: .regularExpression
            ) != nil
    }

    static func compareSemanticVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func parsed(_ value: String) -> ([String], [String]?)? {
            let pieces = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let core = pieces[0].split(separator: ".").map(String.init)
            guard core.count == 3 else { return nil }
            let prerelease = pieces.count == 2 ? pieces[1].split(separator: ".").map(String.init) : nil
            return (core, prerelease)
        }
        func compareNumeric(_ left: String, _ right: String) -> ComparisonResult {
            let normalizedLeft = String(left.drop(while: { $0 == "0" }))
            let normalizedRight = String(right.drop(while: { $0 == "0" }))
            let safeLeft = normalizedLeft.isEmpty ? "0" : normalizedLeft
            let safeRight = normalizedRight.isEmpty ? "0" : normalizedRight
            if safeLeft.count != safeRight.count {
                return safeLeft.count < safeRight.count ? .orderedAscending : .orderedDescending
            }
            if safeLeft == safeRight { return .orderedSame }
            return safeLeft < safeRight ? .orderedAscending : .orderedDescending
        }
        guard let left = parsed(lhs), let right = parsed(rhs) else { return .orderedSame }
        for index in 0..<3 {
            let comparison = compareNumeric(left.0[index], right.0[index])
            if comparison != .orderedSame { return comparison }
        }
        switch (left.1, right.1) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case (.some(let leftParts), .some(let rightParts)):
            for index in 0..<max(leftParts.count, rightParts.count) {
                guard index < leftParts.count else { return .orderedAscending }
                guard index < rightParts.count else { return .orderedDescending }
                let leftPart = leftParts[index]
                let rightPart = rightParts[index]
                if leftPart == rightPart { continue }
                let leftNumeric = leftPart.allSatisfy { $0.isNumber }
                let rightNumeric = rightPart.allSatisfy { $0.isNumber }
                if leftNumeric && rightNumeric {
                    return compareNumeric(leftPart, rightPart)
                }
                if leftNumeric { return .orderedAscending }
                if rightNumeric { return .orderedDescending }
                return leftPart < rightPart ? .orderedAscending : .orderedDescending
            }
            return .orderedSame
        }
    }

    private static func validDigest(_ value: String) -> Bool {
        value.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    private static func validPermission(_ value: String) -> Bool {
        value.unicodeScalars.count <= 128
            && value.range(of: "^[a-z][a-z0-9]*(?:\\.[a-z][a-z0-9_]*)+$", options: .regularExpression) != nil
    }

    private static func validStateProperty(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil
    }

    private static func validPackageID(_ value: String) -> Bool {
        value.unicodeScalars.count <= 160
            && value.range(of: "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$", options: .regularExpression) != nil
    }
}
