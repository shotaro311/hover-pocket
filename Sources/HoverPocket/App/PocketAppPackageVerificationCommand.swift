import Foundation

enum PocketAppPackageVerificationCommand {
    static func run() -> Never {
        var failures: [String] = []
        let runtime = PocketAppPackageRuntime()
        var referencePackage: PocketAppPackage?

        do {
            try withPackage { root in
                let package = try runtime.load(directory: root)
                referencePackage = package
                require(package.manifest.id == "local.example.today-focus", "package_id", failures: &failures)
                require(package.manifest.version == "1.0.0", "package_version", failures: &failures)
                require(package.manifestDigest.hasPrefix("sha256:") && package.manifestDigest.count == 71, "manifest_digest", failures: &failures)
                require(
                    package.manifestDigest == "sha256:e9c369e0b52620d95c14baa2e04070535a1f21020308090f0467eed8cf4f04df",
                    "package_digest_golden",
                    failures: &failures
                )
                require(package.surfaces["main"]?.nodeCount == 6, "package_surface", failures: &failures)
                require(package.workflows["startFocus"]?.steps.count == 2, "package_workflow", failures: &failures)
                require(package.workflows["startFocus"]?.requiredPermissions == ["sticky.write", "timer.write"], "package_permissions", failures: &failures)
                require(package.statePropertyNames == ["selectedEventRef"], "package_state_schema", failures: &failures)
                require(
                    package.testCases == [
                        "calendar-read": "pass",
                        "start-focus-approved": "pass",
                        "start-focus-idempotent-replay": "pass",
                        "start-focus-rejected": "reject"
                    ],
                    "package_tests",
                    failures: &failures
                )
                print("pocket_app_manifest_digest=\(package.manifestDigest)")
            }
        } catch {
            failures.append("valid_package:\(error)")
        }

        do {
            guard let originalDigest = referencePackage?.manifestDigest else {
                throw PocketAppPackageError.invalid("$:reference_digest")
            }
            try withPackage { root in
                try Data("Changed intent without manifest changes".utf8)
                    .write(to: root.appendingPathComponent("intent.md"), options: .atomic)
                let changed = try runtime.load(directory: root)
                require(changed.manifestDigest != originalDigest, "package_resource_digest", failures: &failures)
            }
        } catch {
            failures.append("package_resource_digest:fixture:\(error)")
        }

        do {
            guard let resourceRoot = Bundle.module.resourceURL else {
                throw PocketAppPackageError.invalid("$:bundle_resource")
            }
            let bundledRoot = resourceRoot
                .appendingPathComponent("PocketApps", isDirectory: true)
                .appendingPathComponent("local.example.today-focus", isDirectory: true)
            let bundled = try runtime.load(directory: bundledRoot)
            require(bundled.manifestDigest == referencePackage?.manifestDigest, "bundled_manifest", failures: &failures)
            require(bundled.surfaces == referencePackage?.surfaces, "bundled_surfaces", failures: &failures)
            require(bundled.workflows == referencePackage?.workflows, "bundled_workflows", failures: &failures)
            require(bundled.testCases == referencePackage?.testCases, "bundled_tests", failures: &failures)
        } catch {
            failures.append("bundled_package:\(error)")
        }

        rejectPackage("unlisted_file", failures: &failures) { root in
            try Data("unexpected".utf8).write(to: root.appendingPathComponent("unexpected.txt"))
        }
        rejectPackage("hidden_unlisted_file", failures: &failures) { root in
            try Data("unexpected".utf8).write(to: root.appendingPathComponent(".unexpected"))
        }
        rejectPackage("missing_file", failures: &failures) { root in
            try FileManager.default.removeItem(at: root.appendingPathComponent("intent.md"))
        }
        rejectPackage("symlink", failures: &failures) { root in
            let intent = root.appendingPathComponent("intent.md")
            try FileManager.default.removeItem(at: intent)
            try FileManager.default.createSymbolicLink(atPath: intent.path, withDestinationPath: fixtureURL("package/intent.md").path)
        }
        rejectPackage("oversized_file", failures: &failures) { root in
            try Data(repeating: 0x61, count: PocketAppPackageRuntime.maximumFileBytes + 1)
                .write(to: root.appendingPathComponent("intent.md"))
        }
        rejectPackage("unknown_capability", failures: &failures) { root in
            try mutateJSON(root.appendingPathComponent("manifest.json")) { manifest in
                guard var capabilities = manifest["requestedCapabilities"] as? [[String: Any]] else { return false }
                capabilities[0]["id"] = "calendar.events.delete"
                manifest["requestedCapabilities"] = capabilities
                return true
            }
        }
        rejectPackage("path_traversal", failures: &failures) { root in
            try mutateJSON(root.appendingPathComponent("manifest.json")) { manifest in
                manifest["intent"] = "../intent.md"
                return true
            }
        }
        rejectPackage("cyclic_or_forward_dependency", failures: &failures) { root in
            try mutateJSON(root.appendingPathComponent("workflows/start-focus.workflow.json")) { workflow in
                guard var steps = workflow["steps"] as? [[String: Any]] else { return false }
                steps[0]["dependsOn"] = ["savePurpose"]
                workflow["steps"] = steps
                return true
            }
        }
        rejectPackage("unbounded_workflow", failures: &failures) { root in
            try mutateJSON(root.appendingPathComponent("workflows/start-focus.workflow.json")) { workflow in
                guard var limits = workflow["limits"] as? [String: Any] else { return false }
                limits["maxSteps"] = 33
                workflow["limits"] = limits
                return true
            }
        }
        rejectPackage("unbound_surface_input", failures: &failures) { root in
            try mutateJSON(root.appendingPathComponent("surfaces/main.surface.json")) { surface in
                guard var rootNode = surface["root"] as? [String: Any],
                      var children = rootNode["children"] as? [[String: Any]] else { return false }
                children[2]["value"] = "$input.missing"
                rootNode["children"] = children
                surface["root"] = rootNode
                return true
            }
        }
        rejectPackage("surface_input_type_mismatch", failures: &failures) { root in
            try mutateJSON(root.appendingPathComponent("workflows/start-focus.workflow.json")) { workflow in
                guard var inputs = workflow["inputs"] as? [String: Any] else { return false }
                inputs["purpose"] = "integer"
                workflow["inputs"] = inputs
                return true
            }
        }
        rejectPackage("unsupported_surface_query_shape", failures: &failures) { root in
            try mutateJSON(root.appendingPathComponent("surfaces/main.surface.json")) { surface in
                guard var rootNode = surface["root"] as? [String: Any],
                      var children = rootNode["children"] as? [[String: Any]],
                      var pickerItems = children[1]["items"] as? [String: Any] else { return false }
                pickerItems["query"] = "sticky.note.get@1"
                children[1]["items"] = pickerItems
                rootNode["children"] = children
                surface["root"] = rootNode
                return true
            }
        }
        rejectPackage("unsupported_test_case", failures: &failures) { root in
            try mutateJSON(root.appendingPathComponent("tests/calendar-read.json")) { test in
                test["case"] = "custom-generated-case"
                return true
            }
        }
        rejectPackage("deep_empty_directories", failures: &failures) { root in
            let relative = Array(repeating: "nested", count: 17).joined(separator: "/")
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(relative, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        rejectPackage("excess_empty_directories", failures: &failures) { root in
            for index in 0..<257 {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent("empty-\(index)", isDirectory: true),
                    withIntermediateDirectories: false
                )
            }
        }

        MainActor.assumeIsolated {
            verifyStableKey(failures: &failures)
            verifyLifecycle(failures: &failures)
            PocketAppGenerationVerification.verify(failures: &failures)
        }

        print("pocket_app_package_verify=\(failures.isEmpty ? "ok" : "failed")")
        print("pocket_app_package_valid_files=9")
        print("pocket_app_package_bundled=ok")
        print("pocket_app_package_negative_cases=15")
        print("pocket_app_lifecycle_verify=\(failures.isEmpty ? "ok" : "failed")")
        print("pocket_app_generation_verify=\(failures.isEmpty ? "ok" : "failed")")
        if !failures.isEmpty {
            print("pocket_app_package_failures=\(failures.joined(separator: ","))")
        }
        exit(failures.isEmpty ? 0 : 1)
    }

    @MainActor
    private static func verifyStableKey(failures: inout [String]) {
        let valid = "today-focus:2026-08-15"
        require((try? PocketStableKey.validate(valid)) == valid, "stable_key_valid", failures: &failures)
        let invalid = [
            "today-focus:bad\nkey",
            "today-focus:key\n",
            "today-focus:bad\u{202E}key",
            "today-focus:bad\u{0007}key",
            "today-focus:" + String(repeating: "a", count: 90),
            "Today-focus:2026-08-15",
            "today-focus:a:b"
        ]
        for (index, value) in invalid.enumerated() {
            require((try? PocketStableKey.validate(value)) == nil, "stable_key_reject_\(index)", failures: &failures)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let principal = CapabilityPrincipal(userID: "verify", pocketAppID: "local.example.today-focus")
        let plan = CapabilityExecutionPlan(
            id: "verify-stable-key",
            createdAt: now,
            origin: .pocketSurface,
            principal: principal,
            appContext: CapabilityAppContext(
                id: "local.example.today-focus",
                version: "1.0.0",
                manifestDigest: "sha256:" + String(repeating: "0", count: 64)
            ),
            steps: [
                CapabilityPlanStep(
                    id: "savePurpose",
                    capability: PocketCapabilityKeys.stickyUpsert,
                    arguments: [
                        "stableKey": .string(valid),
                        "title": .string("Focus purpose"),
                        "body": .string("Focus"),
                        "color": .string("yellow")
                    ],
                    idempotencyKey: "verify-stable-key-0001",
                    dependencies: []
                )
            ],
            requiredPermissions: ["sticky.write"]
        )
        do {
            let digest = try CapabilityCanonicalJSON.planDigest(plan)
            let draft = PocketAppWorkflowDraft(
                packageID: "local.example.today-focus",
                workflowID: "startFocus",
                plan: plan,
                preparation: CapabilityBrokerPreparation(planDigest: digest, approvalRequest: nil)
            )
            require(PocketSurfaceHostModel.approvalSummary(draft).contains(valid), "stable_key_approval_exact", failures: &failures)
            let changedPlan = CapabilityExecutionPlan(
                id: plan.id,
                createdAt: plan.createdAt,
                origin: plan.origin,
                principal: plan.principal,
                appContext: plan.appContext,
                steps: [
                    CapabilityPlanStep(
                        id: "savePurpose",
                        capability: PocketCapabilityKeys.stickyUpsert,
                        arguments: [
                            "stableKey": .string("today-focus:2026-08-16"),
                            "title": .string("Focus purpose"),
                            "body": .string("Focus"),
                            "color": .string("yellow")
                        ],
                        idempotencyKey: "verify-stable-key-0001",
                        dependencies: []
                    )
                ],
                requiredPermissions: ["sticky.write"]
            )
            require(try CapabilityCanonicalJSON.planDigest(changedPlan) != digest, "stable_key_plan_digest", failures: &failures)
        } catch {
            failures.append("stable_key_binding:\(error)")
        }
    }

    @MainActor
    private static func verifyLifecycle(failures: inout [String]) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            try withPackage { draftRoot in
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hover-pocket-lifecycle-\(UUID().uuidString)", isDirectory: true)
                let dataRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hover-pocket-lifecycle-data-\(UUID().uuidString)", isDirectory: true)
                defer {
                    makeTreeMutable(root)
                    try? FileManager.default.removeItem(at: root)
                    try? FileManager.default.removeItem(at: dataRoot)
                }
                let manager = try PocketAppLifecycleManager(rootDirectory: root, userDataRoot: dataRoot)
                let proposal = try manager.stage(draftDirectory: draftRoot, now: now)
                require(proposal.packageDigest == "sha256:e9c369e0b52620d95c14baa2e04070535a1f21020308090f0467eed8cf4f04df", "lifecycle_stage_digest", failures: &failures)
                require(proposal.previewDigest.hasPrefix("sha256:") && proposal.previews.count == 1, "lifecycle_preview", failures: &failures)
                require(proposal.permissionDiff.added == ["calendar.events.read", "sticky.read", "sticky.write", "timer.read", "timer.write"], "lifecycle_permission_diff", failures: &failures)
                require(proposal.approvalRequired && proposal.capabilityGrantDiff.added.count == 5, "lifecycle_grant_diff", failures: &failures)
                require(
                    proposal.tests.count == 6
                        && proposal.tests.prefix(2).allSatisfy { $0.status == "pass" }
                        && proposal.tests.dropFirst(2).allSatisfy { $0.status == $0.expected },
                    "lifecycle_tests",
                    failures: &failures
                )
                do {
                    _ = try manager.install(proposal, approvalGrant: nil, now: now)
                    failures.append("lifecycle_permission_increase_accepted")
                } catch PocketAppLifecycleError.approvalRequired {
                }
                let duplicateProposal = try manager.stage(draftDirectory: draftRoot, now: now)
                require(
                    duplicateProposal.bindingDigest == proposal.bindingDigest,
                    "lifecycle_duplicate_binding_fixture",
                    failures: &failures
                )
                try Data("draft changed after staging".utf8).write(to: draftRoot.appendingPathComponent("intent.md"), options: .atomic)
                let grant = try manager.approve(requestID: proposal.requestID, bindingDigest: proposal.bindingDigest, now: now)
                do {
                    _ = try manager.install(duplicateProposal, approvalGrant: grant, now: now)
                    failures.append("lifecycle_cross_request_grant_accepted")
                } catch PocketAppLifecycleError.approvalInvalid {
                }
                var tamperedBytes = proposal.previews[0].canonicalRenderModel
                tamperedBytes[0] ^= 0xff
                let tamperedProposal = PocketAppLifecycleProposal(
                    requestID: proposal.requestID,
                    action: proposal.action,
                    packageID: proposal.packageID,
                    version: proposal.version,
                    packageDigest: proposal.packageDigest,
                    currentDigest: proposal.currentDigest,
                    currentState: proposal.currentState,
                    previewDigest: proposal.previewDigest,
                    previews: [PocketAppPreviewSurface(
                        id: proposal.previews[0].id,
                        renderDigest: proposal.previews[0].renderDigest,
                        canonicalRenderModel: tamperedBytes
                    )],
                    permissionDiff: proposal.permissionDiff,
                    capabilityGrantDiff: proposal.capabilityGrantDiff,
                    tests: proposal.tests,
                    bindingDigest: proposal.bindingDigest,
                    createdAt: proposal.createdAt,
                    expiresAt: proposal.expiresAt,
                    approvalRequired: proposal.approvalRequired,
                    stagingDirectory: proposal.stagingDirectory,
                    stateSchemaDigest: proposal.stateSchemaDigest,
                    statePropertyNames: proposal.statePropertyNames
                )
                do {
                    _ = try manager.install(tamperedProposal, approvalGrant: grant, now: now)
                    failures.append("lifecycle_tampered_preview_accepted")
                } catch PocketAppLifecycleError.packageChanged {
                }
                let installed = try manager.install(proposal, approvalGrant: grant, now: now)
                try manager.reject(
                    requestID: duplicateProposal.requestID,
                    bindingDigest: duplicateProposal.bindingDigest
                )
                require(try installed.readbackVerified && manager.activePackage(packageID: proposal.packageID)?.manifestDigest == proposal.packageDigest, "lifecycle_install_readback", failures: &failures)
                let appsRoot = root.appendingPathComponent("Apps", isDirectory: true)
                try Data("Finder metadata".utf8).write(to: appsRoot.appendingPathComponent(".DS_Store"))
                try FileManager.default.createDirectory(
                    at: appsRoot.appendingPathComponent("not-a-package", isDirectory: true),
                    withIntermediateDirectories: false
                )
                let snapshotWithUnmanagedEntries = try manager.managementSnapshot()
                require(
                    snapshotWithUnmanagedEntries.packages.contains {
                        $0.packageID == proposal.packageID && $0.state == .enabled
                    } && snapshotWithUnmanagedEntries.issues.isEmpty,
                    "lifecycle_unmanaged_entries_do_not_block_snapshot",
                    failures: &failures
                )
                try Data(contentsOf: fixtureURL("package/intent.md")).write(to: draftRoot.appendingPathComponent("intent.md"), options: .atomic)

                let installedIntent = root
                    .appendingPathComponent("Apps/\(proposal.packageID)/Versions/\(versionStorageKey(proposal.version))/\(proposal.packageDigest.dropFirst("sha256:".count))/package/intent.md")
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: installedIntent.path)
                let reharden = try manager.stage(draftDirectory: draftRoot, now: now.addingTimeInterval(0.5))
                let rehardenGrant = try manager.approve(
                    requestID: reharden.requestID,
                    bindingDigest: reharden.bindingDigest,
                    now: now.addingTimeInterval(0.5)
                )
                _ = try manager.install(reharden, approvalGrant: rehardenGrant, now: now.addingTimeInterval(0.5))
                let rehardenedAttributes = try FileManager.default.attributesOfItem(atPath: installedIntent.path)
                let rehardenedPermissions = (rehardenedAttributes[.posixPermissions] as? NSNumber)?.intValue
                require(
                    rehardenedPermissions.map { $0 & 0o222 == 0 } == true,
                    "lifecycle_existing_snapshot_rehardened",
                    failures: &failures
                )

                try mutateJSON(draftRoot.appendingPathComponent("manifest.json")) { manifest in
                    manifest["version"] = "1.0.1"
                    return true
                }
                let update = try manager.stage(draftDirectory: draftRoot, now: now.addingTimeInterval(1))
                require(update.permissionDiff.added.isEmpty && update.action == .update && update.approvalRequired, "lifecycle_update_diff", failures: &failures)
                do {
                    _ = try manager.install(update, approvalGrant: nil, now: now.addingTimeInterval(1))
                    failures.append("lifecycle_update_without_approval")
                } catch PocketAppLifecycleError.approvalRequired {
                }
                let updateGrant = try manager.approve(
                    requestID: update.requestID,
                    bindingDigest: update.bindingDigest,
                    now: now.addingTimeInterval(1)
                )
                _ = try manager.install(update, approvalGrant: updateGrant, now: now.addingTimeInterval(1))
                try mutateJSON(draftRoot.appendingPathComponent("manifest.json")) { manifest in
                    manifest["version"] = "1.0.0"
                    return true
                }
                do {
                    _ = try manager.stage(draftDirectory: draftRoot, now: now.addingTimeInterval(2))
                    failures.append("lifecycle_downgrade_update_accepted")
                } catch PocketAppLifecycleError.downgradeRequiresRollback {
                }
                let rollback = try manager.prepareRollback(packageID: proposal.packageID, version: "1.0.0", now: now.addingTimeInterval(2))
                require(rollback.approvalRequired, "lifecycle_rollback_approval", failures: &failures)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: installedIntent.path)
                let rollbackGrant = try manager.approve(
                    requestID: rollback.requestID,
                    bindingDigest: rollback.bindingDigest,
                    now: now.addingTimeInterval(2)
                )
                _ = try manager.rollback(rollback, approvalGrant: rollbackGrant, now: now.addingTimeInterval(2))
                require(try manager.activePackage(packageID: proposal.packageID)?.manifest.version == "1.0.0", "lifecycle_rollback", failures: &failures)
                let rollbackAttributes = try FileManager.default.attributesOfItem(atPath: installedIntent.path)
                let rollbackPermissions = (rollbackAttributes[.posixPermissions] as? NSNumber)?.intValue
                require(
                    rollbackPermissions.map { $0 & 0o222 == 0 } == true,
                    "lifecycle_rollback_snapshot_rehardened",
                    failures: &failures
                )
                try mutateJSON(draftRoot.appendingPathComponent("manifest.json")) { manifest in
                    manifest["version"] = "1.0.2"
                    guard var capabilities = manifest["requestedCapabilities"] as? [[String: Any]],
                          let stickyIndex = capabilities.firstIndex(where: { $0["id"] as? String == "sticky.note.get" }) else {
                        return false
                    }
                    capabilities[stickyIndex].removeValue(forKey: "scope")
                    manifest["requestedCapabilities"] = capabilities
                    return true
                }
                let authorityUpdate = try manager.stage(draftDirectory: draftRoot, now: now.addingTimeInterval(2))
                require(
                    authorityUpdate.permissionDiff.added.isEmpty
                        && !authorityUpdate.capabilityGrantDiff.added.isEmpty
                        && !authorityUpdate.capabilityGrantDiff.removed.isEmpty
                        && authorityUpdate.approvalRequired,
                    "lifecycle_effective_grant_diff",
                    failures: &failures
                )
                try manager.reject(requestID: authorityUpdate.requestID, bindingDigest: authorityUpdate.bindingDigest)
                let disabled = try manager.disable(packageID: proposal.packageID, now: now.addingTimeInterval(3))
                require(try disabled.state == .disabled && manager.activePackage(packageID: proposal.packageID) == nil, "lifecycle_disable", failures: &failures)

                let userPackage = dataRoot.appendingPathComponent(proposal.packageID, isDirectory: true)
                try FileManager.default.createDirectory(at: userPackage, withIntermediateDirectories: true)
                let sentinel = userPackage.appendingPathComponent("sentinel.txt")
                try Data("preserve".utf8).write(to: sentinel)
                _ = try manager.remove(packageID: proposal.packageID, dataDisposition: .preserve, now: now.addingTimeInterval(4))
                require(FileManager.default.fileExists(atPath: sentinel.path), "lifecycle_remove_preserve", failures: &failures)
                try mutateJSON(draftRoot.appendingPathComponent("manifest.json")) { manifest in
                    manifest["version"] = "1.0.0"
                    return true
                }
                let reinstall = try manager.stage(draftDirectory: draftRoot, now: now.addingTimeInterval(5))
                let reinstallGrant = try manager.approve(
                    requestID: reinstall.requestID,
                    bindingDigest: reinstall.bindingDigest,
                    now: now.addingTimeInterval(5)
                )
                _ = try manager.install(reinstall, approvalGrant: reinstallGrant, now: now.addingTimeInterval(5))
                do {
                    _ = try manager.remove(packageID: proposal.packageID, dataDisposition: .delete, now: now.addingTimeInterval(6))
                    failures.append("lifecycle_remove_delete_without_approval")
                } catch PocketAppLifecycleError.approvalRequired {
                }
                require(FileManager.default.fileExists(atPath: sentinel.path), "lifecycle_remove_delete_preserved", failures: &failures)
                _ = try manager.remove(packageID: proposal.packageID, dataDisposition: .preserve, now: now.addingTimeInterval(7))
            }
        } catch {
            failures.append("lifecycle_positive:\(error)")
        }

        do {
            try withPackage { draftRoot in
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("hover-pocket-lifecycle-negative-\(UUID().uuidString)", isDirectory: true)
                let dataRoot = FileManager.default.temporaryDirectory.appendingPathComponent("hover-pocket-lifecycle-negative-data-\(UUID().uuidString)", isDirectory: true)
                defer {
                    makeTreeMutable(root)
                    try? FileManager.default.removeItem(at: root)
                    try? FileManager.default.removeItem(at: dataRoot)
                }
                let manager = try PocketAppLifecycleManager(rootDirectory: root, userDataRoot: dataRoot)
                let expired = try manager.stage(draftDirectory: draftRoot, now: now)
                do {
                    _ = try manager.approve(requestID: expired.requestID, bindingDigest: expired.bindingDigest, now: now.addingTimeInterval(301))
                    failures.append("lifecycle_stale_approval_accepted")
                } catch PocketAppLifecycleError.approvalExpired {
                }
                require(
                    !FileManager.default.fileExists(atPath: expired.stagingDirectory.deletingLastPathComponent().path),
                    "lifecycle_expired_approval_cleanup",
                    failures: &failures
                )

                let expiredInstall = try manager.stage(draftDirectory: draftRoot, now: now.addingTimeInterval(302))
                let expiredInstallGrant = try manager.approve(
                    requestID: expiredInstall.requestID,
                    bindingDigest: expiredInstall.bindingDigest,
                    now: now.addingTimeInterval(302)
                )
                do {
                    _ = try manager.install(
                        expiredInstall,
                        approvalGrant: expiredInstallGrant,
                        now: now.addingTimeInterval(603)
                    )
                    failures.append("lifecycle_expired_install_accepted")
                } catch PocketAppLifecycleError.approvalExpired {
                }
                require(
                    !FileManager.default.fileExists(atPath: expiredInstall.stagingDirectory.deletingLastPathComponent().path),
                    "lifecycle_expired_install_cleanup",
                    failures: &failures
                )

                let abandoned = try manager.stage(draftDirectory: draftRoot, now: now.addingTimeInterval(604))
                let replacement = try manager.stage(draftDirectory: draftRoot, now: now.addingTimeInterval(905))
                require(
                    !FileManager.default.fileExists(atPath: abandoned.stagingDirectory.deletingLastPathComponent().path),
                    "lifecycle_stage_purges_expired",
                    failures: &failures
                )
                do {
                    try manager.reject(requestID: replacement.requestID, bindingDigest: "sha256:\(String(repeating: "0", count: 64))")
                    failures.append("lifecycle_reject_wrong_binding_accepted")
                } catch PocketAppLifecycleError.approvalInvalid {
                }
                require(
                    FileManager.default.fileExists(atPath: replacement.stagingDirectory.path),
                    "lifecycle_reject_wrong_binding_preserves_proposal",
                    failures: &failures
                )
                _ = try PocketAppLifecycleManager(rootDirectory: root, userDataRoot: dataRoot)
                require(
                    FileManager.default.fileExists(atPath: replacement.stagingDirectory.path),
                    "lifecycle_second_manager_preserves_live_staging",
                    failures: &failures
                )
                try manager.reject(requestID: replacement.requestID, bindingDigest: replacement.bindingDigest)

                let capacityPeer = try PocketAppLifecycleManager(rootDirectory: root, userDataRoot: dataRoot)
                var capacityProposals: [(PocketAppLifecycleManager, PocketAppLifecycleProposal)] = []
                for index in 0..<4 {
                    let owner = index.isMultiple(of: 2) ? manager : capacityPeer
                    capacityProposals.append((owner, try owner.stage(
                        draftDirectory: draftRoot,
                        now: now.addingTimeInterval(906 + Double(index))
                    )))
                }
                do {
                    _ = try manager.stage(draftDirectory: draftRoot, now: now.addingTimeInterval(910))
                    failures.append("lifecycle_pending_limit_not_enforced")
                } catch PocketAppLifecycleError.pendingLimitExceeded {
                }
                require(
                    capacityProposals.allSatisfy { FileManager.default.fileExists(atPath: $0.1.stagingDirectory.path) },
                    "lifecycle_pending_limit_preserves_existing",
                    failures: &failures
                )
                for (owner, pending) in capacityProposals {
                    try owner.reject(requestID: pending.requestID, bindingDigest: pending.bindingDigest)
                }

                let abandonedRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hover-pocket-lifecycle-abandoned-\(UUID().uuidString)", isDirectory: true)
                let abandonedDataRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hover-pocket-lifecycle-abandoned-data-\(UUID().uuidString)", isDirectory: true)
                defer {
                    makeTreeMutable(abandonedRoot)
                    try? FileManager.default.removeItem(at: abandonedRoot)
                    try? FileManager.default.removeItem(at: abandonedDataRoot)
                }
                let abandonedParent = try {
                    let abandonedManager = try PocketAppLifecycleManager(
                        rootDirectory: abandonedRoot,
                        userDataRoot: abandonedDataRoot
                    )
                    return try abandonedManager.stage(draftDirectory: draftRoot, now: now)
                        .stagingDirectory
                        .deletingLastPathComponent()
                }()
                _ = try PocketAppLifecycleManager(rootDirectory: abandonedRoot, userDataRoot: abandonedDataRoot)
                require(
                    !FileManager.default.fileExists(atPath: abandonedParent.path),
                    "lifecycle_abandoned_manager_cleans_staging",
                    failures: &failures
                )

                let changed = try manager.stage(draftDirectory: draftRoot, now: now)
                let changedGrant = try manager.approve(requestID: changed.requestID, bindingDigest: changed.bindingDigest, now: now)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: changed.stagingDirectory.appendingPathComponent("intent.md").path)
                try Data("tampered staged bytes".utf8).write(to: changed.stagingDirectory.appendingPathComponent("intent.md"), options: .atomic)
                do {
                    _ = try manager.install(changed, approvalGrant: changedGrant, now: now)
                    failures.append("lifecycle_digest_change_accepted")
                } catch PocketAppLifecycleError.packageChanged {
                }

                let clean = try manager.stage(draftDirectory: draftRoot, now: now)
                let cleanGrant = try manager.approve(requestID: clean.requestID, bindingDigest: clean.bindingDigest, now: now)
                _ = try manager.install(clean, approvalGrant: cleanGrant, now: now)

                let activeRecord = root.appendingPathComponent("Apps/\(clean.packageID)/active.json")
                try mutateJSON(activeRecord) { record in
                    record["permissions"] = []
                    return true
                }
                try mutateJSON(draftRoot.appendingPathComponent("manifest.json")) { manifest in
                    manifest["version"] = "1.0.1"
                    return true
                }
                let reconciled = try manager.stage(draftDirectory: draftRoot, now: now.addingTimeInterval(1))
                require(reconciled.permissionDiff.added.isEmpty, "lifecycle_active_record_permission_reconciled", failures: &failures)
                try manager.reject(requestID: reconciled.requestID, bindingDigest: reconciled.bindingDigest)

                let syncFailingManager = try PocketAppLifecycleManager(
                    rootDirectory: root,
                    userDataRoot: dataRoot,
                    failureInjection: { $0 == "snapshot_sync" }
                )
                let syncFailure = try syncFailingManager.stage(draftDirectory: draftRoot, now: now.addingTimeInterval(1))
                let syncFailureGrant = try syncFailingManager.approve(
                    requestID: syncFailure.requestID,
                    bindingDigest: syncFailure.bindingDigest,
                    now: now.addingTimeInterval(1)
                )
                do {
                    _ = try syncFailingManager.install(
                        syncFailure,
                        approvalGrant: syncFailureGrant,
                        now: now.addingTimeInterval(1)
                    )
                    failures.append("lifecycle_snapshot_sync_failure_accepted")
                } catch PocketAppLifecycleError.storageFailure {
                }
                require(
                    try syncFailingManager.activePackage(packageID: clean.packageID)?.manifest.version == "1.0.0",
                    "lifecycle_snapshot_sync_precedes_active_commit",
                    failures: &failures
                )

                let failingManager = try PocketAppLifecycleManager(
                    rootDirectory: root,
                    userDataRoot: dataRoot,
                    failureInjection: { $0 == "active_write" }
                )
                let writeFailure = try failingManager.stage(draftDirectory: draftRoot, now: now.addingTimeInterval(1))
                let writeFailureGrant = try failingManager.approve(
                    requestID: writeFailure.requestID,
                    bindingDigest: writeFailure.bindingDigest,
                    now: now.addingTimeInterval(1)
                )
                do {
                    _ = try failingManager.install(writeFailure, approvalGrant: writeFailureGrant, now: now.addingTimeInterval(1))
                    failures.append("lifecycle_write_failure_accepted")
                } catch PocketAppLifecycleError.storageFailure {
                }
                require(
                    try failingManager.activePackage(packageID: clean.packageID)?.manifest.version == "1.0.0",
                    "lifecycle_write_failure_invariant",
                    failures: &failures
                )
                let failingRemoveManager = try PocketAppLifecycleManager(
                    rootDirectory: root,
                    userDataRoot: dataRoot,
                    failureInjection: { $0 == "remove_stage" }
                )
                do {
                    _ = try failingRemoveManager.remove(
                        packageID: clean.packageID,
                        dataDisposition: .preserve,
                        now: now.addingTimeInterval(2)
                    )
                    failures.append("lifecycle_remove_failure_accepted")
                } catch PocketAppLifecycleError.storageFailure {
                }
                require(
                    try failingRemoveManager.activePackage(packageID: clean.packageID)?.manifest.version == "1.0.0",
                    "lifecycle_remove_failure_invariant",
                    failures: &failures
                )
                let recoveredIntent = root
                    .appendingPathComponent("Apps/\(clean.packageID)/Versions/\(versionStorageKey(clean.version))/\(clean.packageDigest.dropFirst("sha256:".count))/package/intent.md")
                let recoveredAttributes = try FileManager.default.attributesOfItem(atPath: recoveredIntent.path)
                let recoveredPermissions = (recoveredAttributes[.posixPermissions] as? NSNumber)?.intValue
                require(
                    recoveredPermissions.map { $0 & 0o222 == 0 } == true,
                    "lifecycle_remove_failure_rehardened",
                    failures: &failures
                )
                let recoveryVersions = root.appendingPathComponent("Apps/\(clean.packageID)/Versions", isDirectory: true)
                let recoveryTombstone = root
                    .appendingPathComponent("Apps/\(clean.packageID)/.removed-Versions-recovery", isDirectory: true)
                makeTreeMutable(recoveryVersions)
                try FileManager.default.moveItem(at: recoveryVersions, to: recoveryTombstone)
                let startupRecoveredManager = try PocketAppLifecycleManager(rootDirectory: root, userDataRoot: dataRoot)
                require(
                    try startupRecoveredManager.activePackage(packageID: clean.packageID)?.manifest.version == "1.0.0",
                    "lifecycle_startup_remove_recovery_active",
                    failures: &failures
                )
                let startupRecoveredAttributes = try FileManager.default.attributesOfItem(atPath: recoveredIntent.path)
                let startupRecoveredPermissions = (startupRecoveredAttributes[.posixPermissions] as? NSNumber)?.intValue
                require(
                    startupRecoveredPermissions.map { $0 & 0o222 == 0 } == true,
                    "lifecycle_startup_remove_recovery_rehardened",
                    failures: &failures
                )
                makeTreeMutable(recoveryVersions)
                _ = try PocketAppLifecycleManager(rootDirectory: root, userDataRoot: dataRoot)
                let repeatedRecoveryAttributes = try FileManager.default.attributesOfItem(atPath: recoveredIntent.path)
                let repeatedRecoveryPermissions = (repeatedRecoveryAttributes[.posixPermissions] as? NSNumber)?.intValue
                require(
                    repeatedRecoveryPermissions.map { $0 & 0o222 == 0 } == true,
                    "lifecycle_startup_existing_versions_rehardened",
                    failures: &failures
                )
                try mutateJSON(draftRoot.appendingPathComponent("manifest.json")) { manifest in
                    manifest["version"] = "1.0.0"
                    return true
                }
                try mutateJSON(draftRoot.appendingPathComponent("data.schema.json")) { schema in
                    guard var properties = schema["properties"] as? [String: Any] else { return false }
                    properties["newState"] = ["type": "string"]
                    schema["properties"] = properties
                    return true
                }
                do {
                    _ = try manager.stage(draftDirectory: draftRoot, now: now.addingTimeInterval(1))
                    failures.append("lifecycle_migration_accepted")
                } catch PocketAppLifecycleError.migrationRequired {
                }

                let corrupt = root
                    .appendingPathComponent("Apps/\(clean.packageID)/Versions/\(versionStorageKey(clean.version))/\(clean.packageDigest.dropFirst("sha256:".count))/package/intent.md")
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: corrupt.path)
                try Data("corrupt".utf8).write(to: corrupt)
                do {
                    _ = try manager.activePackage(packageID: clean.packageID)
                    failures.append("lifecycle_corrupt_version_accepted")
                } catch PocketAppLifecycleError.corruptVersion {
                }

                let versionsRoot = root.appendingPathComponent("Apps/\(clean.packageID)/Versions", isDirectory: true)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: versionsRoot.path)
                let interrupted = versionsRoot.appendingPathComponent("9.9.9/.installing-fixture", isDirectory: true)
                try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
                _ = try PocketAppLifecycleManager(rootDirectory: root, userDataRoot: dataRoot)
                require(!FileManager.default.fileExists(atPath: interrupted.path), "lifecycle_interrupted_cleanup", failures: &failures)
            }
        } catch {
            failures.append("lifecycle_negative:\(error)")
        }

        do {
            try withPackage { draftRoot in
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hover-pocket-lifecycle-state-binding-\(UUID().uuidString)", isDirectory: true)
                let dataRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hover-pocket-lifecycle-state-binding-data-\(UUID().uuidString)", isDirectory: true)
                let absentRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hover-pocket-lifecycle-absent-binding-\(UUID().uuidString)", isDirectory: true)
                let absentDataRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hover-pocket-lifecycle-absent-binding-data-\(UUID().uuidString)", isDirectory: true)
                defer {
                    for directory in [root, absentRoot] {
                        makeTreeMutable(directory)
                        try? FileManager.default.removeItem(at: directory)
                    }
                    try? FileManager.default.removeItem(at: dataRoot)
                    try? FileManager.default.removeItem(at: absentDataRoot)
                }

                let manager = try PocketAppLifecycleManager(rootDirectory: root, userDataRoot: dataRoot)
                let initial = try manager.stage(draftDirectory: draftRoot, now: now)
                let initialGrant = try manager.approve(
                    requestID: initial.requestID,
                    bindingDigest: initial.bindingDigest,
                    now: now
                )
                _ = try manager.install(initial, approvalGrant: initialGrant, now: now)
                try mutateJSON(draftRoot.appendingPathComponent("manifest.json")) { manifest in
                    manifest["version"] = "1.0.1"
                    return true
                }
                let enabledProposal = try manager.stage(draftDirectory: draftRoot, now: now.addingTimeInterval(1))
                let enabledGrant = try manager.approve(
                    requestID: enabledProposal.requestID,
                    bindingDigest: enabledProposal.bindingDigest,
                    now: now.addingTimeInterval(1)
                )
                _ = try manager.disable(packageID: initial.packageID, now: now.addingTimeInterval(2))
                do {
                    _ = try manager.install(enabledProposal, approvalGrant: enabledGrant, now: now.addingTimeInterval(2))
                    failures.append("lifecycle_enabled_proposal_after_disable_accepted")
                } catch PocketAppLifecycleError.activeChanged {
                }
                require(
                    try manager.activePackage(packageID: initial.packageID) == nil,
                    "lifecycle_disabled_state_preserved",
                    failures: &failures
                )
                let disabledUpdate = try manager.stage(draftDirectory: draftRoot, now: now.addingTimeInterval(3))
                require(
                    disabledUpdate.permissionDiff.added.count == 5
                        && disabledUpdate.permissionDiff.removed.isEmpty
                        && disabledUpdate.capabilityGrantDiff.added.count == 5
                        && disabledUpdate.capabilityGrantDiff.removed.isEmpty,
                    "lifecycle_disabled_update_restores_grants_only_with_approval",
                    failures: &failures
                )
                try manager.reject(requestID: disabledUpdate.requestID, bindingDigest: disabledUpdate.bindingDigest)

                try mutateJSON(draftRoot.appendingPathComponent("manifest.json")) { manifest in
                    manifest["version"] = "1.0.0"
                    return true
                }
                let absentManager = try PocketAppLifecycleManager(rootDirectory: absentRoot, userDataRoot: absentDataRoot)
                let absentProposal = try absentManager.stage(draftDirectory: draftRoot, now: now)
                let absentGrant = try absentManager.approve(
                    requestID: absentProposal.requestID,
                    bindingDigest: absentProposal.bindingDigest,
                    now: now
                )
                _ = try absentManager.remove(
                    packageID: absentProposal.packageID,
                    dataDisposition: .preserve,
                    now: now.addingTimeInterval(1)
                )
                do {
                    _ = try absentManager.install(absentProposal, approvalGrant: absentGrant, now: now.addingTimeInterval(1))
                    failures.append("lifecycle_absent_proposal_after_remove_accepted")
                } catch PocketAppLifecycleError.activeChanged {
                }
                require(
                    try absentManager.activePackage(packageID: absentProposal.packageID) == nil,
                    "lifecycle_removed_state_preserved",
                    failures: &failures
                )
            }
        } catch {
            failures.append("lifecycle_state_binding:\(error)")
        }

        do {
            try withPackage { draftRoot in
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hover-pocket-lifecycle-large-version-\(UUID().uuidString)", isDirectory: true)
                let dataRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hover-pocket-lifecycle-large-version-data-\(UUID().uuidString)", isDirectory: true)
                defer {
                    makeTreeMutable(root)
                    try? FileManager.default.removeItem(at: root)
                    try? FileManager.default.removeItem(at: dataRoot)
                }
                let manager = try PocketAppLifecycleManager(rootDirectory: root, userDataRoot: dataRoot)
                let largeVersion = String(repeating: "9", count: 59) + ".0.0"
                try mutateJSON(draftRoot.appendingPathComponent("manifest.json")) { manifest in
                    manifest["version"] = largeVersion
                    return true
                }
                let install = try manager.stage(draftDirectory: draftRoot, now: now)
                let grant = try manager.approve(
                    requestID: install.requestID,
                    bindingDigest: install.bindingDigest,
                    now: now
                )
                _ = try manager.install(install, approvalGrant: grant, now: now)
                try mutateJSON(draftRoot.appendingPathComponent("manifest.json")) { manifest in
                    manifest["version"] = "1.0.0"
                    return true
                }
                do {
                    _ = try manager.stage(draftDirectory: draftRoot, now: now.addingTimeInterval(1))
                    failures.append("lifecycle_large_version_downgrade_accepted")
                } catch PocketAppLifecycleError.downgradeRequiresRollback {
                }
            }
        } catch {
            failures.append("lifecycle_large_version:\(error)")
        }

        do {
            try withPackage { draftRoot in
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hover-pocket-lifecycle-case-version-\(UUID().uuidString)", isDirectory: true)
                let dataRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hover-pocket-lifecycle-case-version-data-\(UUID().uuidString)", isDirectory: true)
                defer {
                    makeTreeMutable(root)
                    try? FileManager.default.removeItem(at: root)
                    try? FileManager.default.removeItem(at: dataRoot)
                }
                let manager = try PocketAppLifecycleManager(rootDirectory: root, userDataRoot: dataRoot)
                try mutateJSON(draftRoot.appendingPathComponent("manifest.json")) { manifest in
                    manifest["version"] = "1.0.0-ALPHA"
                    return true
                }
                let initial = try manager.stage(draftDirectory: draftRoot, now: now)
                let initialGrant = try manager.approve(
                    requestID: initial.requestID,
                    bindingDigest: initial.bindingDigest,
                    now: now
                )
                _ = try manager.install(initial, approvalGrant: initialGrant, now: now)
                try mutateJSON(draftRoot.appendingPathComponent("manifest.json")) { manifest in
                    manifest["version"] = "1.0.0-alpha"
                    return true
                }
                let update = try manager.stage(draftDirectory: draftRoot, now: now.addingTimeInterval(1))
                let updateGrant = try manager.approve(
                    requestID: update.requestID,
                    bindingDigest: update.bindingDigest,
                    now: now.addingTimeInterval(1)
                )
                _ = try manager.install(update, approvalGrant: updateGrant, now: now.addingTimeInterval(1))
                require(
                    try manager.activePackage(packageID: initial.packageID)?.manifest.version == "1.0.0-alpha",
                    "lifecycle_case_distinct_version_update",
                    failures: &failures
                )
                let rollback = try manager.prepareRollback(
                    packageID: initial.packageID,
                    version: "1.0.0-ALPHA",
                    now: now.addingTimeInterval(2)
                )
                let rollbackGrant = try manager.approve(
                    requestID: rollback.requestID,
                    bindingDigest: rollback.bindingDigest,
                    now: now.addingTimeInterval(2)
                )
                _ = try manager.rollback(rollback, approvalGrant: rollbackGrant, now: now.addingTimeInterval(2))
                require(
                    try manager.activePackage(packageID: initial.packageID)?.manifest.version == "1.0.0-ALPHA",
                    "lifecycle_case_distinct_version_rollback",
                    failures: &failures
                )
                let versionDirectories = try FileManager.default.contentsOfDirectory(
                    at: root.appendingPathComponent("Apps/\(initial.packageID)/Versions", isDirectory: true),
                    includingPropertiesForKeys: nil
                )
                require(
                    Set(versionDirectories.map(\.lastPathComponent)).count == 2,
                    "lifecycle_case_distinct_version_storage",
                    failures: &failures
                )
            }
        } catch {
            failures.append("lifecycle_case_distinct_version:\(error)")
        }

        do {
            try withPackage { draftRoot in
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hover-pocket-lifecycle-test-gate-\(UUID().uuidString)", isDirectory: true)
                let dataRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hover-pocket-lifecycle-test-gate-data-\(UUID().uuidString)", isDirectory: true)
                defer {
                    makeTreeMutable(root)
                    try? FileManager.default.removeItem(at: root)
                    try? FileManager.default.removeItem(at: dataRoot)
                }
                let manager = try PocketAppLifecycleManager(rootDirectory: root, userDataRoot: dataRoot)
                try mutateJSON(draftRoot.appendingPathComponent("tests/calendar-read.json")) { test in
                    test["expected"] = "reject"
                    return true
                }
                do {
                    _ = try manager.stage(draftDirectory: draftRoot, now: now)
                    failures.append("lifecycle_declared_test_not_executed")
                } catch PocketAppLifecycleError.stagingTestFailed {
                }
            }
        } catch {
            failures.append("lifecycle_test_gate:\(error)")
        }

        do {
            try withPackage { draftRoot in
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hover-pocket-lifecycle-host-version-\(UUID().uuidString)", isDirectory: true)
                let dataRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hover-pocket-lifecycle-host-version-data-\(UUID().uuidString)", isDirectory: true)
                defer {
                    makeTreeMutable(root)
                    try? FileManager.default.removeItem(at: root)
                    try? FileManager.default.removeItem(at: dataRoot)
                }
                try mutateJSON(draftRoot.appendingPathComponent("manifest.json")) { manifest in
                    manifest["minHostVersion"] = "2.0.0"
                    return true
                }
                let incompatibleHost = try PocketAppLifecycleManager(rootDirectory: root, userDataRoot: dataRoot)
                do {
                    _ = try incompatibleHost.stage(draftDirectory: draftRoot, now: now)
                    failures.append("lifecycle_incompatible_stage_accepted")
                } catch PocketAppLifecycleError.hostVersionUnsupported {
                }
                let hostTwo = try PocketAppLifecycleManager(
                    rootDirectory: root,
                    userDataRoot: dataRoot,
                    hostVersion: "2.0.0"
                )
                let initial = try hostTwo.stage(draftDirectory: draftRoot, now: now)
                let initialGrant = try hostTwo.approve(
                    requestID: initial.requestID,
                    bindingDigest: initial.bindingDigest,
                    now: now
                )
                _ = try hostTwo.install(initial, approvalGrant: initialGrant, now: now)

                let hostOne = try PocketAppLifecycleManager(rootDirectory: root, userDataRoot: dataRoot)
                do {
                    _ = try hostOne.activePackage(packageID: initial.packageID)
                    failures.append("lifecycle_incompatible_active_package_accepted")
                } catch PocketAppLifecycleError.hostVersionUnsupported {
                }

                try mutateJSON(draftRoot.appendingPathComponent("manifest.json")) { manifest in
                    manifest["version"] = "2.0.0"
                    manifest["minHostVersion"] = "1.0.0"
                    return true
                }
                let update = try hostTwo.stage(draftDirectory: draftRoot, now: now.addingTimeInterval(1))
                let updateGrant = try hostTwo.approve(
                    requestID: update.requestID,
                    bindingDigest: update.bindingDigest,
                    now: now.addingTimeInterval(1)
                )
                _ = try hostTwo.install(update, approvalGrant: updateGrant, now: now.addingTimeInterval(1))
                do {
                    _ = try hostOne.prepareRollback(
                        packageID: initial.packageID,
                        version: "1.0.0",
                        now: now.addingTimeInterval(2)
                    )
                    failures.append("lifecycle_incompatible_rollback_accepted")
                } catch PocketAppLifecycleError.hostVersionUnsupported {
                }
            }
        } catch {
            failures.append("lifecycle_host_version:\(error)")
        }
    }

    private static func makeTreeMutable(_ root: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return }
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            try? fileManager.setAttributes(
                [.posixPermissions: isDirectory ? 0o700 : 0o600],
                ofItemAtPath: url.path
            )
        }
    }

    private static func rejectPackage(
        _ label: String,
        failures: inout [String],
        mutation: (URL) throws -> Void
    ) {
        do {
            try withPackage { root in
                do {
                    try mutation(root)
                    _ = try PocketAppPackageRuntime().load(directory: root)
                    failures.append("accepted:\(label)")
                } catch {
                }
            }
        } catch {
            failures.append("\(label):fixture:\(error)")
        }
    }

    private static func withPackage(body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-pocket-package-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try assemblePackage(at: root)
        try body(root)
    }

    private static func assemblePackage(at root: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.appendingPathComponent("surfaces", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("workflows", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("tests", isDirectory: true), withIntermediateDirectories: true)

        let files: [(String, String)] = [
            ("manifest.json", "valid/pocket-app.today-focus.json"),
            ("intent.md", "package/intent.md"),
            ("data.schema.json", "package/data.schema.json"),
            ("surfaces/main.surface.json", "valid/pocket-surface.today-focus.json"),
            ("workflows/start-focus.workflow.json", "valid/pocket-workflow.today-focus.json"),
            ("tests/calendar-read.json", "package/test.calendar-read.json"),
            ("tests/start-focus-approved.json", "package/test.start-focus-approved.json"),
            ("tests/start-focus-idempotent-replay.json", "package/test.start-focus-idempotent-replay.json"),
            ("tests/start-focus-rejected.json", "package/test.start-focus-rejected.json")
        ]
        for (destination, fixture) in files {
            try Data(contentsOf: fixtureURL(fixture)).write(to: root.appendingPathComponent(destination))
        }
    }

    private static func mutateJSON(
        _ url: URL,
        mutation: (inout [String: Any]) -> Bool
    ) throws {
        guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              mutation(&object) else {
            throw PocketAppPackageError.invalid("$:mutation")
        }
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    private static func fixtureURL(_ relativePath: String) -> URL {
        var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        while current.path != "/" {
            let candidate = current
                .appendingPathComponent("contracts/pocket/v1/fixtures", isDirectory: true)
                .appendingPathComponent(relativePath, isDirectory: false)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            current.deleteLastPathComponent()
        }
        return current.appendingPathComponent("missing-fixture")
    }

    private static func versionStorageKey(_ version: String) -> String {
        "v-" + version.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private static func require(_ condition: Bool, _ label: String, failures: inout [String]) {
        if !condition { failures.append(label) }
    }
}
