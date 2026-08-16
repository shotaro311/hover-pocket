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
final class PocketSurfaceRegistry {
    private final class Entry {
        let readback: PocketAppRuntimeReadback
        let runtimeHandle: AnyObject
        let surfaceIDs: Set<String>
        var models: [String: PocketSurfaceHostModel] = [:]

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
            models.values.forEach { $0.invalidateActivation() }
            models.removeAll()
        }
    }

    private var entries: [String: Entry] = [:]

    var activeAppIDs: [String] { entries.keys.sorted() }

    func model(appID: String, surfaceID: String) throws -> PocketSurfaceHostModel? {
        guard let entry = entries[appID], entry.surfaceIDs.contains(surfaceID) else { return nil }
        if let model = entry.models[surfaceID] { return model }
        guard let runtime = entry.runtimeHandle as? PocketAppExecutionRuntime else { return nil }
        let model = try PocketSurfaceHostModel(runtime: runtime, surfaceID: surfaceID)
        entry.models[surfaceID] = model
        return model
    }

    func readback(appID: String) -> PocketAppRuntimeReadback? {
        entries[appID]?.readback
    }

    static func generatedProviderID(appID: String) -> String {
        "generated-pocket-app:\(appID)"
    }

    static func generatedSurfaceRouteID(appID: String, surfaceID: String) -> String {
        "\(generatedProviderID(appID: appID))/\(surfaceID)"
    }

    fileprivate func activate(
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
    }

    fileprivate func deactivate(appID: String) {
        entries.removeValue(forKey: appID)?.invalidate()
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

    typealias ManagedPackagesSource = () throws -> [PocketAppManagedPackage]
    typealias CandidateSource = (String) throws -> Candidate?

    let executionRegistry = PocketExecutionRuntimeRegistry()
    let surfaceRegistry = PocketSurfaceRegistry()

    private let sourceLifecycle: PocketAppLifecycleManager?
    private let managedPackagesSource: ManagedPackagesSource
    private let candidateSource: CandidateSource
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
        self.managedPackagesSource = {
            try lifecycle.managedPackages()
        }
        self.candidateSource = { packageID in
            guard let package = try lifecycle.activePackageForActivation(packageID: packageID) else {
                return nil
            }
            let effectivePermissions = package.manifest.requestedCapabilities.reduce(into: Set<String>()) {
                $0.formUnion($1.permissions)
            }
            let stateStore = try PocketAppUserStateStore(
                packageID: package.manifest.id,
                allowedKeys: package.statePropertyNames,
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
        self.failureInjection = failureInjection
        self.reservedAppIDs = ["local.example.today-focus"]
    }

    init(
        managedPackagesSource: @escaping ManagedPackagesSource,
        candidateSource: @escaping CandidateSource,
        reservedAppIDs: Set<String> = ["local.example.today-focus"],
        failureInjection: ((String) -> Bool)? = nil
    ) {
        self.sourceLifecycle = nil
        self.managedPackagesSource = managedPackagesSource
        self.candidateSource = candidateSource
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
        var failures: [String] = []
        let managed: [PocketAppManagedPackage]
        do {
            managed = try managedPackagesSource()
        } catch {
            return ["*"]
        }

        for package in managed.sorted(by: { $0.packageID < $1.packageID }) {
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
                failures.append(package.packageID)
            }
        }
        return failures
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
