import CryptoKit
import CoreFoundation
import Foundation

enum PocketAppWorkspaceBackupError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let code): code
        }
    }
}

struct PocketAppWorkspaceInstalledVersion: Equatable, Sendable {
    let version: String
    let packageDigest: String
}

struct PocketAppWorkspaceBackupApp: Equatable, Sendable {
    let appID: String
    let activeVersion: String
    let activePackageDigest: String
    let stateSchemaDigest: String
    let lifecycleState: PocketAppLifecycleState
    let effectivePermissions: [String]
    let installedVersions: [PocketAppWorkspaceInstalledVersion]
    let dataVersion: Int
    let dataDigest: String
}

struct PocketAppWorkspaceBackupFile: Equatable, Sendable {
    let path: String
    let size: Int
    let sha256: String
    let bytes: Data
}

struct PocketAppWorkspaceBackupArchive: Equatable, Sendable {
    static let schema = "hoverpocket.pocket-app-workspace-backup/v1"

    let createdAt: Date
    let sourcePlatform: String
    let hostVersion: String
    let apps: [PocketAppWorkspaceBackupApp]
    let files: [PocketAppWorkspaceBackupFile]
}

struct PocketAppWorkspaceRestoreChange: Equatable, Sendable {
    let appID: String
    let action: String
    let fromVersion: String?
    let toVersion: String
    let fromLifecycleState: String?
    let toLifecycleState: String
    let addedPermissions: [String]
    let removedPermissions: [String]
    let dataChanged: Bool
}

struct PocketAppWorkspaceRestoreProposal: Equatable, Sendable {
    let requestID: String
    let backupDigest: String
    let bindingDigest: String
    let changes: [PocketAppWorkspaceRestoreChange]
    let createdAt: Date
    let expiresAt: Date
}

struct PocketAppWorkspaceRestoreGrant: Equatable, Sendable {
    fileprivate let token: String
}

struct PocketAppWorkspaceRestoreAppReadback: Equatable, Sendable {
    let appID: String
    let version: String
    let packageDigest: String
    let lifecycleState: PocketAppLifecycleState
    let effectivePermissions: [String]
    let runtimeReadbackVerified: Bool
    let dataVersion: Int
    let dataDigest: String
}

struct PocketAppWorkspaceRestoreReceipt: Equatable, Sendable {
    let backupDigest: String
    let restoredApps: [PocketAppWorkspaceRestoreAppReadback]
    let readbackVerified: Bool
    let rollbackPerformed: Bool
}

@MainActor
final class PocketAppWorkspaceBackupManager {
    static let maximumBackupFileBytes = 96 * 1_024 * 1_024
    static let maximumDecodedBytes = 64 * 1_024 * 1_024
    static let maximumFiles = 2_048
    static let maximumApps = 64
    static let approvalLifetime: TimeInterval = 300

    private struct PackagePayload {
        let version: String
        let digest: String
        let files: [String: Data]
    }

    private struct ValidatedArchive {
        let archive: PocketAppWorkspaceBackupArchive
        let packages: [String: [PackagePayload]]
        let userData: [String: Data]
        let encodedBytes: Data
    }

    private struct PendingRestore {
        let proposal: PocketAppWorkspaceRestoreProposal
        let validated: ValidatedArchive
    }

    private struct IssuedGrant {
        let requestID: String
        let bindingDigest: String
        let expiresAt: Date
    }

    private let definitionRoot: URL
    private let userDataRoot: URL
    private let transactionRoot: URL
    private let lifecycle: PocketAppLifecycleManager
    private let runtime: PocketAppPackageRuntime
    private let runtimeReadback: ((PocketAppLifecycleReceipt) throws -> PocketAppRuntimeReadback)?
    private let failureInjection: ((String) -> Bool)?
    private var pending: [String: PendingRestore] = [:]
    private var grants: [String: IssuedGrant] = [:]

    init(
        definitionRoot: URL,
        userDataRoot: URL,
        transactionRoot: URL,
        lifecycle: PocketAppLifecycleManager,
        runtimeReadback: ((PocketAppLifecycleReceipt) throws -> PocketAppRuntimeReadback)? = nil,
        failureInjection: ((String) -> Bool)? = nil
    ) throws {
        self.definitionRoot = definitionRoot.standardizedFileURL
        self.userDataRoot = userDataRoot.standardizedFileURL
        self.transactionRoot = transactionRoot.standardizedFileURL
        self.lifecycle = lifecycle
        self.runtime = PocketAppPackageRuntime()
        self.runtimeReadback = runtimeReadback
        self.failureInjection = failureInjection
        try FileManager.default.createDirectory(
            at: self.transactionRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try requireDirectory(self.definitionRoot, code: "BACKUP_DEFINITION_ROOT_INVALID")
        try requireDirectory(self.userDataRoot, code: "BACKUP_DATA_ROOT_INVALID")
        try requireDirectory(self.transactionRoot, code: "BACKUP_TRANSACTION_ROOT_INVALID")
    }

    func exportData(now: Date = Date()) throws -> Data {
        let archive = try captureArchive(now: now)
        return try encode(archive)
    }

    func export(to destination: URL, now: Date = Date()) throws -> String {
        let data = try exportData(now: now)
        guard data.count <= Self.maximumBackupFileBytes else {
            throw failure("BACKUP_SIZE_EXCEEDED")
        }
        let target = destination.standardizedFileURL
        let parent = target.deletingLastPathComponent()
        try requireDirectory(parent, code: "BACKUP_DESTINATION_INVALID")
        if FileManager.default.fileExists(atPath: target.path) {
            let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw failure("BACKUP_DESTINATION_INVALID")
            }
        }
        do {
            try data.write(to: target, options: .atomic)
            let observed = try Data(contentsOf: target, options: [.mappedIfSafe])
            guard observed == data else { throw failure("BACKUP_WRITE_READBACK_FAILED") }
            return Self.sha256(data)
        } catch let error as PocketAppWorkspaceBackupError {
            throw error
        } catch {
            throw failure("BACKUP_WRITE_FAILED")
        }
    }

