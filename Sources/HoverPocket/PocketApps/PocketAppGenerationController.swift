import Combine
import Foundation

@MainActor
final class PocketAppGenerationController: ObservableObject {
    @Published private(set) var phase: PocketAppGenerationPhase = .idle
    @Published private(set) var pendingProposal: PocketAppLifecycleProposal?
    @Published private(set) var uninstalledPackages: [PocketAppManagedPackage] = []
    @Published private(set) var removalMessage: String?
    @Published private(set) var managedPackages: [PocketAppManagedPackage] = []
    @Published private(set) var packageNames: [String: String] = [:]
    @Published private(set) var managementIssues: [PocketAppManagementIssue] = []
    @Published private(set) var appHealth: [PocketAppHealthSnapshot] = []
    @Published private(set) var lastReceipt: PocketAppLifecycleReceipt?
    @Published private(set) var errorCode: String?
    @Published private(set) var pendingAllowsActivation = false
    @Published private(set) var pendingWorkspaceRestore: PocketAppWorkspaceRestoreProposal?
    @Published private(set) var lastWorkspaceBackupDigest: String?
    @Published private(set) var lastWorkspaceRestoreReceipt: PocketAppWorkspaceRestoreReceipt?
    @Published private(set) var workspaceBackupErrorCode: String?
    @Published private(set) var supportedReasoningEfforts: [String] = []
    @Published private(set) var generatorStatus: String?
    @Published private(set) var history: [PocketToolCheckpoint] = []
    @Published private(set) var historyIssue: String?
    @Published private(set) var draftCheckpoint: PocketToolCheckpoint?
    @Published private(set) var previewModel: PocketSurfaceHostModel?

    private let generator: (any PocketAppGenerationAdapter)?
    private let lifecycle: PocketAppLifecycleManager
    private let materializer: PocketAppGenerationMaterializer
    private let workspaceBackupManager: PocketAppWorkspaceBackupManager
    private let pins: [PocketAppPinnedDirectory]
    private let postCommitHook: (() -> Void)?
    private var generationCancellation: PocketAppGenerationCancellation?
    private let generationSettings: AppSettings?
    private let historyStore: PocketToolHistoryStore
    private let previewFactory: ((PocketAppPackage, URL) throws -> PocketSurfaceHostModel)?
    private let previewDataRoot: URL

    init(
        rootDirectory: URL,
        userDataRoot: URL,
        generationRoot: URL,
        generator: (any PocketAppGenerationAdapter)?,
        postCommitHook: (() -> Void)? = nil,
        runtimeActivationReadback: ((PocketAppLifecycleReceipt) throws -> PocketAppRuntimeReadback)? = nil,
        generationSettings: AppSettings? = nil,
        previewFactory: ((PocketAppPackage, URL) throws -> PocketSurfaceHostModel)? = nil
    ) throws {
        let definitionPin = try PocketAppPinnedDirectory(url: rootDirectory)
        let userDataPin = try PocketAppPinnedDirectory(url: userDataRoot)
        let generationPin = try PocketAppPinnedDirectory(url: generationRoot)
        self.pins = [definitionPin, userDataPin, generationPin]
        self.generator = generator
        self.generationSettings = generationSettings
        self.previewFactory = previewFactory
        self.previewDataRoot = generationPin.url.appendingPathComponent("PreviewData")
        self.historyStore = try PocketToolHistoryStore(rootDirectory: generationPin.url.appendingPathComponent("History"))
        self.postCommitHook = postCommitHook
        self.lifecycle = try PocketAppLifecycleManager(
            rootDirectory: definitionPin.url,
            userDataRoot: userDataPin.url,
            performStartupRecovery: false,
            activationReadback: runtimeActivationReadback
        )
        self.materializer = PocketAppGenerationMaterializer(rootDirectory: generationPin.url)
        self.workspaceBackupManager = try PocketAppWorkspaceBackupManager(
            definitionRoot: definitionPin.url,
            userDataRoot: userDataPin.url,
            transactionRoot: definitionPin.url.appendingPathComponent("BackupRestore", isDirectory: true),
            lifecycle: self.lifecycle,
            runtimeReadback: runtimeActivationReadback
        )
        try validatePins()
        try refreshManagedPackages()
        refreshHistory()
    }

