import Combine
import Foundation

@MainActor
final class PocketAppGenerationController: ObservableObject {
    @Published private(set) var phase: PocketAppGenerationPhase = .idle
    @Published private(set) var pendingProposal: PocketAppLifecycleProposal?
    @Published private(set) var managedPackages: [PocketAppManagedPackage] = []
    @Published private(set) var managementIssues: [PocketAppManagementIssue] = []
    @Published private(set) var appHealth: [PocketAppHealthSnapshot] = []
    @Published private(set) var lastReceipt: PocketAppLifecycleReceipt?
    @Published private(set) var errorCode: String?
    @Published private(set) var pendingAllowsActivation = false

    private let generator: (any PocketAppGenerationAdapter)?
    private let lifecycle: PocketAppLifecycleManager
    private let materializer: PocketAppGenerationMaterializer
    private let pins: [PocketAppPinnedDirectory]
    private let postCommitHook: (() -> Void)?
    private var generationCancellation: PocketAppGenerationCancellation?

    init(
        rootDirectory: URL,
        userDataRoot: URL,
        generationRoot: URL,
        generator: (any PocketAppGenerationAdapter)?,
        postCommitHook: (() -> Void)? = nil,
        runtimeActivationReadback: ((PocketAppLifecycleReceipt) throws -> PocketAppRuntimeReadback)? = nil
    ) throws {
        let definitionPin = try PocketAppPinnedDirectory(url: rootDirectory)
        let userDataPin = try PocketAppPinnedDirectory(url: userDataRoot)
        let generationPin = try PocketAppPinnedDirectory(url: generationRoot)
        self.pins = [definitionPin, userDataPin, generationPin]
        self.generator = generator
        self.postCommitHook = postCommitHook
        self.lifecycle = try PocketAppLifecycleManager(
            rootDirectory: definitionPin.url,
            userDataRoot: userDataPin.url,
            performStartupRecovery: false,
            activationReadback: runtimeActivationReadback
        )
        self.materializer = PocketAppGenerationMaterializer(rootDirectory: generationPin.url)
        try validatePins()
        try refreshManagedPackages()
    }

    var isGeneratorAvailable: Bool { generator != nil }

    func refreshManagedPackages() throws {
        try validatePins()
        let snapshot = try lifecycle.managementSnapshot()
        managedPackages = snapshot.packages.filter { $0.state != .removed }
        managementIssues = snapshot.issues
        appHealth = try lifecycle.healthSnapshots()
        try validatePins()
    }

    func refreshHealth() {
        guard let observed = try? lifecycle.healthSnapshots() else { return }
        appHealth = observed
    }

    func recoverAfterSystemTransition() {
        try? refreshManagedPackages()
    }

    func generate(userRequest: String, updating packageID: String? = nil) async {
        guard phase != .generating, phase != .installing, pendingProposal == nil else {
            fail(.busy)
            return
        }
        guard let generator else {
            fail(.generatorUnavailable)
            return
        }
        do {
            try validatePins()
            try refreshManagedPackages()
            let request = try makeRequest(userRequest: userRequest, updating: packageID)
            let cancellation = PocketAppGenerationCancellation()
            generationCancellation = cancellation
            phase = .generating
            errorCode = nil
            lastReceipt = nil
            let envelope = try await withTaskCancellationHandler(operation: {
                try await Task.detached(priority: .userInitiated) {
                    try generator.generate(request, cancellation: cancellation)
                }.value
            }, onCancel: {
                cancellation.cancel()
            })
            if cancellation.isCancelled { throw PocketAppGenerationError.generatorCancelled }
            let materialized = try materializer.materialize(envelope: envelope, request: request)
            defer { try? FileManager.default.removeItem(at: materialized.directory) }
            let proposal = try lifecycle.stage(draftDirectory: materialized.directory)
            guard proposal.packageID == request.appID,
                  proposal.version == request.version,
                  proposal.packageDigest == materialized.package.manifestDigest,
                  proposal.approvalRequired else {
                throw PocketAppGenerationError.packageInvalid
            }
            try validatePins()
            pendingProposal = proposal
            pendingAllowsActivation = generator.allowsActivation
            phase = .awaitingApproval
            generationCancellation = nil
        } catch let error as PocketAppGenerationError {
            generationCancellation = nil
            fail(error)
        } catch {
            generationCancellation = nil
            fail(.packageInvalid)
        }
    }