    func prepareRestore(data: Data, now: Date = Date()) throws -> PocketAppWorkspaceRestoreProposal {
        guard data.count <= Self.maximumBackupFileBytes else {
            throw failure("RESTORE_BACKUP_SIZE_EXCEEDED")
        }
        try purgeExpired(now: now)
        let validated = try decodeAndValidate(data)
        let changes = try restoreChanges(validated)
        let backupDigest = Self.sha256(data)
        let previewBytes = try Self.canonicalPreview(changes)
        let bindingDigest = Self.sha256(Data((backupDigest + "\n").utf8) + previewBytes)
        let requestID = "workspace-restore-approval:\(UUID().uuidString.lowercased())"
        let proposal = PocketAppWorkspaceRestoreProposal(
            requestID: requestID,
            backupDigest: backupDigest,
            bindingDigest: bindingDigest,
            changes: changes,
            createdAt: now,
            expiresAt: now.addingTimeInterval(Self.approvalLifetime)
        )
        pending[requestID] = PendingRestore(proposal: proposal, validated: validated)
        return proposal
    }

    func prepareRestore(from source: URL, now: Date = Date()) throws -> PocketAppWorkspaceRestoreProposal {
        let url = source.standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= Self.maximumBackupFileBytes else {
            throw failure("RESTORE_SOURCE_INVALID")
        }
        return try prepareRestore(data: Self.readBoundedFile(url), now: now)
    }

    func approve(
        requestID: String,
        bindingDigest: String,
        now: Date = Date()
    ) throws -> PocketAppWorkspaceRestoreGrant {
        try purgeExpired(now: now)
        guard let item = pending[requestID],
              item.proposal.bindingDigest == bindingDigest,
              now <= item.proposal.expiresAt else {
            throw failure("RESTORE_APPROVAL_INVALID")
        }
        let token = "workspace-restore-grant:\(UUID().uuidString.lowercased())"
        grants[token] = IssuedGrant(
            requestID: requestID,
            bindingDigest: bindingDigest,
            expiresAt: item.proposal.expiresAt
        )
        return PocketAppWorkspaceRestoreGrant(token: token)
    }

    func reject(requestID: String, bindingDigest: String) throws {
        guard let item = pending[requestID], item.proposal.bindingDigest == bindingDigest else {
            throw failure("RESTORE_APPROVAL_INVALID")
        }
        pending.removeValue(forKey: requestID)
        grants = grants.filter { $0.value.requestID != requestID }
    }

    func restore(
        _ proposal: PocketAppWorkspaceRestoreProposal,
        grant: PocketAppWorkspaceRestoreGrant?,
        now: Date = Date()
    ) throws -> PocketAppWorkspaceRestoreReceipt {
        try purgeExpired(now: now)
        guard let item = pending[proposal.requestID], item.proposal == proposal else {
            throw failure("RESTORE_PROPOSAL_CHANGED")
        }
        guard let grant else { throw failure("RESTORE_APPROVAL_REQUIRED") }
        let currentPreview = try Self.canonicalPreview(restoreChanges(item.validated))
        let approvedPreview = try Self.canonicalPreview(proposal.changes)
        guard currentPreview == approvedPreview else { throw failure("RESTORE_PROPOSAL_CHANGED") }
        try consume(grant, proposal: proposal, now: now)

        let affectedIDs = Set(item.validated.archive.apps.map(\.appID))
        let previous = try captureArchive(now: now, appIDs: affectedIDs)
        let previousIDs = Set(previous.apps.map(\.appID))
        var rollbackPerformed = false
        do {
            try apply(item.validated, now: now, verifyRuntime: true, allowFailureInjection: true)
            let readbacks = try readback(item.validated)
            guard readbacks.count == item.validated.archive.apps.count,
                  readbacks.allSatisfy(\.runtimeReadbackVerified) else {
                throw failure("RESTORE_READBACK_MISMATCH")
            }
            pending.removeValue(forKey: proposal.requestID)
            grants = grants.filter { $0.value.requestID != proposal.requestID }
            return PocketAppWorkspaceRestoreReceipt(
                backupDigest: proposal.backupDigest,
                restoredApps: readbacks,
                readbackVerified: true,
                rollbackPerformed: false
            )
        } catch {
            rollbackPerformed = true
            var rollbackFailed = false
            do {
                let currentIDs = Set(item.validated.archive.apps.map(\.appID))
                try removeApps(currentIDs, now: now)
                let previousData = try encode(previous)
                let previousValidated = try decodeAndValidate(previousData)
                try apply(previousValidated, now: now, verifyRuntime: true, allowFailureInjection: false)
                for appID in currentIDs.subtracting(previousIDs) {
                    try removeResidualApp(appID)
                }
            } catch {
                rollbackFailed = true
            }
            pending.removeValue(forKey: proposal.requestID)
            grants = grants.filter { $0.value.requestID != proposal.requestID }
            if rollbackFailed {
                throw failure("RESTORE_ROLLBACK_FAILED")
            }
            _ = rollbackPerformed
            throw failure("RESTORE_COMMIT_FAILED_ROLLED_BACK")
        }
    }

