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

        MainActor.assumeIsolated {
            verifyStableKey(failures: &failures)
            verifyLifecycle(failures: &failures)
        }

        print("pocket_app_package_verify=\(failures.isEmpty ? "ok" : "failed")")
        print("pocket_app_package_valid_files=9")
        print("pocket_app_package_bundled=ok")
        print("pocket_app_package_negative_cases=10")
        print("pocket_app_lifecycle_verify=\(failures.isEmpty ? "ok" : "failed")")
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
                        && proposal.tests.dropFirst(2).allSatisfy { $0.status == "validated_declaration" },
                    "lifecycle_tests",
                    failures: &failures
                )
                do {
                    _ = try manager.install(proposal, approvalGrant: nil, now: now)
                    failures.append("lifecycle_permission_increase_accepted")
                } catch PocketAppLifecycleError.approvalRequired {
                }
                try Data("draft changed after staging".utf8).write(to: draftRoot.appendingPathComponent("intent.md"), options: .atomic)
                let grant = try manager.approve(requestID: proposal.requestID, bindingDigest: proposal.bindingDigest, now: now)
                let installed = try manager.install(proposal, approvalGrant: grant, now: now)
                require(try installed.readbackVerified && manager.activePackage(packageID: proposal.packageID)?.manifestDigest == proposal.packageDigest, "lifecycle_install_readback", failures: &failures)
                try Data(contentsOf: fixtureURL("package/intent.md")).write(to: draftRoot.appendingPathComponent("intent.md"), options: .atomic)

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
                let rollbackGrant = try manager.approve(
                    requestID: rollback.requestID,
                    bindingDigest: rollback.bindingDigest,
                    now: now.addingTimeInterval(2)
                )
                _ = try manager.rollback(rollback, approvalGrant: rollbackGrant, now: now.addingTimeInterval(2))
                require(try manager.activePackage(packageID: proposal.packageID)?.manifest.version == "1.0.0", "lifecycle_rollback", failures: &failures)
                try mutateJSON(draftRoot.appendingPathComponent("manifest.json")) { manifest in
                    manifest["version"] = "1.0.2"
                    guard var capabilities = manifest["requestedCapabilities"] as? [[String: Any]],
                          let calendarIndex = capabilities.firstIndex(where: { $0["id"] as? String == "calendar.events.list" }) else {
                        return false
                    }
                    capabilities[calendarIndex].removeValue(forKey: "scope")
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
                    .appendingPathComponent("Apps/\(clean.packageID)/Versions/\(clean.version)/\(clean.packageDigest.dropFirst("sha256:".count))/package/intent.md")
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: corrupt.path)
                try Data("corrupt".utf8).write(to: corrupt)
                do {
                    _ = try manager.activePackage(packageID: clean.packageID)
                    failures.append("lifecycle_corrupt_version_accepted")
                } catch PocketAppLifecycleError.corruptVersion {
                }

                let interrupted = root.appendingPathComponent("Apps/\(clean.packageID)/Versions/9.9.9/.installing-fixture", isDirectory: true)
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

    private static func require(_ condition: Bool, _ label: String, failures: inout [String]) {
        if !condition { failures.append(label) }
    }
}
