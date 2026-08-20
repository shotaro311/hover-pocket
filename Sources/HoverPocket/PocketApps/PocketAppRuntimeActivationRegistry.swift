import Combine
import Foundation

struct PocketAppRuntimeReadback: Equatable, Sendable {
    let appID: String
    let version: String?
    let packageDigest: String?
    let effectivePermissions: [String]

    init(
        appID: String,
        version: String?,
        packageDigest: String?,
        effectivePermissions: [String]
    ) {
        self.appID = appID
        self.version = version
        self.packageDigest = packageDigest
        self.effectivePermissions = effectivePermissions.sorted()
    }

    func matches(_ receipt: PocketAppLifecycleReceipt) -> Bool {
        appID == receipt.packageID
            && version == receipt.version
            && packageDigest == receipt.packageDigest
            && effectivePermissions == receipt.effectivePermissions.sorted()
    }
}

enum PocketAppRuntimeActivationError: Error, Equatable {
    case reservedIdentity
    case unavailable
    case readbackMismatch
}

@MainActor
final class PocketAppActivationLease {
    private(set) var isActive = true
    private var cancellationHandlers: [UUID: () -> Void] = [:]

    func requireActive() throws {
        guard isActive else { throw PocketAppRuntimeActivationError.unavailable }
    }

    func invalidate() {
        guard isActive else { return }
        isActive = false
        let handlers = Array(cancellationHandlers.values)
        cancellationHandlers.removeAll()
        handlers.forEach { $0() }
    }

    func registerCancellation(_ handler: @escaping () -> Void) -> UUID? {
        guard isActive else {
            handler()
            return nil
        }
        let id = UUID()
        cancellationHandlers[id] = handler
        return id
    }

    func unregisterCancellation(_ id: UUID?) {
        guard let id else { return }
        cancellationHandlers.removeValue(forKey: id)
    }
}

@MainActor
final class PocketExecutionRuntimeRegistry {
    private struct Entry {
        let readback: PocketAppRuntimeReadback
        let runtimeHandle: AnyObject
        let activationLease: PocketAppActivationLease?
    }

    private var entries: [String: Entry] = [:]

    var activeAppIDs: [String] { entries.keys.sorted() }

    func runtime(appID: String) -> PocketAppExecutionRuntime? {
        entries[appID]?.runtimeHandle as? PocketAppExecutionRuntime
    }

    func readback(appID: String) -> PocketAppRuntimeReadback? {
        entries[appID]?.readback
    }

    fileprivate func activate(
        _ readback: PocketAppRuntimeReadback,
        runtimeHandle: AnyObject,
        activationLease: PocketAppActivationLease?
    ) {
        entries[readback.appID]?.activationLease?.invalidate()
        entries[readback.appID] = Entry(
            readback: readback,
            runtimeHandle: runtimeHandle,
            activationLease: activationLease
        )
    }

    fileprivate func deactivate(appID: String) {
        entries.removeValue(forKey: appID)?.activationLease?.invalidate()
    }
}

@MainActor
final class PocketSurfaceRegistry: ObservableObject {
    struct Route: Equatable, Sendable {
        let appID: String
        let providerID: String
        let surfaceID: String
        let title: String
    }

    private final class Entry {
        private final class WeakModel {
            weak var value: PocketSurfaceHostModel?

            init(_ value: PocketSurfaceHostModel) {
                self.value = value
            }
        }

        let readback: PocketAppRuntimeReadback
        let runtimeHandle: AnyObject
        let surfaceIDs: Set<String>
        private var models: [String: [WeakModel]] = [:]

        init(
            readback: PocketAppRuntimeReadback,
            runtimeHandle: AnyObject,
            surfaceIDs: Set<String>
        ) {
            self.readback = readback
            self.runtimeHandle = runtimeHandle
            self.surfaceIDs = surfaceIDs
        }

        @MainActor
        func invalidate() {
            models.values
                .flatMap { $0 }
                .compactMap(\.value)
                .forEach { $0.invalidateActivation() }
            models.removeAll()
        }

        @MainActor
        func makeModel(surfaceID: String) throws -> PocketSurfaceHostModel? {
            guard let runtime = runtimeHandle as? PocketAppExecutionRuntime else { return nil }
            let model = try PocketSurfaceHostModel(runtime: runtime, surfaceID: surfaceID)
            models[surfaceID] = (models[surfaceID] ?? [])
                .filter { $0.value != nil } + [WeakModel(model)]
            return model
        }
    }

    private var entries: [String: Entry] = [:]
    @Published private(set) var revision = 0

    var activeAppIDs: [String] { entries.keys.sorted() }

    var routes: [Route] {
        entries.values.compactMap { entry in
            guard let surfaceID = entry.surfaceIDs.contains("main")
                    ? "main"
                    : entry.surfaceIDs.sorted().first else { return nil }
            let title = (entry.runtimeHandle as? PocketAppExecutionRuntime)?.package.manifest.name
                ?? entry.readback.appID
            return Route(
                appID: entry.readback.appID,
                providerID: Self.generatedProviderID(appID: entry.readback.appID),
                surfaceID: surfaceID,
                title: title
            )
        }.sorted { $0.providerID < $1.providerID }
    }