    private func captureArchive(now: Date, appIDs: Set<String>? = nil) throws -> PocketAppWorkspaceBackupArchive {
        let snapshot = try lifecycle.managementSnapshot()
        guard snapshot.issues.isEmpty else { throw failure("BACKUP_WORKSPACE_UNHEALTHY") }
        let managed = snapshot.packages
            .filter { package in
                package.state != .removed && (appIDs == nil || appIDs?.contains(package.packageID) == true)
            }
            .sorted { $0.packageID < $1.packageID }
        guard managed.count <= Self.maximumApps else { throw failure("BACKUP_APP_LIMIT_EXCEEDED") }

        var apps: [PocketAppWorkspaceBackupApp] = []
        var files: [PocketAppWorkspaceBackupFile] = []
        var decodedTotal = 0
        for managedPackage in managed {
            guard let activeVersion = managedPackage.version,
                  let activeDigest = managedPackage.packageDigest else {
                throw failure("BACKUP_LIFECYCLE_INVALID")
            }
            let packages = try installedPackages(appID: managedPackage.packageID)
            guard !packages.isEmpty,
                  packages.contains(where: { $0.version == activeVersion && $0.digest == activeDigest }) else {
                throw failure("BACKUP_LIFECYCLE_INVALID")
            }
            let activePackage = try packagePayload(
                packages,
                version: activeVersion,
                digest: activeDigest
            )
            let loadedActive = try loadPackage(activePackage)
            let permissions = Set(loadedActive.manifest.requestedCapabilities
                .flatMap { $0.permissions })
                .sorted()
            let stateBytes = try validatedStateBytes(
                appID: managedPackage.packageID,
                stateProperties: loadedActive.stateProperties,
                sourceRoot: userDataRoot,
                defaultIfMissing: Data("{}".utf8)
            )
            let dataDigest = Self.sha256(stateBytes)
            files.append(PocketAppWorkspaceBackupFile(
                path: "data/\(managedPackage.packageID)/state.json",
                size: stateBytes.count,
                sha256: dataDigest,
                bytes: stateBytes
            ))
            decodedTotal += stateBytes.count

            for package in packages {
                for path in package.files.keys.sorted() {
                    guard let bytes = package.files[path] else { throw failure("BACKUP_PACKAGE_INVALID") }
                    let archivePath = "apps/\(managedPackage.packageID)/versions/\(package.version)/\(Self.digestHex(package.digest))/package/\(path)"
                    files.append(PocketAppWorkspaceBackupFile(
                        path: archivePath,
                        size: bytes.count,
                        sha256: Self.sha256(bytes),
                        bytes: bytes
                    ))
                    decodedTotal += bytes.count
                }
            }
            guard decodedTotal <= Self.maximumDecodedBytes else {
                throw failure("BACKUP_SIZE_EXCEEDED")
            }
            apps.append(PocketAppWorkspaceBackupApp(
                appID: managedPackage.packageID,
                activeVersion: activeVersion,
                activePackageDigest: activeDigest,
                stateSchemaDigest: loadedActive.stateSchemaDigest,
                lifecycleState: managedPackage.state,
                effectivePermissions: permissions,
                installedVersions: packages.map {
                    PocketAppWorkspaceInstalledVersion(version: $0.version, packageDigest: $0.digest)
                },
                dataVersion: 1,
                dataDigest: dataDigest
            ))
        }
        guard files.count <= Self.maximumFiles else { throw failure("BACKUP_FILE_LIMIT_EXCEEDED") }
        files.sort { $0.path < $1.path }
        let lowercased = files.map { $0.path.lowercased() }
        guard Set(lowercased).count == lowercased.count else { throw failure("BACKUP_CASE_COLLISION") }
        return PocketAppWorkspaceBackupArchive(
            createdAt: now,
            sourcePlatform: "macos",
            hostVersion: PocketAppHostContract.version,
            apps: apps,
            files: files
        )
    }