    func cancelGeneration() {
        generationCancellation?.cancel()
    }

    func approveAndInstall(requestID: String, bindingDigest: String) {
        guard let proposal = pendingProposal,
              proposal.requestID == requestID,
              proposal.bindingDigest == bindingDigest,
              pendingAllowsActivation else {
            if pendingProposal?.requestID == requestID,
               pendingProposal?.bindingDigest == bindingDigest,
               !pendingAllowsActivation {
                fail(.previewOnly)
                return
            }
            fail(.approvalMismatch)
            return
        }
        do {
            try validatePins()
            try refreshManagedPackages()
            phase = .installing
            let grant = try lifecycle.approve(
                requestID: proposal.requestID,
                bindingDigest: proposal.bindingDigest
            )
            let receipt: PocketAppLifecycleReceipt
            if proposal.action == .rollback {
                receipt = try lifecycle.rollback(proposal, approvalGrant: grant)
            } else {
                receipt = try lifecycle.install(proposal, approvalGrant: grant)
            }
            guard receipt.readbackVerified,
                  receipt.packageID == proposal.packageID,
                  receipt.version == proposal.version,
                  receipt.packageDigest == proposal.packageDigest else {
                throw PocketAppGenerationError.packageInvalid
            }
            recordCommittedReceipt(receipt, phase: .installed, clearPending: true)
            postCommitHook?()
            try refreshManagedPackagesAfterCommit(receipt)
        } catch let error as PocketAppGenerationError {
            discardPendingAfterFailedActivation(proposal)
            refreshManagedPackagesAfterFailure()
            fail(error)
        } catch {
            discardPendingAfterFailedActivation(proposal)
            refreshManagedPackagesAfterFailure()
            fail(.approvalMismatch)
        }
    }

    func rejectPending() {
        guard let proposal = pendingProposal else { return }
        do {
            try lifecycle.reject(requestID: proposal.requestID, bindingDigest: proposal.bindingDigest)
            pendingProposal = nil
            pendingAllowsActivation = false
            phase = .idle
            errorCode = nil
        } catch {
            fail(.approvalMismatch)
        }
    }

    func disable(packageID: String) {
        do {
            try validatePins()
            try refreshManagedPackages()
            guard !managementIssues.contains(where: { $0.packageID == packageID }) else {
                throw PocketAppGenerationError.packageInvalid
            }
            let receipt = try lifecycle.disable(packageID: packageID)
            guard receipt.readbackVerified, receipt.state == .disabled else {
                throw PocketAppGenerationError.packageInvalid
            }
            recordCommittedReceipt(
                receipt,
                phase: .disabled,
                clearPending: false
            )
            postCommitHook?()
            try refreshManagedPackagesAfterCommit(receipt)
        } catch {
            refreshManagedPackagesAfterFailure()
            fail(.packageInvalid)
        }
    }

    func enable(packageID: String) {
        do {
            try validatePins()
            try refreshManagedPackages()
            guard !managementIssues.contains(where: { $0.packageID == packageID }) else {
                throw PocketAppGenerationError.packageInvalid
            }
            let receipt = try lifecycle.enable(packageID: packageID)
            guard receipt.readbackVerified, receipt.state == .enabled else {
                throw PocketAppGenerationError.packageInvalid
            }
            recordCommittedReceipt(
                receipt,
                phase: .installed,
                clearPending: false
            )
            postCommitHook?()
            try refreshManagedPackagesAfterCommit(receipt)
        } catch {
            refreshManagedPackagesAfterFailure()
            fail(.packageInvalid)
        }
    }

    func removePreservingData(packageID: String) {
        do {
            try validatePins()
            try refreshManagedPackages()
            try rejectPendingProposalIfNeeded(for: packageID)
            let receipt = try lifecycle.remove(packageID: packageID, dataDisposition: .preserve)
            guard receipt.readbackVerified,
                  receipt.state == .removed,
                  receipt.dataDisposition == .preserve else {
                throw PocketAppGenerationError.packageInvalid
            }
            recordCommittedReceipt(
                receipt,
                phase: .removed,
                clearPending: false
            )
            postCommitHook?()
            try refreshManagedPackagesAfterCommit(receipt)
        } catch {
            refreshManagedPackagesAfterFailure()
            fail(.packageInvalid)
        }
    }