    func model(appID: String, surfaceID: String) throws -> PocketSurfaceHostModel? {
        guard let entry = entries[appID], entry.surfaceIDs.contains(surfaceID) else { return nil }
        return try entry.makeModel(surfaceID: surfaceID)
    }

    func readback(appID: String) -> PocketAppRuntimeReadback? {
        entries[appID]?.readback
    }

    nonisolated static func generatedProviderID(appID: String) -> String {
        "generated-pocket-app:\(appID)"
    }

    nonisolated static func generatedAppID(providerID: String) -> String? {
        let prefix = "generated-pocket-app:"
        guard providerID.hasPrefix(prefix) else { return nil }
        let appID = String(providerID.dropFirst(prefix.count))
        guard appID.unicodeScalars.count <= 160,
              appID.range(
                  of: "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$",
                  options: .regularExpression
              ) != nil else {
            return nil
        }
        return appID
    }

    nonisolated static func generatedSurfaceRouteID(appID: String, surfaceID: String) -> String {
        "\(generatedProviderID(appID: appID))/\(surfaceID)"
    }

    func activate(
        _ readback: PocketAppRuntimeReadback,
        runtimeHandle: AnyObject,
        surfaceIDs: Set<String>
    ) {
        entries.removeValue(forKey: readback.appID)?.invalidate()
        entries[readback.appID] = Entry(
            readback: readback,
            runtimeHandle: runtimeHandle,
            surfaceIDs: surfaceIDs
        )
        revision &+= 1
    }

    func deactivate(appID: String) {
        guard let entry = entries.removeValue(forKey: appID) else { return }
        entry.invalidate()
        revision &+= 1
    }
}

@MainActor
final class PocketAppRuntimeActivationRegistry {
    struct Candidate {
        let readback: PocketAppRuntimeReadback
        let runtimeHandle: AnyObject
        let activationLease: PocketAppActivationLease?
        let surfaceIDs: Set<String>
    }

    typealias ManagementSnapshotSource = () throws -> PocketAppManagementSnapshot
    typealias ManagedPackagesSource = () throws -> [PocketAppManagedPackage]
    typealias ManagementIssuesSource = () throws -> [PocketAppManagementIssue]
    typealias CandidateSource = (String) throws -> Candidate?
    typealias RestoreFailurePersistence = (String) -> Bool

    let executionRegistry = PocketExecutionRuntimeRegistry()
    let surfaceRegistry = PocketSurfaceRegistry()

    private let sourceLifecycle: PocketAppLifecycleManager?
    private let managementSnapshotSource: ManagementSnapshotSource
    private let candidateSource: CandidateSource
    private let restoreFailurePersistence: RestoreFailurePersistence
    private let failureInjection: ((String) -> Bool)?
    private let reservedAppIDs: Set<String>

    init(
        rootDirectory: URL,
        userDataRoot: URL,
        broker: CapabilityBroker,
        userID: String,
        failureInjection: ((String) -> Bool)? = nil
    ) throws {
        let lifecycle = try PocketAppLifecycleManager(
            rootDirectory: rootDirectory,
            userDataRoot: userDataRoot,
            performStartupRecovery: true
        )
        self.sourceLifecycle = lifecycle
        self.managementSnapshotSource = lifecycle.managementSnapshot
        self.candidateSource = { packageID in
            guard let package = try lifecycle.activePackageForActivation(packageID: packageID) else {
                return nil
            }
            let effectivePermissions = package.manifest.requestedCapabilities.reduce(into: Set<String>()) {
                $0.formUnion($1.permissions)
            }
            let stateStore = try PocketAppUserStateStore(
                packageID: package.manifest.id,
                propertyTypes: package.statePropertyTypes,
                rootDirectory: userDataRoot
            )
            let activationLease = PocketAppActivationLease()
            let runtime = PocketAppExecutionRuntime(
                package: package,
                broker: broker,
                userID: userID,
                grantedPermissions: effectivePermissions,
                userStateStore: stateStore,
                activationLease: activationLease
            )
            return Candidate(
                readback: PocketAppRuntimeReadback(
                    appID: package.manifest.id,
                    version: package.manifest.version,
                    packageDigest: package.manifestDigest,
                    effectivePermissions: effectivePermissions.sorted()
                ),
                runtimeHandle: runtime,
                activationLease: activationLease,
                surfaceIDs: Set(package.surfaces.keys)
            )
        }
        self.restoreFailurePersistence = { packageID in
            do {
                let receipt = try lifecycle.disable(packageID: packageID)
                guard let observed = try lifecycle.durableManagedPackage(packageID: packageID) else {
                    return false
                }
                return receipt.state == .disabled
                    && receipt.effectivePermissions.isEmpty
                    && observed.state == .disabled
                    && observed.version == receipt.version
                    && observed.packageDigest == receipt.packageDigest
            } catch {
                return false
            }
        }
        self.failureInjection = failureInjection
        self.reservedAppIDs = ["local.example.today-focus"]
    }