    private func decodeAndValidate(_ data: Data) throws -> ValidatedArchive {
        guard data.count <= Self.maximumBackupFileBytes else {
            throw failure("RESTORE_BACKUP_SIZE_EXCEEDED")
        }
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw failure("RESTORE_DOCUMENT_INVALID")
            }
            object = decoded
        } catch let error as PocketAppWorkspaceBackupError {
            throw error
        } catch {
            throw failure("RESTORE_DOCUMENT_INVALID")
        }
        try requireKeys(
            object,
            expected: ["schema", "createdAt", "sourcePlatform", "hostVersion", "apps", "files"],
            code: "RESTORE_DOCUMENT_INVALID"
        )
        guard object["schema"] as? String == PocketAppWorkspaceBackupArchive.schema,
              let createdAtText = object["createdAt"] as? String,
              let createdAt = Self.parseDate(createdAtText),
              let sourcePlatform = object["sourcePlatform"] as? String,
              ["macos", "windows"].contains(sourcePlatform),
              let hostVersion = object["hostVersion"] as? String,
              Self.validVersion(hostVersion),
              let rawApps = object["apps"] as? [Any],
              let rawFiles = object["files"] as? [Any],
              rawApps.count <= Self.maximumApps,
              rawFiles.count <= Self.maximumFiles else {
            throw failure("RESTORE_DOCUMENT_INVALID")
        }

        var files: [PocketAppWorkspaceBackupFile] = []
        var filePaths = Set<String>()
        var foldedPaths = Set<String>()
        var decodedTotal = 0
        for raw in rawFiles {
            guard let item = raw as? [String: Any] else { throw failure("RESTORE_FILE_INVALID") }
            try requireKeys(item, expected: ["path", "size", "sha256", "contentBase64"], code: "RESTORE_FILE_INVALID")
            guard let path = item["path"] as? String,
                  let sizeNumber = item["size"] as? NSNumber,
                  CFGetTypeID(sizeNumber) != CFBooleanGetTypeID(),
                  let digest = item["sha256"] as? String,
                  let encoded = item["contentBase64"] as? String,
                  let bytes = Data(base64Encoded: encoded, options: []),
                  bytes.base64EncodedString() == encoded,
                  Self.safeArchivePath(path),
                  Self.validDigest(digest),
                  sizeNumber.intValue == bytes.count,
                  bytes.count <= PocketAppPackageRuntime.maximumFileBytes,
                  Self.sha256(bytes) == digest,
                  filePaths.insert(path).inserted,
                  foldedPaths.insert(path.lowercased()).inserted else {
                throw failure("RESTORE_FILE_INVALID")
            }
            decodedTotal += bytes.count
            guard decodedTotal <= Self.maximumDecodedBytes else {
                throw failure("RESTORE_BACKUP_SIZE_EXCEEDED")
            }
            files.append(PocketAppWorkspaceBackupFile(path: path, size: bytes.count, sha256: digest, bytes: bytes))
        }
        guard files.map(\.path) == files.map(\.path).sorted() else {
            throw failure("RESTORE_FILE_ORDER_INVALID")
        }

        var apps: [PocketAppWorkspaceBackupApp] = []
        var appIDs = Set<String>()
        for raw in rawApps {
            guard let item = raw as? [String: Any] else { throw failure("RESTORE_APP_INVALID") }
            try requireKeys(
                item,
                expected: [
                    "appId", "activeVersion", "activePackageDigest", "stateSchemaDigest",
                    "lifecycleState", "effectivePermissions", "installedVersions", "dataVersion", "dataDigest"
                ],
                code: "RESTORE_APP_INVALID"
            )
            guard let appID = item["appId"] as? String,
                  Self.validAppID(appID),
                  appIDs.insert(appID).inserted,
                  let activeVersion = item["activeVersion"] as? String,
                  Self.validVersion(activeVersion),
                  let activeDigest = item["activePackageDigest"] as? String,
                  Self.validDigest(activeDigest),
                  let schemaDigest = item["stateSchemaDigest"] as? String,
                  Self.validDigest(schemaDigest),
                  let stateText = item["lifecycleState"] as? String,
                  let state = PocketAppLifecycleState(rawValue: stateText),
                  state == .enabled || state == .disabled,
                  let rawPermissions = item["effectivePermissions"] as? [Any],
                  let rawVersions = item["installedVersions"] as? [Any],
                  let dataVersionNumber = item["dataVersion"] as? NSNumber,
                  dataVersionNumber.intValue == 1,
                  let dataDigest = item["dataDigest"] as? String,
                  Self.validDigest(dataDigest) else {
                throw failure("RESTORE_APP_INVALID")
            }
            let permissions = try rawPermissions.map { value -> String in
                guard let permission = value as? String, Self.validPermission(permission) else {
                    throw failure("RESTORE_PERMISSION_INVALID")
                }
                return permission
            }
            guard permissions == permissions.sorted(), Set(permissions).count == permissions.count else {
                throw failure("RESTORE_PERMISSION_INVALID")
            }
            var versions: [PocketAppWorkspaceInstalledVersion] = []
            var versionNames = Set<String>()
            for versionRaw in rawVersions {
                guard let versionObject = versionRaw as? [String: Any] else {
                    throw failure("RESTORE_VERSION_INVALID")
                }
                try requireKeys(versionObject, expected: ["version", "packageDigest"], code: "RESTORE_VERSION_INVALID")
                guard let version = versionObject["version"] as? String,
                      Self.validVersion(version),
                      versionNames.insert(version).inserted,
                      let digest = versionObject["packageDigest"] as? String,
                      Self.validDigest(digest) else {
                    throw failure("RESTORE_VERSION_INVALID")
                }
                versions.append(PocketAppWorkspaceInstalledVersion(version: version, packageDigest: digest))
            }
            guard !versions.isEmpty,
                  versions == versions.sorted(by: { Self.compareVersions($0.version, $1.version) }),
                  versions.contains(where: { $0.version == activeVersion && $0.packageDigest == activeDigest }) else {
                throw failure("RESTORE_VERSION_INVALID")
            }
            apps.append(PocketAppWorkspaceBackupApp(
                appID: appID,
                activeVersion: activeVersion,
                activePackageDigest: activeDigest,
                stateSchemaDigest: schemaDigest,
                lifecycleState: state,
                effectivePermissions: permissions,
                installedVersions: versions,
                dataVersion: 1,
                dataDigest: dataDigest
            ))
        }
        guard apps.map(\.appID) == apps.map(\.appID).sorted() else {
            throw failure("RESTORE_APP_ORDER_INVALID")
        }

        var packages: [String: [PackagePayload]] = [:]
        var userData: [String: Data] = [:]
        var expectedPaths = Set<String>()
        let filesByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        for app in apps {
            var payloads: [PackagePayload] = []
            for installed in app.installedVersions {
                let prefix = "apps/\(app.appID)/versions/\(installed.version)/\(Self.digestHex(installed.packageDigest))/package/"
                let matching = files.filter { $0.path.hasPrefix(prefix) }
                guard !matching.isEmpty else { throw failure("RESTORE_PACKAGE_MISSING") }
                let relativeFiles = Dictionary(uniqueKeysWithValues: matching.map {
                    (String($0.path.dropFirst(prefix.count)), $0.bytes)
                })
                let payload = PackagePayload(version: installed.version, digest: installed.packageDigest, files: relativeFiles)
                let loaded = try loadPackage(payload)
                guard loaded.manifest.id == app.appID,
                      loaded.manifest.version == installed.version,
                      loaded.manifestDigest == installed.packageDigest else {
                    throw failure("RESTORE_PACKAGE_INVALID")
                }
                payloads.append(payload)
                expectedPaths.formUnion(matching.map(\.path))
            }
            guard let active = payloads.first(where: {
                $0.version == app.activeVersion && $0.digest == app.activePackageDigest
            }) else { throw failure("RESTORE_ACTIVE_PACKAGE_MISSING") }
            let loadedActive = try loadPackage(active)
            let observedPermissions = Set(
                loadedActive.manifest.requestedCapabilities.flatMap { $0.permissions }
            ).sorted()
            guard loadedActive.stateSchemaDigest == app.stateSchemaDigest,
                  observedPermissions == app.effectivePermissions else {
                throw failure("RESTORE_APP_BINDING_MISMATCH")
            }
            let dataPath = "data/\(app.appID)/state.json"
            guard let stateFile = filesByPath[dataPath], stateFile.sha256 == app.dataDigest else {
                throw failure("RESTORE_DATA_MISSING")
            }
            _ = try validatedStateBytes(
                appID: app.appID,
                stateProperties: loadedActive.stateProperties,
                bytes: stateFile.bytes
            )
            expectedPaths.insert(dataPath)
            packages[app.appID] = payloads
            userData[app.appID] = stateFile.bytes
        }
        guard expectedPaths == filePaths else { throw failure("RESTORE_UNREFERENCED_FILE") }
        let archive = PocketAppWorkspaceBackupArchive(
            createdAt: createdAt,
            sourcePlatform: sourcePlatform,
            hostVersion: hostVersion,
            apps: apps,
            files: files
        )
        return ValidatedArchive(archive: archive, packages: packages, userData: userData, encodedBytes: data)
    }

    private func restoreChanges(_ validated: ValidatedArchive) throws -> [PocketAppWorkspaceRestoreChange] {
        var changes: [PocketAppWorkspaceRestoreChange] = []
        for app in validated.archive.apps {
            let current = try lifecycle.managedPackage(packageID: app.appID)
            let currentPermissions: [String]
            if let version = current?.version,
               let digest = current?.packageDigest,
               let payload = try? installedPackages(appID: app.appID).first(where: {
                   $0.version == version && $0.digest == digest
               }),
               let loaded = try? loadPackage(payload) {
                currentPermissions = Set(
                    loaded.manifest.requestedCapabilities.flatMap { $0.permissions }
                ).sorted()
            } else {
                currentPermissions = []
            }
            let currentData = try? currentStateBytes(appID: app.appID)
            let targetData = validated.userData[app.appID] ?? Data()
            changes.append(PocketAppWorkspaceRestoreChange(
                appID: app.appID,
                action: current == nil || current?.state == .removed ? "add" : "replace",
                fromVersion: current?.version,
                toVersion: app.activeVersion,
                fromLifecycleState: current?.state.rawValue,
                toLifecycleState: app.lifecycleState.rawValue,
                addedPermissions: app.effectivePermissions.filter { !currentPermissions.contains($0) },
                removedPermissions: currentPermissions.filter { !app.effectivePermissions.contains($0) },
                dataChanged: currentData != targetData
            ))
        }
        return changes.sorted { $0.appID < $1.appID }
    }

    private func apply(
        _ validated: ValidatedArchive,
        now: Date,
        verifyRuntime: Bool,
        allowFailureInjection: Bool
    ) throws {
        let appIDs = Set(validated.archive.apps.map(\.appID))
        try removeApps(appIDs, now: now)
        for app in validated.archive.apps {
            guard let payloads = validated.packages[app.appID],
                  let stateBytes = validated.userData[app.appID] else {
                throw failure("RESTORE_PACKAGE_MISSING")
            }
            for payload in payloads {
                let draft = transactionRoot
                    .appendingPathComponent("draft-\(UUID().uuidString.lowercased())", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: draft) }
                try materialize(payload.files, at: draft)
                let proposal = try lifecycle.stage(draftDirectory: draft, now: now)
                guard proposal.packageID == app.appID,
                      proposal.version == payload.version,
                      proposal.packageDigest == payload.digest else {
                    throw failure("RESTORE_PACKAGE_CHANGED")
                }
                let grant = try lifecycle.approve(
                    requestID: proposal.requestID,
                    bindingDigest: proposal.bindingDigest,
                    now: now
                )
                _ = try lifecycle.install(proposal, approvalGrant: grant, now: now)
            }
            let current = try lifecycle.managedPackage(packageID: app.appID)
            if current?.version != app.activeVersion || current?.packageDigest != app.activePackageDigest {
                let rollback = try lifecycle.prepareRollback(
                    packageID: app.appID,
                    version: app.activeVersion,
                    now: now
                )
                guard rollback.packageDigest == app.activePackageDigest else {
                    throw failure("RESTORE_ACTIVE_PACKAGE_MISMATCH")
                }
                let grant = try lifecycle.approve(
                    requestID: rollback.requestID,
                    bindingDigest: rollback.bindingDigest,
                    now: now
                )
                _ = try lifecycle.rollback(rollback, approvalGrant: grant, now: now)
            }
            try replaceState(appID: app.appID, bytes: stateBytes)
            if app.lifecycleState == .disabled {
                _ = try lifecycle.disable(packageID: app.appID, now: now)
            }
            if allowFailureInjection, failureInjection?("after_app_commit") == true {
                throw failure("RESTORE_INJECTED_FAILURE")
            }
            if verifyRuntime {
                try verifyFinalRuntime(app)
            }
        }
    }

    private func readback(_ validated: ValidatedArchive) throws -> [PocketAppWorkspaceRestoreAppReadback] {
        try validated.archive.apps.map { app in
            guard let current = try lifecycle.managedPackage(packageID: app.appID),
                  current.version == app.activeVersion,
                  current.packageDigest == app.activePackageDigest,
                  current.state == app.lifecycleState else {
                throw failure("RESTORE_LIFECYCLE_READBACK_MISMATCH")
            }
            let stateBytes = try currentStateBytes(appID: app.appID)
            guard Self.sha256(stateBytes) == app.dataDigest else {
                throw failure("RESTORE_DATA_READBACK_MISMATCH")
            }
            try verifyFinalRuntime(app)
            return PocketAppWorkspaceRestoreAppReadback(
                appID: app.appID,
                version: app.activeVersion,
                packageDigest: app.activePackageDigest,
                lifecycleState: app.lifecycleState,
                effectivePermissions: app.effectivePermissions,
                runtimeReadbackVerified: true,
                dataVersion: app.dataVersion,
                dataDigest: app.dataDigest
            )
        }
    }

    private func verifyFinalRuntime(_ app: PocketAppWorkspaceBackupApp) throws {
        guard let runtimeReadback else { return }
        let effective = app.lifecycleState == .enabled ? app.effectivePermissions : []
        let receipt = PocketAppLifecycleReceipt(
            action: "workspace_restore",
            packageID: app.appID,
            version: app.activeVersion,
            packageDigest: app.activePackageDigest,
            effectivePermissions: effective,
            state: app.lifecycleState,
            readbackVerified: true,
            dataDisposition: nil
        )
        let observed = try runtimeReadback(receipt)
        guard observed.matches(receipt) else { throw failure("RESTORE_RUNTIME_READBACK_MISMATCH") }
        if failureInjection?("runtime_readback") == true {
            throw failure("RESTORE_RUNTIME_READBACK_MISMATCH")
        }
    }

    private func removeApps(_ appIDs: Set<String>, now: Date) throws {
        for appID in appIDs.sorted() {
            guard let current = try lifecycle.managedPackage(packageID: appID), current.state != .removed else { continue }
            _ = try lifecycle.remove(packageID: appID, dataDisposition: .preserve, now: now)
        }
    }

    private func removeResidualApp(_ appID: String) throws {
        let appRoot = definitionRoot.appendingPathComponent("Apps/\(appID)", isDirectory: true)
        let dataRoot = userDataRoot.appendingPathComponent(appID, isDirectory: true)
        for url in [appRoot, dataRoot] where FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw failure("RESTORE_ROLLBACK_FAILED")
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func installedPackages(appID: String) throws -> [PackagePayload] {
        guard Self.validAppID(appID) else { throw failure("BACKUP_APP_INVALID") }
        let versionsRoot = definitionRoot
            .appendingPathComponent("Apps", isDirectory: true)
            .appendingPathComponent(appID, isDirectory: true)
            .appendingPathComponent("Versions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: versionsRoot.path) else { return [] }
        try requireDirectory(versionsRoot, code: "BACKUP_VERSION_ROOT_INVALID")
        var result: [PackagePayload] = []
        for versionDirectory in try childDirectories(versionsRoot) {
            for digestDirectory in try childDirectories(versionDirectory)
                where !digestDirectory.lastPathComponent.hasPrefix(".installing-") {
                let packageDirectory = digestDirectory.appendingPathComponent("package", isDirectory: true)
                let snapshot = try PocketAppFileSnapshot.capture(directory: packageDirectory)
                let package = try runtime.load(snapshot: snapshot)
                guard package.manifest.id == appID,
                      digestDirectory.lastPathComponent == Self.digestHex(package.manifestDigest) else {
                    throw failure("BACKUP_PACKAGE_INVALID")
                }
                result.append(PackagePayload(
                    version: package.manifest.version,
                    digest: package.manifestDigest,
                    files: snapshot.files
                ))
            }
        }
        result.sort { Self.compareVersions($0.version, $1.version) }
        let versions = result.map(\.version)
        guard Set(versions).count == versions.count else { throw failure("BACKUP_VERSION_CONFLICT") }
        return result
    }

    private func loadPackage(_ payload: PackagePayload) throws -> PocketAppPackage {
        do {
            return try runtime.load(snapshot: PocketAppFileSnapshot(
                rootDirectory: transactionRoot,
                files: payload.files,
                identities: [:]
            ))
        } catch {
            throw failure("RESTORE_PACKAGE_INVALID")
        }
    }

    private func packagePayload(
        _ packages: [PackagePayload],
        version: String,
        digest: String
    ) throws -> PackagePayload {
        guard let payload = packages.first(where: { $0.version == version && $0.digest == digest }) else {
            throw failure("BACKUP_ACTIVE_PACKAGE_MISSING")
        }
        return payload
    }

    private func validatedStateBytes(
        appID: String,
        stateProperties: [String: PocketAppStatePropertySchema],
        sourceRoot: URL,
        defaultIfMissing: Data
    ) throws -> Data {
        let path = sourceRoot.appendingPathComponent("\(appID)/state.json")
        let bytes: Data
        if FileManager.default.fileExists(atPath: path.path) {
            bytes = try PocketAppFileSnapshot.readFileNoFollow(
                rootDirectory: sourceRoot,
                relativePath: "\(appID)/state.json",
                maximumBytes: 256 * 1_024
            )
        } else {
            bytes = defaultIfMissing
        }
        return try validatedStateBytes(appID: appID, stateProperties: stateProperties, bytes: bytes)
    }

    private func validatedStateBytes(
        appID: String,
        stateProperties: [String: PocketAppStatePropertySchema],
        bytes: Data
    ) throws -> Data {
        guard bytes.count <= 256 * 1_024 else { throw failure("RESTORE_DATA_INVALID") }
        let root = transactionRoot.appendingPathComponent("validate-\(UUID().uuidString.lowercased())", isDirectory: true)
        let appRoot = root.appendingPathComponent(appID, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: appRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stateURL = appRoot.appendingPathComponent("state.json")
        try bytes.write(to: stateURL, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        _ = try PocketAppUserStateStore(packageID: appID, stateProperties: stateProperties, rootDirectory: root)
        let observed = try PocketAppFileSnapshot.readFileNoFollow(
            rootDirectory: root,
            relativePath: "\(appID)/state.json",
            maximumBytes: 256 * 1_024
        )
        guard observed == bytes else { throw failure("RESTORE_DATA_SCHEMA_INVALID") }
        return bytes
    }

    private func replaceState(appID: String, bytes: Data) throws {
        let directory = userDataRoot.appendingPathComponent(appID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try requireDirectory(directory, code: "RESTORE_DATA_ROOT_INVALID")
        let target = directory.appendingPathComponent("state.json")
        try bytes.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        guard try currentStateBytes(appID: appID) == bytes else {
            throw failure("RESTORE_DATA_READBACK_MISMATCH")
        }
    }

    private func currentStateBytes(appID: String) throws -> Data {
        let target = userDataRoot.appendingPathComponent("\(appID)/state.json")
        guard FileManager.default.fileExists(atPath: target.path) else { return Data("{}".utf8) }
        return try PocketAppFileSnapshot.readFileNoFollow(
            rootDirectory: userDataRoot,
            relativePath: "\(appID)/state.json",
            maximumBytes: 256 * 1_024
        )
    }

    private func materialize(_ files: [String: Data], at directory: URL) throws {
        let snapshot = PocketAppFileSnapshot(rootDirectory: directory, files: files, identities: [:])
        try snapshot.materialize(at: directory)
    }

    private func encode(_ archive: PocketAppWorkspaceBackupArchive) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let object: [String: Any] = [
            "schema": PocketAppWorkspaceBackupArchive.schema,
            "createdAt": formatter.string(from: archive.createdAt),
            "sourcePlatform": archive.sourcePlatform,
            "hostVersion": archive.hostVersion,
            "apps": archive.apps.map { app in
                [
                    "appId": app.appID,
                    "activeVersion": app.activeVersion,
                    "activePackageDigest": app.activePackageDigest,
                    "stateSchemaDigest": app.stateSchemaDigest,
                    "lifecycleState": app.lifecycleState.rawValue,
                    "effectivePermissions": app.effectivePermissions,
                    "installedVersions": app.installedVersions.map {
                        ["version": $0.version, "packageDigest": $0.packageDigest]
                    },
                    "dataVersion": app.dataVersion,
                    "dataDigest": app.dataDigest
                ] as [String: Any]
            },
            "files": archive.files.map { file in
                [
                    "path": file.path,
                    "size": file.size,
                    "sha256": file.sha256,
                    "contentBase64": file.bytes.base64EncodedString()
                ] as [String: Any]
            }
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= Self.maximumBackupFileBytes else { throw failure("BACKUP_SIZE_EXCEEDED") }
        return data
    }

    private func consume(
        _ grant: PocketAppWorkspaceRestoreGrant,
        proposal: PocketAppWorkspaceRestoreProposal,
        now: Date
    ) throws {
        guard let issued = grants.removeValue(forKey: grant.token),
              issued.requestID == proposal.requestID,
              issued.bindingDigest == proposal.bindingDigest,
              now <= issued.expiresAt else {
            throw failure("RESTORE_APPROVAL_INVALID")
        }
    }

    private func purgeExpired(now: Date) throws {
        let expired = pending.values.filter { now > $0.proposal.expiresAt }.map { $0.proposal.requestID }
        for requestID in expired {
            pending.removeValue(forKey: requestID)
            grants = grants.filter { $0.value.requestID != requestID }
        }
    }

    private func requireDirectory(_ url: URL, code: String) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw failure(code) }
    }

    private func childDirectories(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ).filter { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw failure("BACKUP_TREE_INVALID")
            }
            return true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func requireKeys(_ object: [String: Any], expected: Set<String>, code: String) throws {
        guard Set(object.keys) == expected else { throw failure(code) }
    }

    private static func canonicalPreview(_ changes: [PocketAppWorkspaceRestoreChange]) throws -> Data {
        let object = changes.map { change in
            [
                "appId": change.appID,
                "action": change.action,
                "fromVersion": change.fromVersion ?? NSNull(),
                "toVersion": change.toVersion,
                "addedPermissions": change.addedPermissions,
                "removedPermissions": change.removedPermissions,
                "dataChanged": change.dataChanged,
                "fromLifecycleState": change.fromLifecycleState ?? NSNull(),
                "toLifecycleState": change.toLifecycleState
            ] as [String: Any]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private static func safeArchivePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 1_024,
              value == value.precomposedStringWithCanonicalMapping,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.contains(":"),
              !value.contains("\0") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        if components.first == "data" {
            return components.count == 3
                && validAppID(String(components[1]))
                && components[2] == "state.json"
        }
        guard components.first == "apps", components.count >= 7,
              validAppID(String(components[1])), components[2] == "versions",
              validVersion(String(components[3])),
              components[4].range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              components[5] == "package" else { return false }
        return components.dropFirst(6).allSatisfy {
            $0.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
        }
    }

    private static func validAppID(_ value: String) -> Bool {
        value.count <= 160 && value.range(
            of: "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$",
            options: .regularExpression
        ) != nil
    }

    private static func validVersion(_ value: String) -> Bool {
        value.count <= 64 && value.range(
            of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$",
            options: .regularExpression
        ) != nil
    }

    private static func validDigest(_ value: String) -> Bool {
        value.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private static func validPermission(_ value: String) -> Bool {
        value.count <= 128 && value.range(
            of: "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*)+$",
            options: .regularExpression
        ) != nil
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> Bool {
        PocketAppLifecycleManager.compareSemanticVersions(lhs, rhs) == .orderedAscending
    }

    private static func sha256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func readBoundedFile(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            guard result.count <= maximumBackupFileBytes - chunk.count else {
                throw PocketAppWorkspaceBackupError.invalid("RESTORE_BACKUP_SIZE_EXCEEDED")
            }
            result.append(chunk)
        }
        return result
    }

    private static func digestHex(_ digest: String) -> String {
        String(digest.dropFirst("sha256:".count))
    }

    private func failure(_ code: String) -> PocketAppWorkspaceBackupError {
        .invalid(code)
    }
}
