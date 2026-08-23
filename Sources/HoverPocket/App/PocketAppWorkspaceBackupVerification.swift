import Foundation

@MainActor
enum PocketAppWorkspaceBackupVerification {
    static func verify(failures: inout [String]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-pocket-workspace-backup-\(UUID().uuidString.lowercased())", isDirectory: true)
        let definitionRoot = root.appendingPathComponent("GeneratedHost", isDirectory: true)
        let dataRoot = root.appendingPathComponent("UserData", isDirectory: true)
        let transactionRoot = root.appendingPathComponent("BackupRestore", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let runtimeReadback: (PocketAppLifecycleReceipt) throws -> PocketAppRuntimeReadback = { receipt in
                PocketAppRuntimeReadback(
                    appID: receipt.packageID,
                    version: receipt.version,
                    packageDigest: receipt.packageDigest,
                    effectivePermissions: receipt.effectivePermissions
                )
            }
            let lifecycle = try PocketAppLifecycleManager(
                rootDirectory: definitionRoot,
                userDataRoot: dataRoot,
                activationReadback: runtimeReadback
            )
            let packageRoot = try bundledPackageCopy(under: root)
            let proposal = try lifecycle.stage(draftDirectory: packageRoot)
            let grant = try lifecycle.approve(
                requestID: proposal.requestID,
                bindingDigest: proposal.bindingDigest
            )
            _ = try lifecycle.install(proposal, approvalGrant: grant)
            let package = try PocketAppPackageRuntime().load(directory: packageRoot)
            let stateStore = try PocketAppUserStateStore(
                packageID: package.manifest.id,
                stateProperties: package.stateProperties,
                rootDirectory: dataRoot
            )
            try stateStore.setString("event-original", for: "selectedEventRef")

            let manager = try PocketAppWorkspaceBackupManager(
                definitionRoot: definitionRoot,
                userDataRoot: dataRoot,
                transactionRoot: transactionRoot,
                lifecycle: lifecycle,
                runtimeReadback: runtimeReadback
            )
            let fixedNow = Date(timeIntervalSince1970: 1_787_536_800)
            let backup = try manager.exportData(now: fixedNow)
            let repeated = try manager.exportData(now: fixedNow)
            require(backup == repeated, "workspace_backup_deterministic", failures: &failures)
            require(backup.count < PocketAppWorkspaceBackupManager.maximumBackupFileBytes, "workspace_backup_bounded", failures: &failures)

            let object = try jsonObject(backup)
            let paths = try filePaths(object)
            require(
                paths.allSatisfy { $0.hasPrefix("apps/") || $0.hasPrefix("data/") },
                "workspace_backup_boundary",
                failures: &failures
            )
            require(
                paths.allSatisfy {
                    let lowered = $0.lowercased()
                    return !lowered.contains("credential")
                        && !lowered.contains("oauth")
                        && !lowered.contains("audit")
                        && !lowered.contains("codexworkspaces")
                },
                "workspace_backup_secret_exclusion",
                failures: &failures
            )
            require(
                paths.contains("data/local.example.today-focus/state.json"),
                "workspace_backup_data",
                failures: &failures
            )

            var crossPlatformObject = object
            crossPlatformObject["sourcePlatform"] = "windows"
            let crossPlatformBytes = try JSONSerialization.data(
                withJSONObject: crossPlatformObject,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            let crossPlatformProposal = try manager.prepareRestore(data: crossPlatformBytes, now: fixedNow)
            require(
                crossPlatformProposal.changes.count == 1,
                "workspace_restore_windows_portability",
                failures: &failures
            )
            try manager.reject(
                requestID: crossPlatformProposal.requestID,
                bindingDigest: crossPlatformProposal.bindingDigest
            )

            try stateStore.setString("event-changed", for: "selectedEventRef")
            let restoreProposal = try manager.prepareRestore(data: backup, now: fixedNow)
            require(
                restoreProposal.changes.count == 1
                    && restoreProposal.changes[0].appID == package.manifest.id
                    && restoreProposal.changes[0].toVersion == package.manifest.version,
                "workspace_restore_preview",
                failures: &failures
            )
            let restoreGrant = try manager.approve(
                requestID: restoreProposal.requestID,
                bindingDigest: restoreProposal.bindingDigest,
                now: fixedNow
            )
            let receipt = try manager.restore(restoreProposal, grant: restoreGrant, now: fixedNow)
            let restoredState = try stateValue(dataRoot: dataRoot, appID: package.manifest.id, key: "selectedEventRef")
            require(
                receipt.readbackVerified
                    && !receipt.rollbackPerformed
                    && receipt.restoredApps.count == 1
                    && receipt.restoredApps[0].dataVersion == 1
                    && restoredState == "event-original",
                "workspace_restore_roundtrip",
                failures: &failures
            )

            let staleProposal = try manager.prepareRestore(data: backup, now: fixedNow)
            try stateStore.setString("event-stale", for: "selectedEventRef")
            let staleGrant = try manager.approve(
                requestID: staleProposal.requestID,
                bindingDigest: staleProposal.bindingDigest,
                now: fixedNow
            )
            do {
                _ = try manager.restore(staleProposal, grant: staleGrant, now: fixedNow)
                failures.append("workspace_restore_stale_preview_accepted")
            } catch {}
            require(
                try stateValue(dataRoot: dataRoot, appID: package.manifest.id, key: "selectedEventRef") == "event-stale",
                "workspace_restore_stale_preview_side_effect",
                failures: &failures
            )
            try manager.reject(requestID: staleProposal.requestID, bindingDigest: staleProposal.bindingDigest)

            let rejection = try manager.prepareRestore(data: backup, now: fixedNow)
            do {
                _ = try manager.approve(
                    requestID: rejection.requestID,
                    bindingDigest: "sha256:" + String(repeating: "0", count: 64),
                    now: fixedNow
                )
                failures.append("workspace_restore_binding_mismatch_accepted")
            } catch {}
            try manager.reject(requestID: rejection.requestID, bindingDigest: rejection.bindingDigest)
            do {
                _ = try manager.approve(
                    requestID: rejection.requestID,
                    bindingDigest: rejection.bindingDigest,
                    now: fixedNow
                )
                failures.append("workspace_restore_rejection_accepted")
            } catch {}

            try rejectMutation(
                backup,
                label: "workspace_restore_tamper",
                failures: &failures,
                mutate: { object in
                    guard var files = object["files"] as? [[String: Any]], !files.isEmpty else { return false }
                    files[0]["contentBase64"] = "e30="
                    object["files"] = files
                    return true
                },
                manager: manager,
                now: fixedNow
            )
            try rejectMutation(
                backup,
                label: "workspace_restore_traversal",
                failures: &failures,
                mutate: { object in
                    guard var files = object["files"] as? [[String: Any]], !files.isEmpty else { return false }
                    files[0]["path"] = "data/local.example.today-focus/../credential.json"
                    object["files"] = files
                    return true
                },
                manager: manager,
                now: fixedNow
            )
            try rejectMutation(
                backup,
                label: "workspace_restore_case_collision",
                failures: &failures,
                mutate: { object in
                    guard var files = object["files"] as? [[String: Any]],
                          let index = files.firstIndex(where: { ($0["path"] as? String)?.contains("/package/intent.md") == true }),
                          var duplicate = files[safe: index],
                          let path = duplicate["path"] as? String else { return false }
                    duplicate["path"] = path.replacingOccurrences(of: "intent.md", with: "Intent.md")
                    files.append(duplicate)
                    files.sort { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
                    object["files"] = files
                    return true
                },
                manager: manager,
                now: fixedNow
            )
            try rejectMutation(
                backup,
                label: "workspace_restore_oversized_file",
                failures: &failures,
                mutate: { object in
                    guard var files = object["files"] as? [[String: Any]], !files.isEmpty else { return false }
                    let bytes = Data(repeating: 0x41, count: PocketAppPackageRuntime.maximumFileBytes + 1)
                    files[0]["size"] = bytes.count
                    files[0]["contentBase64"] = bytes.base64EncodedString()
                    object["files"] = files
                    return true
                },
                manager: manager,
                now: fixedNow
            )

            try stateStore.setString("event-before-failure", for: "selectedEventRef")
            var commitFailureRemaining = 1
            let failingManager = try PocketAppWorkspaceBackupManager(
                definitionRoot: definitionRoot,
                userDataRoot: dataRoot,
                transactionRoot: root.appendingPathComponent("BackupRestoreFailure", isDirectory: true),
                lifecycle: lifecycle,
                runtimeReadback: runtimeReadback,
                failureInjection: { point in
                    guard point == "after_app_commit", commitFailureRemaining > 0 else { return false }
                    commitFailureRemaining -= 1
                    return true
                }
            )
            let failingProposal = try failingManager.prepareRestore(data: backup, now: fixedNow)
            let failingGrant = try failingManager.approve(
                requestID: failingProposal.requestID,
                bindingDigest: failingProposal.bindingDigest,
                now: fixedNow
            )
            do {
                _ = try failingManager.restore(failingProposal, grant: failingGrant, now: fixedNow)
                failures.append("workspace_restore_commit_failure_accepted")
            } catch {}
            require(
                try stateValue(dataRoot: dataRoot, appID: package.manifest.id, key: "selectedEventRef") == "event-before-failure",
                "workspace_restore_commit_failure_rollback",
                failures: &failures
            )

            var readbackFailureRemaining = 1
            let readbackFailingManager = try PocketAppWorkspaceBackupManager(
                definitionRoot: definitionRoot,
                userDataRoot: dataRoot,
                transactionRoot: root.appendingPathComponent("BackupRestoreReadbackFailure", isDirectory: true),
                lifecycle: lifecycle,
                runtimeReadback: runtimeReadback,
                failureInjection: { point in
                    guard point == "runtime_readback", readbackFailureRemaining > 0 else { return false }
                    readbackFailureRemaining -= 1
                    return true
                }
            )
            let readbackProposal = try readbackFailingManager.prepareRestore(data: backup, now: fixedNow)
            let readbackGrant = try readbackFailingManager.approve(
                requestID: readbackProposal.requestID,
                bindingDigest: readbackProposal.bindingDigest,
                now: fixedNow
            )
            do {
                _ = try readbackFailingManager.restore(readbackProposal, grant: readbackGrant, now: fixedNow)
                failures.append("workspace_restore_readback_failure_accepted")
            } catch {}
            require(
                try stateValue(dataRoot: dataRoot, appID: package.manifest.id, key: "selectedEventRef") == "event-before-failure",
                "workspace_restore_readback_failure_rollback",
                failures: &failures
            )
        } catch {
            failures.append("workspace_backup_fixture:\(error)")
        }
    }

    private static func bundledPackageCopy(under root: URL) throws -> URL {
        guard let resources = Bundle.module.resourceURL else {
            throw PocketAppWorkspaceBackupError.invalid("WORKSPACE_FIXTURE_MISSING")
        }
        let source = resources
            .appendingPathComponent("PocketApps", isDirectory: true)
            .appendingPathComponent("local.example.today-focus", isDirectory: true)
        let destination = root.appendingPathComponent("Package", isDirectory: true)
        try PocketAppFileSnapshot.capture(directory: source).materialize(at: destination)
        return destination
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PocketAppWorkspaceBackupError.invalid("WORKSPACE_JSON_INVALID")
        }
        return object
    }

    private static func filePaths(_ object: [String: Any]) throws -> [String] {
        guard let files = object["files"] as? [[String: Any]] else {
            throw PocketAppWorkspaceBackupError.invalid("WORKSPACE_FILES_INVALID")
        }
        return try files.map {
            guard let path = $0["path"] as? String else {
                throw PocketAppWorkspaceBackupError.invalid("WORKSPACE_PATH_INVALID")
            }
            return path
        }
    }

    private static func rejectMutation(
        _ backup: Data,
        label: String,
        failures: inout [String],
        mutate: (inout [String: Any]) -> Bool,
        manager: PocketAppWorkspaceBackupManager,
        now: Date
    ) throws {
        var object = try jsonObject(backup)
        guard mutate(&object) else {
            failures.append("\(label)_fixture")
            return
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        do {
            _ = try manager.prepareRestore(data: data, now: now)
            failures.append("\(label)_accepted")
        } catch {}
    }

    private static func stateValue(dataRoot: URL, appID: String, key: String) throws -> String? {
        let data = try PocketAppFileSnapshot.readFileNoFollow(
            rootDirectory: dataRoot,
            relativePath: "\(appID)/state.json",
            maximumBytes: 256 * 1_024
        )
        let object = try jsonObject(data)
        return object[key] as? String
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ label: String, failures: inout [String]) {
        do {
            if try !condition() { failures.append(label) }
        } catch {
            failures.append("\(label):\(error)")
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
