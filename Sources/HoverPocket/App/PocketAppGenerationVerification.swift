import Darwin
import Foundation

@MainActor
enum PocketAppGenerationVerification {
    static func verify(failures: inout [String]) {
        verifyDefaultOff(failures: &failures)
        PocketAppRuntimeActivationVerification.verify(failures: &failures)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-pocket-generation-host-\(UUID().uuidString)", isDirectory: true)
        let dataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-pocket-generation-data-\(UUID().uuidString)", isDirectory: true)
        let draftRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-pocket-generation-drafts-\(UUID().uuidString)", isDirectory: true)
        defer {
            makeTreeMutable(root)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: dataRoot)
            try? FileManager.default.removeItem(at: draftRoot)
        }
        do {
            try FileManager.default.createDirectory(at: draftRoot, withIntermediateDirectories: true)
            let fixture = try fixtureDocument()
            let fixtureRoot = fixtureURL(".")
            let adapter = FixturePocketAppGenerationAdapter(fixtureRoot: fixtureRoot)
            let materializer = PocketAppGenerationMaterializer(rootDirectory: draftRoot)
            let lifecycle = try PocketAppLifecycleManager(rootDirectory: root, userDataRoot: dataRoot)

            let request = try makeRequest(
                requestID: string(fixture, "requestId"),
                userRequest: string(fixture, "userRequest"),
                appID: string(fixture, "appId"),
                version: string(fixture, "initialVersion"),
                namespace: string(fixture, "namespace")
            )
            require(
                request.requestDigest == string(fixture, "expectedRequestDigest"),
                "generation_request_digest",
                failures: &failures
            )
            let envelope = try adapter.generate(request, cancellation: PocketAppGenerationCancellation())
            let materialized = try materializer.materialize(envelope: envelope, request: request)
            defer { try? FileManager.default.removeItem(at: materialized.directory) }
            require(
                materialized.package.manifestDigest == string(fixture, "expectedInitialPackageDigest"),
                "generation_initial_digest",
                failures: &failures
            )
            let proposal = try lifecycle.stage(draftDirectory: materialized.directory)
            let expectedPermissions = Set(stringArray(fixture, "expectedAddedPermissions"))
            require(Set(proposal.permissionDiff.added) == expectedPermissions, "generation_permission_diff", failures: &failures)
            require(proposal.approvalRequired && proposal.previews.count == 1, "generation_preview", failures: &failures)
            require(proposal.tests.allSatisfy { $0.status == $0.expected }, "generation_tests", failures: &failures)
            let grant = try lifecycle.approve(requestID: proposal.requestID, bindingDigest: proposal.bindingDigest)
            let installed = try lifecycle.install(proposal, approvalGrant: grant)
            require(installed.readbackVerified, "generation_install_readback", failures: &failures)
            require(
                try lifecycle.activePackage(packageID: request.appID)?.manifestDigest == proposal.packageDigest,
                "generation_active_digest",
                failures: &failures
            )

            let updateRequest = try makeRequest(
                requestID: "generation-fixture-0002",
                userRequest: request.userRequest,
                appID: request.appID,
                version: string(fixture, "updateVersion"),
                namespace: request.namespace
            )
            let updateEnvelope = try adapter.generate(updateRequest, cancellation: PocketAppGenerationCancellation())
            let updateMaterialized = try materializer.materialize(envelope: updateEnvelope, request: updateRequest)
            defer { try? FileManager.default.removeItem(at: updateMaterialized.directory) }
            let update = try lifecycle.stage(draftDirectory: updateMaterialized.directory)
            require(update.action == .update && update.permissionDiff.added.isEmpty, "generation_update", failures: &failures)
            let updateGrant = try lifecycle.approve(requestID: update.requestID, bindingDigest: update.bindingDigest)
            let updated = try lifecycle.install(update, approvalGrant: updateGrant)
            require(updated.readbackVerified && updated.version == updateRequest.version, "generation_update_readback", failures: &failures)

            let managed = try lifecycle.managedPackages().first { $0.packageID == request.appID }
            require(
                managed?.version == updateRequest.version
                    && managed?.packageDigest == update.packageDigest
                    && managed?.installedVersions.contains(request.version) == true,
                "generation_managed_readback",
                failures: &failures
            )

            let rollback = try lifecycle.prepareRollback(packageID: request.appID, version: request.version)
            let rollbackGrant = try lifecycle.approve(requestID: rollback.requestID, bindingDigest: rollback.bindingDigest)
            let rolledBack = try lifecycle.rollback(rollback, approvalGrant: rollbackGrant)
            require(rolledBack.readbackVerified && rolledBack.version == request.version, "generation_rollback", failures: &failures)

            let disabled = try lifecycle.disable(packageID: request.appID)
            require(disabled.readbackVerified && disabled.state == .disabled, "generation_disable", failures: &failures)
            let enabled = try lifecycle.enable(packageID: request.appID)
            let enabledPackage = try lifecycle.activePackage(packageID: request.appID)
            require(
                enabled.readbackVerified
                    && enabled.state == .enabled
                    && enabledPackage?.manifestDigest == enabled.packageDigest,
                "generation_enable_readback",
                failures: &failures
            )
            let disabledAgain = try lifecycle.disable(packageID: request.appID)
            require(
                disabledAgain.readbackVerified && disabledAgain.state == .disabled,
                "generation_disable_after_enable",
                failures: &failures
            )
            var failEnableReadback = true
            let failingEnableLifecycle = try PocketAppLifecycleManager(
                rootDirectory: root,
                userDataRoot: dataRoot,
                failureInjection: { point in
                    guard point == "enable_readback", failEnableReadback else { return false }
                    failEnableReadback = false
                    return true
                }
            )
            do {
                _ = try failingEnableLifecycle.enable(packageID: request.appID)
                failures.append("generation_enable_readback_failure_accepted")
            } catch PocketAppLifecycleError.readbackFailed {
            }
            let restoredDisabled = try failingEnableLifecycle.managedPackages()
                .first { $0.packageID == request.appID }
            let restoredActivePackage = try failingEnableLifecycle.activePackage(packageID: request.appID)
            require(
                restoredDisabled?.state == .disabled
                    && restoredActivePackage == nil,
                "generation_enable_readback_failure_restored_disabled",
                failures: &failures
            )
            let failingRuntimeEnableLifecycle = try PocketAppLifecycleManager(
                rootDirectory: root,
                userDataRoot: dataRoot,
                activationReadback: { receipt in
                    if receipt.state == .enabled {
                        throw PocketAppRuntimeActivationError.unavailable
                    }
                    return PocketAppRuntimeReadback(
                        appID: receipt.packageID,
                        version: receipt.version,
                        packageDigest: receipt.packageDigest,
                        effectivePermissions: receipt.effectivePermissions
                    )
                }
            )
            do {
                _ = try failingRuntimeEnableLifecycle.enable(packageID: request.appID)
                failures.append("generation_runtime_enable_failure_accepted")
            } catch PocketAppLifecycleError.readbackFailed {
            }
            require(
                try failingRuntimeEnableLifecycle.managedPackage(packageID: request.appID)?.state == .disabled
                    && failingRuntimeEnableLifecycle.activePackage(packageID: request.appID) == nil,
                "generation_runtime_enable_failure_remains_disabled",
                failures: &failures
            )

            let reupdate = try lifecycle.stage(draftDirectory: updateMaterialized.directory)
            let reupdateGrant = try lifecycle.approve(
                requestID: reupdate.requestID,
                bindingDigest: reupdate.bindingDigest
            )
            _ = try lifecycle.install(reupdate, approvalGrant: reupdateGrant)
            let failingRuntimeRollbackLifecycle = try PocketAppLifecycleManager(
                rootDirectory: root,
                userDataRoot: dataRoot,
                activationReadback: { receipt in
                    if receipt.state == .enabled {
                        throw PocketAppRuntimeActivationError.unavailable
                    }
                    return PocketAppRuntimeReadback(
                        appID: receipt.packageID,
                        version: receipt.version,
                        packageDigest: receipt.packageDigest,
                        effectivePermissions: receipt.effectivePermissions
                    )
                }
            )
            let failingRollback = try failingRuntimeRollbackLifecycle.prepareRollback(
                packageID: request.appID,
                version: request.version
            )
            let failingRollbackGrant = try failingRuntimeRollbackLifecycle.approve(
                requestID: failingRollback.requestID,
                bindingDigest: failingRollback.bindingDigest
            )
            do {
                _ = try failingRuntimeRollbackLifecycle.rollback(
                    failingRollback,
                    approvalGrant: failingRollbackGrant
                )
                failures.append("generation_runtime_rollback_failure_accepted")
            } catch PocketAppLifecycleError.readbackFailed {
            }
            let rollbackFallback = try failingRuntimeRollbackLifecycle.managedPackage(packageID: request.appID)
            let rollbackFallbackActivePackage = try failingRuntimeRollbackLifecycle.activePackage(
                packageID: request.appID
            )
            require(
                rollbackFallback?.state == .disabled
                    && rollbackFallback?.version == updateRequest.version
                    && rollbackFallbackActivePackage == nil,
                "generation_runtime_rollback_failure_disables_previous_version",
                failures: &failures
            )
            let packageDataRoot = dataRoot.appendingPathComponent(request.appID, isDirectory: true)
            try FileManager.default.createDirectory(at: packageDataRoot, withIntermediateDirectories: true)
            let sentinel = packageDataRoot.appendingPathComponent("sentinel.txt")
            try Data("preserve".utf8).write(to: sentinel)
            let removed = try lifecycle.remove(packageID: request.appID, dataDisposition: .preserve)
            require(
                removed.readbackVerified
                    && removed.state == .removed
                    && removed.dataDisposition == .preserve
                    && FileManager.default.fileExists(atPath: sentinel.path),
                "generation_remove_preserve",
                failures: &failures
            )

            let tampered = PocketAppGenerationEnvelope(
                requestID: envelope.requestID,
                requestDigest: "sha256:" + String(repeating: "0", count: 64),
                appID: envelope.appID,
                version: envelope.version,
                namespace: envelope.namespace,
                files: envelope.files
            )
            do {
                _ = try materializer.materialize(envelope: tampered, request: request)
                failures.append("generation_tampered_envelope_accepted")
            } catch PocketAppGenerationError.envelopeMismatch {
            }

            var unsafeFiles = envelope.files
            unsafeFiles[0] = PocketAppGeneratedFile(path: "../manifest.json", utf8: unsafeFiles[0].utf8)
            let unsafe = PocketAppGenerationEnvelope(
                requestID: envelope.requestID,
                requestDigest: envelope.requestDigest,
                appID: envelope.appID,
                version: envelope.version,
                namespace: envelope.namespace,
                files: unsafeFiles
            )
            do {
                _ = try materializer.materialize(envelope: unsafe, request: request)
                failures.append("generation_unsafe_path_accepted")
            } catch PocketAppGenerationError.unsafePath {
            }

            let cancelled = PocketAppGenerationCancellation()
            cancelled.cancel()
            do {
                _ = try adapter.generate(request, cancellation: cancelled)
                failures.append("generation_cancel_ignored")
            } catch PocketAppGenerationError.generatorCancelled {
            }

            try verifySchemaParity(failures: &failures)
            try verifyRealOutputFixture(request: request, failures: &failures)
            try verifyPromptAndVersioning(request: request, failures: &failures)
            verifyRealCodexFailsClosed(failures: &failures)
            try verifyProcessTreeCleanup(failures: &failures)
            try verifyRootPin(failures: &failures)
            try verifyGenerationStartupDoesNotRecover(failures: &failures)
            try verifyFailedActivationRefreshesManagement(failures: &failures)
            try verifyCommittedReceiptSurvivesManagedRefreshFailure(failures: &failures)
            try verifyUnrelatedActionPreservesPendingProposal(failures: &failures)
        } catch {
            failures.append("generation_e2e:\(error)")
        }
    }

    private static func verifyDefaultOff(failures: inout [String]) {
        let suite = "hover-pocket-generation-default-off-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            failures.append("generation_default_off_defaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        require(!settings.aiNativeEnabled, "generation_default_off", failures: &failures)
        defaults.removePersistentDomain(forName: suite)
    }

    private static func makeRequest(
        requestID: String,
        userRequest: String,
        appID: String,
        version: String,
        namespace: String
    ) throws -> PocketAppGenerationRequest {
        let request = PocketAppGenerationRequest(
            requestID: requestID,
            userRequest: userRequest,
            appID: appID,
            version: version,
            namespace: namespace,
            capabilities: PocketAppGenerationCapability.boundedCatalog(namespace: namespace)
        )
        try request.validate()
        return request
    }

    private static func verifySchemaParity(failures: inout [String]) throws {
        let source = try Data(contentsOf: contractURL("pocket-app-generation-output.schema.json"))
        let runtime = Data(PocketAppGenerationContract.outputSchemaJSON.utf8)
        let sourceObject = try JSONSerialization.jsonObject(with: source)
        let runtimeObject = try JSONSerialization.jsonObject(with: runtime)
        let canonicalSource = try JSONSerialization.data(withJSONObject: sourceObject, options: [.sortedKeys])
        let canonicalRuntime = try JSONSerialization.data(withJSONObject: runtimeObject, options: [.sortedKeys])
        require(canonicalSource == canonicalRuntime, "generation_schema_parity", failures: &failures)
        let sourceDictionary = sourceObject as? [String: Any]
        let properties = sourceDictionary?["properties"] as? [String: Any]
        let schemaProperty = properties?["$schema"] as? [String: Any]
        require(
            schemaProperty?["type"] as? String == "string"
                && schemaProperty?["const"] as? String == PocketAppGenerationContract.schemaID,
            "generation_schema_const_type",
            failures: &failures
        )
    }

    private static func verifyRealOutputFixture(
        request: PocketAppGenerationRequest,
        failures: inout [String]
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-pocket-real-output-host-\(UUID().uuidString)", isDirectory: true)
        let dataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-pocket-real-output-data-\(UUID().uuidString)", isDirectory: true)
        let draftRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-pocket-real-output-draft-\(UUID().uuidString)", isDirectory: true)
        defer {
            makeTreeMutable(root)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: dataRoot)
            try? FileManager.default.removeItem(at: draftRoot)
        }
        try FileManager.default.createDirectory(at: draftRoot, withIntermediateDirectories: true)
        let bytes = try Data(contentsOf: fixtureURL("support/pocket-app-generation.real-codex-output.json"))
        let envelope = try PocketAppGenerationContract.decodeEnvelope(bytes)
        let materializer = PocketAppGenerationMaterializer(rootDirectory: draftRoot)
        let materialized = try materializer.materialize(envelope: envelope, request: request)
        defer { try? FileManager.default.removeItem(at: materialized.directory) }
        let lifecycle = try PocketAppLifecycleManager(rootDirectory: root, userDataRoot: dataRoot)
        let proposal = try lifecycle.stage(draftDirectory: materialized.directory)
        require(proposal.tests.allSatisfy { $0.status == $0.expected }, "generation_real_output_tests", failures: &failures)
        require(!proposal.previews.isEmpty, "generation_real_output_preview", failures: &failures)
        require(!proposal.permissionDiff.added.isEmpty, "generation_real_output_permission_diff", failures: &failures)
        require(!proposal.capabilityGrantDiff.added.isEmpty, "generation_real_output_grant_diff", failures: &failures)
        let grant = try lifecycle.approve(requestID: proposal.requestID, bindingDigest: proposal.bindingDigest)
        let receipt = try lifecycle.install(proposal, approvalGrant: grant)
        let active = try lifecycle.activePackage(packageID: request.appID)
        require(
            receipt.readbackVerified
                && receipt.packageDigest == proposal.packageDigest
                && active?.manifestDigest == proposal.packageDigest,
            "generation_real_output_active_readback",
            failures: &failures
        )
    }

    private static func verifyPromptAndVersioning(
        request: PocketAppGenerationRequest,
        failures: inout [String]
    ) throws {
        let prompt = try PocketAppGenerationContract.prompt(request)
        require(prompt.contains("\"apiVersion\":\"hoverpocket.app/v1\""), "generation_prompt_manifest_shape", failures: &failures)
        require(prompt.contains("\"approval\":{\"mode\":\"before_writes\""), "generation_prompt_workflow_shape", failures: &failures)
        require(prompt.contains("Explicitly forbidden legacy output"), "generation_prompt_legacy_rejection", failures: &failures)
        let largePatch = String(repeating: "9", count: 59)
        let expected = "1.0.1" + String(repeating: "0", count: 59)
        require(
            try PocketAppGenerationController.nextPatchVersion("1.0.\(largePatch)") == expected,
            "generation_large_patch_increment",
            failures: &failures
        )
        require(
            try PocketAppGenerationController.nextVersion(
                installedVersions: ["1.0.0", "1.0.1"],
                currentVersion: "1.0.0"
            ) == "1.0.2",
            "generation_update_after_rollback_uses_highest_version",
            failures: &failures
        )
        require(
            PocketAppGenerationController.rollbackVersions(
                installedVersions: ["1.0.0", "1.0.1"],
                currentVersion: "1.0.0"
            ).isEmpty
                && PocketAppGenerationController.rollbackVersions(
                    installedVersions: ["1.0.0", "1.0.1"],
                    currentVersion: "1.0.1"
                ) == ["1.0.0"],
            "generation_rollback_targets_only_older_versions",
            failures: &failures
        )
        require(
            PocketAppGenerationController.shouldRejectPendingProposal(
                removingPackageID: "local.example.focus",
                pendingPackageID: "local.example.focus"
            )
                && !PocketAppGenerationController.shouldRejectPendingProposal(
                    removingPackageID: "local.example.calendar",
                    pendingPackageID: "local.example.focus"
                ),
            "generation_remove_rejects_only_same_package_proposal",
            failures: &failures
        )
        let freshAppID1 = PocketAppGenerationController.freshAppID()
        let freshAppID2 = PocketAppGenerationController.freshAppID()
        require(
            freshAppID1 != freshAppID2
                && freshAppID1.range(
                    of: "^local\\.generated\\.a[0-9a-f]{32}$",
                    options: .regularExpression
                ) != nil
                && freshAppID2.range(
                    of: "^local\\.generated\\.a[0-9a-f]{32}$",
                    options: .regularExpression
                ) != nil,
            "generation_untargeted_request_gets_fresh_app_id",
            failures: &failures
        )
        let now = Date()
        let crafted = PocketAppLifecycleProposal(
            requestID: "request-safe",
            action: .install,
            packageID: request.appID,
            version: request.version,
            packageDigest: "sha256:" + String(repeating: "a", count: 64),
            currentDigest: nil,
            currentState: nil,
            previewDigest: "sha256:" + String(repeating: "b", count: 64),
            previews: [],
            permissionDiff: PocketAppPermissionDiff(added: ["calendar.events.read\nspoof\u{202E}"], removed: []),
            capabilityGrantDiff: PocketAppCapabilityGrantDiff(
                added: ["{\"capabilityId\":\"safe\u{202E}evil\",\"capabilityVersion\":1,\"effect\":\"private_read\",\"permissions\":[\"calendar.events.read\"],\"scope\":{\"range\":\"today\"}}"],
                removed: []
            ),
            tests: [],
            bindingDigest: "sha256:" + String(repeating: "c", count: 64),
            createdAt: now,
            expiresAt: now.addingTimeInterval(300),
            approvalRequired: true,
            stagingDirectory: FileManager.default.temporaryDirectory,
            stateSchemaDigest: "sha256:" + String(repeating: "d", count: 64),
            statePropertyNames: []
        )
        let approval = PocketAppGenerationApprovalPresentation.text(crafted, source: "codex-preview-only")
        require(
            !approval.contains("\u{202E}")
                && !approval.contains("read\nspoof")
                && approval.contains("\"capabilityVersion\":1")
                && approval.contains(crafted.packageDigest)
                && approval.contains(crafted.bindingDigest),
            "generation_approval_text_sanitized_exact",
            failures: &failures
        )
    }

    private static func verifyRealCodexFailsClosed(failures: inout [String]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-pocket-codex-confinement", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let userHome = root.appendingPathComponent("user-home", isDirectory: true)
        let temporaryDirectory = root.appendingPathComponent("tmp", isDirectory: true)
        let schema = workspace.appendingPathComponent("generation-output.schema.json")
        do {
            let arguments = try CodexPocketAppGenerationAdapter.confinementArguments(
                workspace: workspace,
                codexHome: codexHome,
                userHome: userHome,
                schemaURL: schema
            )
            let joined = arguments.joined(separator: "\n")
            require(
                !arguments.contains("--sandbox")
                    && arguments.contains("--ignore-user-config")
                    && arguments.contains("--ignore-rules")
                    && joined.contains("default_permissions=\"hoverpocket-generation\"")
                    && joined.contains("\"\(workspace.path)\"=\"read\"")
                    && joined.contains("\"\(codexHome.path)\"=\"deny\"")
                    && joined.contains("\"\(userHome.path)\"=\"deny\"")
                    && joined.contains("network.enabled=false")
                    && joined.contains("shell_environment_policy.inherit=\"none\"")
                    && arguments.suffix(3) == ["--output-schema", schema.path, "-"],
                "generation_codex_named_permission_profile",
                failures: &failures
            )
            let environment = CodexPocketAppGenerationAdapter.confinementEnvironment(
                codexHome: codexHome,
                userHome: userHome,
                temporaryDirectory: temporaryDirectory
            )
            require(
                Set(environment.keys) == ["CODEX_HOME", "HOME", "PATH", "TMPDIR", "LANG"]
                    && environment["CODEX_HOME"] == codexHome.path
                    && environment["HOME"] == userHome.path
                    && environment["TMPDIR"] == temporaryDirectory.path
                    && environment["PATH"] == "/usr/bin:/bin",
                "generation_codex_isolated_environment",
                failures: &failures
            )
        } catch {
            failures.append("generation_codex_confinement_contract")
        }
        require(
            !CodexPocketAppGenerationAdapter.supportsConfidentialGeneration
                && CodexPocketAppGenerationAdapter.resolveExecutable() == nil,
            "generation_real_codex_confidentiality_gate",
            failures: &failures
        )
    }

    private static func verifyProcessTreeCleanup(failures: inout [String]) throws {
        for reason in ["cancel", "timeout", "disable"] {
            let childFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("hover-pocket-generation-child-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: childFile) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "sleep 30 & child=$!; printf '%s' \"$child\" > \"$1\"; wait", "hoverpocket-test", childFile.path]
            try process.run()
            let pid = process.processIdentifier
            if setpgid(pid, pid) != 0, getpgid(pid) != pid {
                process.terminate()
                process.waitUntilExit()
                failures.append("generation_process_group_\(reason)")
                continue
            }
            let deadline = Date().addingTimeInterval(2)
            while !FileManager.default.fileExists(atPath: childFile.path), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            let childText = (try? String(contentsOf: childFile, encoding: .utf8)) ?? ""
            let childPID = Int32(childText) ?? -1
            CodexPocketAppGenerationAdapter.stop(process)
            process.waitUntilExit()
            let childAlive = childPID > 0 && kill(childPID, 0) == 0
            require(!process.isRunning && !childAlive, "generation_process_tree_\(reason)", failures: &failures)
        }
    }

    private static func verifyRootPin(failures: inout [String]) throws {
        let temporaryRoot = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(".build", isDirectory: true)
        let target = temporaryRoot
            .appendingPathComponent("hover-pocket-generation-pin-target-\(UUID().uuidString)", isDirectory: true)
        let link = temporaryRoot
            .appendingPathComponent("hover-pocket-generation-pin-link-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do {
            _ = try PocketAppPinnedDirectory(url: link)
            failures.append("generation_symlink_root_accepted")
        } catch PocketAppGenerationError.rootUnsafe {
        }
    }

    private static func verifyGenerationStartupDoesNotRecover(failures: inout [String]) throws {
        let temporaryRoot = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(".build", isDirectory: true)
        let root = temporaryRoot
            .appendingPathComponent("hover-pocket-generation-no-recovery-host-\(UUID().uuidString)", isDirectory: true)
        let dataRoot = temporaryRoot
            .appendingPathComponent("hover-pocket-generation-no-recovery-data-\(UUID().uuidString)", isDirectory: true)
        let draftRoot = temporaryRoot
            .appendingPathComponent("hover-pocket-generation-no-recovery-draft-\(UUID().uuidString)", isDirectory: true)
        defer {
            makeTreeMutable(root)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: dataRoot)
            try? FileManager.default.removeItem(at: draftRoot)
        }
        let abandoned = root
            .appendingPathComponent("Staging", isDirectory: true)
            .appendingPathComponent("abandoned", isDirectory: true)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        let sentinel = abandoned.appendingPathComponent("sentinel.txt")
        try Data("preserve-until-explicit-recovery".utf8).write(to: sentinel)
        let controller = try PocketAppGenerationController(
            rootDirectory: root,
            userDataRoot: dataRoot,
            generationRoot: draftRoot,
            generator: nil
        )
        require(
            FileManager.default.fileExists(atPath: sentinel.path),
            "generation_startup_recovery_disabled",
            failures: &failures
        )
        withExtendedLifetime(controller) {}
    }

    private static func verifyFailedActivationRefreshesManagement(
        failures: inout [String]
    ) throws {
        let temporaryRoot = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(".build", isDirectory: true)
        let root = temporaryRoot
            .appendingPathComponent("hover-pocket-generation-activation-failure-host-\(UUID().uuidString)", isDirectory: true)
        let dataRoot = temporaryRoot
            .appendingPathComponent("hover-pocket-generation-activation-failure-data-\(UUID().uuidString)", isDirectory: true)
        let draftRoot = temporaryRoot
            .appendingPathComponent("hover-pocket-generation-activation-failure-draft-\(UUID().uuidString)", isDirectory: true)
        defer {
            makeTreeMutable(root)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: dataRoot)
            try? FileManager.default.removeItem(at: draftRoot)
        }
        try FileManager.default.createDirectory(at: draftRoot, withIntermediateDirectories: true)
        let adapter = FixturePocketAppGenerationAdapter(fixtureRoot: fixtureURL("."))
        let materializer = PocketAppGenerationMaterializer(rootDirectory: draftRoot)
        let request = try makeRequest(
            requestID: "generation-activation-failure",
            userRequest: "Create a focus app whose activation fails.",
            appID: "local.example.activation-failure",
            version: "1.0.0",
            namespace: "today-focus"
        )
        do {
            let lifecycle = try PocketAppLifecycleManager(rootDirectory: root, userDataRoot: dataRoot)
            _ = try installFixture(request, adapter: adapter, materializer: materializer, lifecycle: lifecycle)
            _ = try lifecycle.disable(packageID: request.appID)
        }
        let controller = try PocketAppGenerationController(
            rootDirectory: root,
            userDataRoot: dataRoot,
            generationRoot: draftRoot,
            generator: nil,
            runtimeActivationReadback: { receipt in
                if receipt.state == .enabled {
                    throw PocketAppRuntimeActivationError.unavailable
                }
                return PocketAppRuntimeReadback(
                    appID: receipt.packageID,
                    version: receipt.version,
                    packageDigest: receipt.packageDigest,
                    effectivePermissions: receipt.effectivePermissions
                )
            }
        )
        controller.enable(packageID: request.appID)
        let observed = controller.managedPackages.first { $0.packageID == request.appID }
        require(
            controller.phase == .failed
                && controller.errorCode == PocketAppGenerationError.packageInvalid.code
                && observed?.state == .disabled,
            "generation_failed_activation_refreshes_disabled_management",
            failures: &failures
        )
    }

    private static func verifyCommittedReceiptSurvivesManagedRefreshFailure(
        failures: inout [String]
    ) throws {
        let temporaryRoot = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(".build", isDirectory: true)
        let root = temporaryRoot
            .appendingPathComponent("hover-pocket-generation-refresh-host-\(UUID().uuidString)", isDirectory: true)
        let dataRoot = temporaryRoot
            .appendingPathComponent("hover-pocket-generation-refresh-data-\(UUID().uuidString)", isDirectory: true)
        let draftRoot = temporaryRoot
            .appendingPathComponent("hover-pocket-generation-refresh-draft-\(UUID().uuidString)", isDirectory: true)
        defer {
            makeTreeMutable(root)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: dataRoot)
            try? FileManager.default.removeItem(at: draftRoot)
        }
        try FileManager.default.createDirectory(at: draftRoot, withIntermediateDirectories: true)
        let adapter = FixturePocketAppGenerationAdapter(fixtureRoot: fixtureURL("."))
        let materializer = PocketAppGenerationMaterializer(rootDirectory: draftRoot)
        let lifecycle = try PocketAppLifecycleManager(rootDirectory: root, userDataRoot: dataRoot)
        let selected = try makeRequest(
            requestID: "generation-refresh-selected",
            userRequest: "Create the selected focus app.",
            appID: "local.example.selected",
            version: "1.0.0",
            namespace: "today-focus"
        )
        let unrelated = try makeRequest(
            requestID: "generation-refresh-unrelated",
            userRequest: "Create an unrelated focus app.",
            appID: "local.example.unrelated",
            version: "1.0.0",
            namespace: "today-focus"
        )
        _ = try installFixture(
            selected,
            adapter: adapter,
            materializer: materializer,
            lifecycle: lifecycle
        )
        let unrelatedReceipt = try installFixture(
            unrelated,
            adapter: adapter,
            materializer: materializer,
            lifecycle: lifecycle
        )
        guard let unrelatedDigest = unrelatedReceipt.packageDigest,
              let unrelatedVersion = unrelatedReceipt.version else {
            throw PocketAppGenerationError.packageInvalid
        }
        let versionStorageKey = "v-" + unrelatedVersion.utf8
            .map { String(format: "%02x", $0) }
            .joined()
        let digestRoot = root
            .appendingPathComponent("Apps/\(unrelated.appID)/Versions/\(versionStorageKey)", isDirectory: true)
            .appendingPathComponent(String(unrelatedDigest.dropFirst("sha256:".count)), isDirectory: true)
        let intent = digestRoot.appendingPathComponent("package/intent.md", isDirectory: false)
        var corruptionApplied = false
        let controller = try PocketAppGenerationController(
            rootDirectory: root,
            userDataRoot: dataRoot,
            generationRoot: draftRoot,
            generator: nil,
            postCommitHook: {
                guard !corruptionApplied else { return }
                makeTreeMutable(digestRoot)
                do {
                    try Data("corrupt-after-commit".utf8).write(to: intent)
                    corruptionApplied = true
                } catch {}
            }
        )
        controller.disable(packageID: selected.appID)
        let observed = controller.managedPackages.first { $0.packageID == selected.appID }
        require(corruptionApplied, "generation_post_commit_corruption_fixture", failures: &failures)
        require(
            controller.phase == .disabled
                && controller.errorCode == nil
                && controller.lastReceipt?.readbackVerified == true
                && controller.lastReceipt?.action == "disable"
                && observed?.state == .disabled
                && controller.managementIssues.contains {
                    $0.packageID == unrelated.appID && $0.removalAllowed
                },
            "generation_committed_receipt_survives_unrelated_refresh_failure",
            failures: &failures
        )
        let recoveredController = try PocketAppGenerationController(
            rootDirectory: root,
            userDataRoot: dataRoot,
            generationRoot: draftRoot,
            generator: nil
        )
        require(
            recoveredController.managedPackages.contains { $0.packageID == selected.appID }
                && recoveredController.managementIssues.contains {
                    $0.packageID == unrelated.appID && $0.removalAllowed
                },
            "generation_corrupt_package_isolated_on_startup",
            failures: &failures
        )
        recoveredController.removePreservingData(packageID: unrelated.appID)
        require(
            recoveredController.lastReceipt?.packageID == unrelated.appID
                && recoveredController.lastReceipt?.state == .removed
                && recoveredController.lastReceipt?.readbackVerified == true
                && !recoveredController.managementIssues.contains { $0.packageID == unrelated.appID }
                && recoveredController.managedPackages.contains { $0.packageID == selected.appID },
            "generation_corrupt_package_remove_preserves_healthy_management",
            failures: &failures
        )
    }

    private static func verifyUnrelatedActionPreservesPendingProposal(
        failures: inout [String]
    ) throws {
        let temporaryRoot = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(".build", isDirectory: true)
        let root = temporaryRoot
            .appendingPathComponent("hover-pocket-generation-pending-host-\(UUID().uuidString)", isDirectory: true)
        let dataRoot = temporaryRoot
            .appendingPathComponent("hover-pocket-generation-pending-data-\(UUID().uuidString)", isDirectory: true)
        let draftRoot = temporaryRoot
            .appendingPathComponent("hover-pocket-generation-pending-draft-\(UUID().uuidString)", isDirectory: true)
        defer {
            makeTreeMutable(root)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: dataRoot)
            try? FileManager.default.removeItem(at: draftRoot)
        }
        try FileManager.default.createDirectory(at: draftRoot, withIntermediateDirectories: true)
        let adapter = FixturePocketAppGenerationAdapter(fixtureRoot: fixtureURL("."))
        let materializer = PocketAppGenerationMaterializer(rootDirectory: draftRoot)
        let pendingV1 = try makeRequest(
            requestID: "generation-pending-v1",
            userRequest: "Create the pending focus app.",
            appID: "local.example.pending",
            version: "1.0.0",
            namespace: "today-focus"
        )
        let pendingV2 = try makeRequest(
            requestID: "generation-pending-v2",
            userRequest: pendingV1.userRequest,
            appID: pendingV1.appID,
            version: "1.0.1",
            namespace: pendingV1.namespace
        )
        let unrelated = try makeRequest(
            requestID: "generation-pending-unrelated",
            userRequest: "Create the unrelated focus app.",
            appID: "local.example.pending-unrelated",
            version: "1.0.0",
            namespace: "today-focus"
        )
        do {
            let lifecycle = try PocketAppLifecycleManager(rootDirectory: root, userDataRoot: dataRoot)
            _ = try installFixture(pendingV1, adapter: adapter, materializer: materializer, lifecycle: lifecycle)
            _ = try installFixture(pendingV2, adapter: adapter, materializer: materializer, lifecycle: lifecycle)
            _ = try installFixture(unrelated, adapter: adapter, materializer: materializer, lifecycle: lifecycle)
        }
        let controller = try PocketAppGenerationController(
            rootDirectory: root,
            userDataRoot: dataRoot,
            generationRoot: draftRoot,
            generator: nil
        )
        controller.prepareRollback(packageID: pendingV1.appID, version: pendingV1.version)
        let pendingRequestID = controller.pendingProposal?.requestID
        controller.disable(packageID: unrelated.appID)
        require(
            pendingRequestID != nil
                && controller.pendingProposal?.requestID == pendingRequestID
                && controller.phase == .awaitingApproval
                && controller.lastReceipt?.packageID == unrelated.appID
                && controller.lastReceipt?.state == .disabled,
            "generation_unrelated_action_preserves_pending_proposal",
            failures: &failures
        )
        controller.rejectPending()
    }

    private static func installFixture(
        _ request: PocketAppGenerationRequest,
        adapter: FixturePocketAppGenerationAdapter,
        materializer: PocketAppGenerationMaterializer,
        lifecycle: PocketAppLifecycleManager
    ) throws -> PocketAppLifecycleReceipt {
        let envelope = try adapter.generate(request, cancellation: PocketAppGenerationCancellation())
        let materialized = try materializer.materialize(envelope: envelope, request: request)
        defer { try? FileManager.default.removeItem(at: materialized.directory) }
        let proposal = try lifecycle.stage(draftDirectory: materialized.directory)
        let grant = try lifecycle.approve(requestID: proposal.requestID, bindingDigest: proposal.bindingDigest)
        return try lifecycle.install(proposal, approvalGrant: grant)
    }

    private static func fixtureDocument() throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL("support/pocket-app-generation.e2e.json"))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PocketAppGenerationError.outputInvalid
        }
        return object
    }

    private static func string(_ object: [String: Any], _ key: String) -> String {
        object[key] as? String ?? ""
    }

    private static func stringArray(_ object: [String: Any], _ key: String) -> [String] {
        object[key] as? [String] ?? []
    }

    private static func fixtureURL(_ relativePath: String) -> URL {
        contractURL("fixtures/\(relativePath)")
    }

    private static func contractURL(_ relativePath: String) -> URL {
        var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        while current.path != "/" {
            let candidate = current
                .appendingPathComponent("contracts/pocket/v1", isDirectory: true)
                .appendingPathComponent(relativePath, isDirectory: false)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            current.deleteLastPathComponent()
        }
        return current.appendingPathComponent("missing-contract")
    }

    private static func makeTreeMutable(_ root: URL) {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let url as URL in enumerator {
            let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            try? FileManager.default.setAttributes(
                [.posixPermissions: directory ? 0o700 : 0o600],
                ofItemAtPath: url.path
            )
        }
    }

    private static func require(_ condition: Bool, _ label: String, failures: inout [String]) {
        if !condition { failures.append(label) }
    }
}