    func packageTitle(_ packageID: String) -> String {
        packageNames[packageID] ?? history.first(where: { $0.packageID == packageID })?.name ?? "個人用ツール"
    }

    var errorMessage: String? {
        guard let errorCode else { return nil }
        switch errorCode {
        case "GENERATION_REQUEST_INVALID": return "作りたいツールや修正したい内容を、もう少し短く具体的に入力してください。"
        case "GENERATOR_UNAVAILABLE": return "選択中のAstra設定を利用できません。ログインと推論設定を確認してください。"
        case "GENERATOR_TIMEOUT": return "生成に時間がかかりすぎたため停止しました。直前のツールは保持しています。"
        case "GENERATOR_CANCELLED": return "生成をキャンセルしました。直前のツールは保持しています。"
        case "GENERATOR_PROCESS_FAILED": return "生成の接続が終了しました。ログインと接続を確認してから、もう一度お試しください。"
        case "GENERATOR_OUTPUT_LIMIT": return "生成内容または履歴が保存上限を超えました。変更を小さく分けてください。"
        case "GENERATION_BUSY": return "実行中の処理が終わるまでお待ちください。"
        case "GENERATION_APPROVAL_MISMATCH": return "確認した後に状態が変わりました。更新内容をもう一度確認してください。"
        case "GENERATION_PREVIEW_ONLY": return "この候補はプレビュー専用です。"
        case "GENERATION_ROOT_UNSAFE": return "保存先の安全性を確認できませんでした。アプリを開き直してください。"
        default: return "生成内容の検証を通過できませんでした。直前のツールを保持しています。修正したい内容を追加してお試しください。"
        }
    }

    var isGeneratorAvailable: Bool { generator != nil }

    func refreshGeneratorModels() async {
        guard let generator = generator as? CodexAppServerPocketGenerator else { return }
        do {
            supportedReasoningEfforts = try await generator.supportedEfforts()
            generatorStatus = nil
        } catch {
            supportedReasoningEfforts = []
            generatorStatus = "Astraの利用情報を取得できません。Codexへのログインと接続を確認してください。"
        }
    }

    func refreshHistory() {
        do { history = try historyStore.list(); historyIssue = nil }
        catch { historyIssue = "変更履歴を読み込めませんでした。履歴ファイルは保持しています。" }
    }

    func startNewDraft() {
        guard phase != .generating, phase != .installing else { return }
        removalMessage = nil
        rejectPending()
        previewModel?.invalidateActivation()
        previewModel = nil
        draftCheckpoint = nil
        clearPreviewData()
        phase = .idle
    }

    private func clearPreviewData() {
        guard FileManager.default.fileExists(atPath: previewDataRoot.path) else { return }
        do {
            _ = try PocketAppPinnedDirectory(url: previewDataRoot)
            try FileManager.default.trashItem(at: previewDataRoot, resultingItemURL: nil)
        } catch { historyIssue = "試し入力の整理に失敗しました。データはそのまま保持しています。" }
    }