    init(
        managedPackagesSource: @escaping ManagedPackagesSource,
        managementIssuesSource: @escaping ManagementIssuesSource = { [] },
        candidateSource: @escaping CandidateSource,
        reservedAppIDs: Set<String> = ["local.example.today-focus"],
        restoreFailurePersistence: @escaping RestoreFailurePersistence = { _ in false },
        failureInjection: ((String) -> Bool)? = nil
    ) {
        self.sourceLifecycle = nil
        self.managementSnapshotSource = {
            PocketAppManagementSnapshot(
                packages: try managedPackagesSource(),
                issues: try managementIssuesSource()
            )
        }
        self.candidateSource = candidateSource
        self.restoreFailurePersistence = restoreFailurePersistence
        self.failureInjection = failureInjection
        self.reservedAppIDs = reservedAppIDs
    }

    @discardableResult
    func synchronize(_ receipt: PocketAppLifecycleReceipt) throws -> PocketAppRuntimeReadback {
        guard !reservedAppIDs.contains(receipt.packageID) else {
            failClosed(appID: receipt.packageID)
            throw PocketAppRuntimeActivationError.reservedIdentity
        }

        switch receipt.state {
        case .enabled:
            guard let candidate = try candidateSource(receipt.packageID),
                  candidate.readback.matches(receipt) else {
                failClosed(appID: receipt.packageID)
                throw PocketAppRuntimeActivationError.readbackMismatch
            }
            return try activate(candidate, expected: candidate.readback)

        case .disabled, .removed:
            guard receipt.effectivePermissions.isEmpty else {
                failClosed(appID: receipt.packageID)
                throw PocketAppRuntimeActivationError.readbackMismatch
            }
            failClosed(appID: receipt.packageID)
            guard executionRegistry.readback(appID: receipt.packageID) == nil,
                  surfaceRegistry.readback(appID: receipt.packageID) == nil else {
                throw PocketAppRuntimeActivationError.readbackMismatch
            }
            return PocketAppRuntimeReadback(
                appID: receipt.packageID,
                version: receipt.version,
                packageDigest: receipt.packageDigest,
                effectivePermissions: []
            )
        }
    }

    @discardableResult
    func restoreEnabledApps() -> [String] {
        let snapshot: PocketAppManagementSnapshot
        do {
            snapshot = try managementSnapshotSource()
        } catch {
            return ["*"]
        }

        var failures = snapshot.issues.map(\.packageID)
        for issue in snapshot.issues {
            failClosed(appID: issue.packageID)
            _ = restoreFailurePersistence(issue.packageID)
        }
        for package in snapshot.packages.sorted(by: { $0.packageID < $1.packageID }) {
            guard package.state == .enabled else {
                failClosed(appID: package.packageID)
                continue
            }
            do {
                guard !reservedAppIDs.contains(package.packageID),
                      let candidate = try candidateSource(package.packageID),
                      candidate.readback.appID == package.packageID,
                      candidate.readback.version == package.version,
                      candidate.readback.packageDigest == package.packageDigest else {
                    throw PocketAppRuntimeActivationError.readbackMismatch
                }
                _ = try activate(candidate, expected: candidate.readback)
            } catch {
                failClosed(appID: package.packageID)
                _ = restoreFailurePersistence(package.packageID)
                failures.append(package.packageID)
            }
        }
        return Array(Set(failures)).sorted()
    }

    func managedAppIDs() throws -> Set<String> {
        Set(
            try managementSnapshotSource().packages.compactMap { package in
                package.state == .removed ? nil : package.packageID
            }
        )
    }

    func shutdown() {
        let appIDs = Set(executionRegistry.activeAppIDs).union(surfaceRegistry.activeAppIDs)
        for appID in appIDs {
            failClosed(appID: appID)
        }
    }

    private func activate(
        _ candidate: Candidate,
        expected: PocketAppRuntimeReadback
    ) throws -> PocketAppRuntimeReadback {
        if failureInjection?("before_runtime_registry_commit") == true {
            failClosed(appID: expected.appID)
            throw PocketAppRuntimeActivationError.unavailable
        }

        executionRegistry.activate(
            expected,
            runtimeHandle: candidate.runtimeHandle,
            activationLease: candidate.activationLease
        )
        surfaceRegistry.activate(
            expected,
            runtimeHandle: candidate.runtimeHandle,
            surfaceIDs: candidate.surfaceIDs
        )

        if failureInjection?("runtime_readback_mismatch") == true
            || executionRegistry.readback(appID: expected.appID) != expected
            || surfaceRegistry.readback(appID: expected.appID) != expected {
            failClosed(appID: expected.appID)
            throw PocketAppRuntimeActivationError.readbackMismatch
        }

        return expected
    }

    private func failClosed(appID: String) {
        surfaceRegistry.deactivate(appID: appID)
        executionRegistry.deactivate(appID: appID)
    }
}