    func prepareRollback(packageID: String, version: String) {
        guard pendingProposal == nil else {
            fail(.busy)
            return
        }
        do {
            try validatePins()
            let proposal = try lifecycle.prepareRollback(packageID: packageID, version: version)
            guard proposal.approvalRequired else { throw PocketAppGenerationError.packageInvalid }
            pendingProposal = proposal
            pendingAllowsActivation = true
            phase = .awaitingApproval
            errorCode = nil
            lastReceipt = nil
            try validatePins()
        } catch {
            fail(.packageInvalid)
        }
    }

    func prepareCapabilityMigration(packageID: String, targetVersion: String) {
        guard pendingProposal == nil else {
            fail(.busy)
            return
        }
        do {
            try validatePins()
            let proposal = try lifecycle.prepareCapabilityMigration(
                packageID: packageID,
                targetVersion: targetVersion
            )
            guard proposal.approvalRequired else { throw PocketAppGenerationError.packageInvalid }
            pendingProposal = proposal
            pendingAllowsActivation = true
            phase = .awaitingApproval
            errorCode = nil
            lastReceipt = nil
            try validatePins()
        } catch {
            fail(.packageInvalid)
        }
    }

    private func makeRequest(userRequest: String, updating packageID: String?) throws -> PocketAppGenerationRequest {
        let trimmed = userRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.count <= PocketAppGenerationRequest.maximumUserRequestScalars,
              !trimmed.contains("\0") else {
            throw PocketAppGenerationError.invalidRequest
        }
        let appID: String
        let version: String
        if let packageID {
            guard let existing = managedPackages.first(where: { $0.packageID == packageID }),
                  let activeVersion = existing.version else {
                throw PocketAppGenerationError.invalidRequest
            }
            appID = packageID
            version = try Self.nextVersion(
                installedVersions: existing.installedVersions,
                currentVersion: activeVersion
            )
        } else {
            var allocated = Self.freshAppID()
            while managedPackages.contains(where: { $0.packageID == allocated })
                || managementIssues.contains(where: { $0.packageID == allocated }) {
                allocated = Self.freshAppID()
            }
            appID = allocated
            version = "1.0.0"
        }
        let namespace = "today-focus"
        let request = PocketAppGenerationRequest(
            requestID: "generation:\(UUID().uuidString.lowercased())",
            userRequest: trimmed,
            appID: appID,
            version: version,
            namespace: namespace,
            capabilities: PocketAppGenerationCapability.boundedCatalog(namespace: namespace)
        )
        try request.validate()
        return request
    }

    static func nextVersion(installedVersions: [String], currentVersion: String) throws -> String {
        guard let highest = (installedVersions + [currentVersion]).max(by: {
            PocketAppLifecycleManager.compareSemanticVersions($0, $1) == .orderedAscending
        }) else {
            throw PocketAppGenerationError.invalidRequest
        }
        return try nextPatchVersion(highest)
    }