    func restoreCheckpoint(_ checkpoint: PocketToolCheckpoint) {
        guard phase != .generating, phase != .installing, pendingWorkspaceRestore == nil else { return }
        do {
            let source = try historyStore.package(for: checkpoint)
            let files = try PocketAppFileSnapshot.capture(directory: source.rootDirectory).files
            let current = managedPackages.first { $0.packageID == checkpoint.packageID }
            let version = try current.map { try Self.nextVersion(installedVersions: $0.installedVersions,
                currentVersion: $0.version ?? checkpoint.version) } ?? checkpoint.version
            let namespace = source.manifest.requestedCapabilities.compactMap { item -> String? in
                guard case .object(let scope)? = item.scope, case .string(let name)? = scope["namespace"] else { return nil }
                return name
            }.first ?? "tool-history"
            let request = PocketAppGenerationRequest(requestID: "restore:\(UUID().uuidString.lowercased())",
                userRequest: "履歴から復元", appID: checkpoint.packageID, version: version, namespace: namespace,
                capabilities: PocketAppGenerationCapability.boundedCatalog(namespace: namespace))
            let generatedFiles = try files.map { path, data -> PocketAppGeneratedFile in
                var data = data
                if path == "manifest.json" {
                    guard var manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PocketToolHistoryError.invalid }
                    manifest["version"] = version
                    data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
                }
                guard let utf8 = String(data: data, encoding: .utf8) else { throw PocketToolHistoryError.invalid }
                return PocketAppGeneratedFile(path: path, utf8: utf8)
            }
            let envelope = PocketAppGenerationEnvelope(requestID: request.requestID, requestDigest: request.requestDigest,
                appID: request.appID, version: version, namespace: namespace, files: generatedFiles)
            let result = try materializer.materialize(envelope: envelope, request: request)
            defer { try? FileManager.default.removeItem(at: result.directory) }
            try presentDraft(result.package, summary: "履歴を復元: " + checkpoint.summary, kind: "restored", allowsActivation: true)
        } catch PocketAppLifecycleError.migrationRequired {
            historyIssue = "この履歴は現在の保存項目と異なります。データ移行の確認が必要です。現在のデータは変更していません。"
        } catch { historyIssue = "履歴を復元できませんでした。直前の画面と保存データは保持しています。" }
    }

    private func presentDraft(_ package: PocketAppPackage, summary: String, kind: String = "preview", allowsActivation: Bool) throws {
        let proposal = try lifecycle.stage(draftDirectory: package.rootDirectory)
        do {
            let model = try previewFactory?(package, previewDataRoot)
            let installedDigest = managedPackages.first { $0.packageID == package.manifest.id }?.packageDigest
            let packageBytes = try PocketAppFileSnapshot.capture(directory: package.rootDirectory).files.values.reduce(0) { $0 + $1.count }
            let reservedBytes = try lifecycle.installedDefinitionBytes(packageID: package.manifest.id) + packageBytes
            let checkpoint = try historyStore.record(package: package, summary: summary, kind: kind,
                installedDigest: installedDigest, reservedDefinitionBytes: reservedBytes)
            if let old = pendingProposal { try lifecycle.reject(requestID: old.requestID, bindingDigest: old.bindingDigest) }
            previewModel?.invalidateActivation()
            previewModel = model
            draftCheckpoint = checkpoint
            pendingProposal = proposal
            pendingAllowsActivation = allowsActivation
            phase = .awaitingApproval
            errorCode = nil
            refreshHistory()
        } catch {
            try? lifecycle.reject(requestID: proposal.requestID, bindingDigest: proposal.bindingDigest)
            throw error
        }
    }

    func refreshManagedPackages() throws {
        try validatePins()
        let snapshot = try lifecycle.managementSnapshot()
        managedPackages = snapshot.packages.filter { $0.state != .removed }
        uninstalledPackages = snapshot.packages.filter { $0.state == .removed }
        for package in managedPackages {
            if let definition = try? lifecycle.currentPackage(packageID: package.packageID, includingDisabled: true) {
                packageNames[package.packageID] = definition.manifest.name
            }
        }
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

    func exportWorkspace(to destination: URL) {
        guard pendingWorkspaceRestore == nil,
              pendingProposal == nil,
              phase != .generating,
              phase != .installing else {
            workspaceBackupErrorCode = "BACKUP_BUSY"
            return
        }
        do {
            try validatePins()
            let digest = try workspaceBackupManager.export(to: destination)
            lastWorkspaceBackupDigest = digest
            lastWorkspaceRestoreReceipt = nil
            workspaceBackupErrorCode = nil
            try validatePins()
        } catch let error as PocketAppWorkspaceBackupError {
            workspaceBackupErrorCode = error.description
        } catch {
            workspaceBackupErrorCode = "BACKUP_EXPORT_FAILED"
        }
    }

    func prepareWorkspaceRestore(from source: URL) {
        guard pendingWorkspaceRestore == nil, pendingProposal == nil, phase != .generating, phase != .installing else {
            workspaceBackupErrorCode = "RESTORE_BUSY"
            return
        }
        do {
            try validatePins()
            pendingWorkspaceRestore = try workspaceBackupManager.prepareRestore(from: source)
            lastWorkspaceRestoreReceipt = nil
            workspaceBackupErrorCode = nil
            try validatePins()
        } catch let error as PocketAppWorkspaceBackupError {
            workspaceBackupErrorCode = error.description
        } catch {
            workspaceBackupErrorCode = "RESTORE_PREVIEW_FAILED"
        }
    }

    func approveWorkspaceRestore() {
        guard let proposal = pendingWorkspaceRestore else {
            workspaceBackupErrorCode = "RESTORE_APPROVAL_INVALID"
            return
        }
        do {
            try validatePins()
            let grant = try workspaceBackupManager.approve(
                requestID: proposal.requestID,
                bindingDigest: proposal.bindingDigest
            )
            let receipt = try workspaceBackupManager.restore(proposal, grant: grant)
            guard receipt.readbackVerified else {
                throw PocketAppWorkspaceBackupError.invalid("RESTORE_READBACK_MISMATCH")
            }
            pendingWorkspaceRestore = nil
            lastWorkspaceRestoreReceipt = receipt
            lastWorkspaceBackupDigest = receipt.backupDigest
            workspaceBackupErrorCode = nil
            postCommitHook?()
            try refreshManagedPackages()
            try validatePins()
        } catch let error as PocketAppWorkspaceBackupError {
            try? workspaceBackupManager.reject(
                requestID: proposal.requestID,
                bindingDigest: proposal.bindingDigest
            )
            pendingWorkspaceRestore = nil
            workspaceBackupErrorCode = error.description
            refreshManagedPackagesAfterFailure()
        } catch {
            try? workspaceBackupManager.reject(
                requestID: proposal.requestID,
                bindingDigest: proposal.bindingDigest
            )
            pendingWorkspaceRestore = nil
            workspaceBackupErrorCode = "RESTORE_COMMIT_FAILED"
            refreshManagedPackagesAfterFailure()
        }
    }

    func rejectWorkspaceRestore() {
        guard let proposal = pendingWorkspaceRestore else { return }
        do {
            try workspaceBackupManager.reject(
                requestID: proposal.requestID,
                bindingDigest: proposal.bindingDigest
            )
            pendingWorkspaceRestore = nil
            workspaceBackupErrorCode = nil
        } catch let error as PocketAppWorkspaceBackupError {
            workspaceBackupErrorCode = error.description
        } catch {
            workspaceBackupErrorCode = "RESTORE_REJECTION_FAILED"
        }
    }

    func generate(userRequest: String, updating packageID: String? = nil) async {
        guard phase != .generating,
              phase != .installing,
              (pendingProposal == nil || draftCheckpoint != nil),
              pendingWorkspaceRestore == nil else {
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
                    try await generator.generate(request, cancellation: cancellation)
                }.value
            }, onCancel: {
                cancellation.cancel()
            })
            if cancellation.isCancelled { throw PocketAppGenerationError.generatorCancelled }
            let materialized = try materializer.materialize(envelope: envelope, request: request)
            defer { try? FileManager.default.removeItem(at: materialized.directory) }
            try validatePins()
            try presentDraft(materialized.package, summary: userRequest, allowsActivation: generator.allowsActivation)
            generationCancellation = nil
        } catch PocketToolHistoryError.capacityExceeded {
            generationCancellation = nil
            historyIssue = "保護中の履歴が保存上限に達しました。履歴を整理してからもう一度生成してください。"
            fail(.outputLimitExceeded)
        } catch PocketAppLifecycleError.migrationRequired {
            generationCancellation = nil
            historyIssue = "入力済みの値をそのまま移せない項目変更が含まれています。新しい必須項目を任意にするなど、移行方法を指定して修正してください。現在のデータは保持しています。"
            fail(.packageInvalid)
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
            if let package = try lifecycle.currentPackage(packageID: receipt.packageID, includingDisabled: true) {
                do {
                    try lifecycle.retainCurrentAndPreviousDefinition(packageID: receipt.packageID, previousDigest: proposal.currentDigest)
                    try historyStore.record(package: package, summary: "導入済み", kind: "installed", installedDigest: receipt.packageDigest,
                        reservedDefinitionBytes: lifecycle.installedDefinitionBytes(packageID: receipt.packageID))
                    refreshHistory()
                } catch { historyIssue = "導入は完了しましたが、履歴への記録ができませんでした。" }
            }
            previewModel?.invalidateActivation()
            previewModel = nil
            draftCheckpoint = nil
            clearPreviewData()
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
        guard pendingWorkspaceRestore == nil else {
            workspaceBackupErrorCode = "RESTORE_BUSY"
            return
        }
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
        guard pendingWorkspaceRestore == nil else {
            workspaceBackupErrorCode = "RESTORE_BUSY"
            return
        }
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

    var managementIsBusy: Bool {
        phase == .generating || phase == .installing || pendingWorkspaceRestore != nil
    }

    func removeTool(packageID: String, includingData: Bool) {
        guard !managementIsBusy, packageID != "local.example.today-focus" else { return }
        removalMessage = nil
        if draftCheckpoint?.packageID == packageID { startNewDraft() }
        removePreservingData(packageID: packageID)
        guard lastReceipt?.packageID == packageID, lastReceipt?.state == .removed, errorCode == nil else { return }
        guard includingData else {
            removalMessage = "アンインストールしました。記録と作成履歴は残っています。"
            try? refreshManagedPackages()
            return
        }
        do {
            try historyStore.withRemovalLock {
                try PocketToolDataLock.withLock(rootDirectory: pins[1].url, packageID: packageID) {
                    try PocketToolRemoval(definitionRoot: pins[0].url, userDataRoot: pins[1].url,
                                          generationRoot: pins[2].url).removeDataAndHistory(packageID: packageID)
                }
            }
            refreshHistory()
            try refreshManagedPackages()
            guard !history.contains(where: { $0.packageID == packageID }),
                  !uninstalledPackages.contains(where: { $0.packageID == packageID }) else {
                throw PocketAppGenerationError.packageInvalid
            }
            lastReceipt = nil
            packageNames.removeValue(forKey: packageID)
            removalMessage = "ツールと保存した記録・作成履歴を削除しました。削除したファイルはmacOSのゴミ箱へ移しました。"
            errorCode = nil
            postCommitHook?()
        } catch {
            lastReceipt = nil
            errorCode = nil
            removalMessage = "アンインストール済みですが、一部の記録を削除できませんでした。「アンインストール済み」からもう一度削除してください。"
            try? refreshManagedPackages()
            refreshHistory()
        }
    }

    func removePreservingData(packageID: String) {
        guard !managementIsBusy else {
            workspaceBackupErrorCode = "RESTORE_BUSY"
            return
        }
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
        guard pendingProposal == nil, pendingWorkspaceRestore == nil else {
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
        guard pendingProposal == nil, pendingWorkspaceRestore == nil else {
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
        let draft = packageID == nil ? draftCheckpoint : nil
        if let draft {
            appID = draft.packageID
            version = draft.version
        } else if let packageID {
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
        let currentPackage = try draft.map { try historyStore.package(for: $0) }
            ?? packageID.flatMap { try lifecycle.currentPackage(packageID: $0, includingDisabled: true) }
        let existingNamespace = currentPackage?.manifest.requestedCapabilities.compactMap { capability -> String? in
            guard case .object(let scope)? = capability.scope, case .string(let value)? = scope["namespace"] else { return nil }
            return value
        }.first
        let namespace = existingNamespace ?? "tool-" + String(appID.split(separator: ".").last ?? "app").prefix(26)
        var request = PocketAppGenerationRequest(
            requestID: "generation:\(UUID().uuidString.lowercased())",
            userRequest: trimmed,
            appID: appID,
            version: version,
            namespace: namespace,
            capabilities: PocketAppGenerationCapability.boundedCatalog(namespace: namespace)
        )
        if let currentPackage {
            request.previousFiles = try PocketAppFileSnapshot.capture(directory: currentPackage.rootDirectory).files
                .sorted(by: { $0.key < $1.key }).map { path, bytes in
                    guard let utf8 = String(data: bytes, encoding: .utf8) else { throw PocketAppGenerationError.packageInvalid }
                    return PocketAppGeneratedFile(path: path, utf8: utf8)
                }
        }
        request.reasoningEffort = generationSettings?.pocketToolReasoningEffort ?? "medium"
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
        removalMessage = nil
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
        uninstalledPackages = snapshot.packages.filter { $0.state == .removed }
        for package in managedPackages {
            if let definition = try? lifecycle.currentPackage(packageID: package.packageID, includingDisabled: true) {
                packageNames[package.packageID] = definition.manifest.name
            }
        }
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