    static func freshAppID() -> String {
        "local.generated.a" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func rollbackVersions(installedVersions: [String], currentVersion: String?) -> [String] {
        guard let currentVersion else { return [] }
        return installedVersions
            .filter {
                PocketAppLifecycleManager.compareSemanticVersions($0, currentVersion) == .orderedAscending
            }
            .sorted {
                PocketAppLifecycleManager.compareSemanticVersions($0, $1) == .orderedAscending
            }
    }

    static func nextPatchVersion(_ value: String) throws -> String {
        let core = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let components = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 3,
              value.unicodeScalars.count <= 64,
              value.range(
                of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$",
                options: .regularExpression
              ) != nil else {
            throw PocketAppGenerationError.invalidRequest
        }
        var digits = Array(components[2].utf8)
        var carry: UInt8 = 1
        for index in digits.indices.reversed() where carry == 1 {
            if digits[index] == 57 {
                digits[index] = 48
            } else {
                digits[index] += 1
                carry = 0
            }
        }
        if carry == 1 { digits.insert(49, at: 0) }
        guard let nextPatch = String(bytes: digits, encoding: .utf8) else {
            throw PocketAppGenerationError.invalidRequest
        }
        let result = "\(components[0]).\(components[1]).\(nextPatch)"
        guard result.unicodeScalars.count <= 64 else {
            throw PocketAppGenerationError.invalidRequest
        }
        return result
    }

    func shutdown() {
        generationCancellation?.cancel()
        if let proposal = pendingProposal {
            try? lifecycle.reject(requestID: proposal.requestID, bindingDigest: proposal.bindingDigest)
            pendingProposal = nil
            pendingAllowsActivation = false
        }
        generationCancellation = nil
        phase = .idle
        errorCode = nil
    }

    private func discardPendingAfterFailedActivation(_ proposal: PocketAppLifecycleProposal) {
        try? lifecycle.reject(requestID: proposal.requestID, bindingDigest: proposal.bindingDigest)
        pendingProposal = nil
        pendingAllowsActivation = false
    }

    private func rejectPendingProposalIfNeeded(for packageID: String) throws {
        guard let proposal = pendingProposal,
              Self.shouldRejectPendingProposal(
                  removingPackageID: packageID,
                  pendingPackageID: proposal.packageID
              ) else { return }
        try lifecycle.reject(requestID: proposal.requestID, bindingDigest: proposal.bindingDigest)
        pendingProposal = nil
        pendingAllowsActivation = false
    }

    private func recordCommittedReceipt(
        _ receipt: PocketAppLifecycleReceipt,
        phase committedPhase: PocketAppGenerationPhase,
        clearPending: Bool
    ) {
        if clearPending {
            pendingProposal = nil
            pendingAllowsActivation = false
        }
        lastReceipt = receipt
        errorCode = nil
        phase = !clearPending && pendingProposal != nil ? .awaitingApproval : committedPhase
        if receipt.state == .removed {
            managedPackages.removeAll { $0.packageID == receipt.packageID }
            managementIssues.removeAll { $0.packageID == receipt.packageID }
            return
        }
        guard let version = receipt.version, let digest = receipt.packageDigest else { return }
        let existing = managedPackages.first { $0.packageID == receipt.packageID }
        let versions = Set((existing?.installedVersions ?? []) + [version]).sorted {
            PocketAppLifecycleManager.compareSemanticVersions($0, $1) == .orderedAscending
        }
        let observed = PocketAppManagedPackage(
            packageID: receipt.packageID,
            state: receipt.state,
            version: version,
            packageDigest: digest,
            installedVersions: versions
        )
        managedPackages.removeAll { $0.packageID == receipt.packageID }
        managedPackages.append(observed)
        managedPackages.sort { $0.packageID < $1.packageID }
        managementIssues.removeAll { $0.packageID == receipt.packageID }
    }

    private func refreshManagedPackagesAfterCommit(_ receipt: PocketAppLifecycleReceipt) throws {
        try validatePins()
        guard let target = try lifecycle.managedPackage(packageID: receipt.packageID),
              target.state == receipt.state,
              target.version == receipt.version,
              target.packageDigest == receipt.packageDigest else {
            throw PocketAppGenerationError.packageInvalid
        }
        let snapshot = try lifecycle.managementSnapshot()
        managedPackages = snapshot.packages.filter { $0.state != .removed }
        managementIssues = snapshot.issues
        appHealth = try lifecycle.healthSnapshots()
        try validatePins()
    }

    private func refreshManagedPackagesAfterFailure() {
        try? refreshManagedPackages()
    }

    static func shouldRejectPendingProposal(
        removingPackageID: String,
        pendingPackageID: String
    ) -> Bool {
        removingPackageID == pendingPackageID
    }

    private func validatePins() throws {
        do {
            for pin in pins { try pin.validate() }
        } catch {
            throw PocketAppGenerationError.rootUnsafe
        }
    }

    private func fail(_ error: PocketAppGenerationError) {
        errorCode = error.code
        phase = .failed
    }
}
