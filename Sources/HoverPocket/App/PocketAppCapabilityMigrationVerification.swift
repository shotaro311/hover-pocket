import Foundation

@MainActor
enum PocketAppCapabilityMigrationVerification {
    static func verify(failures: inout [String]) {
        let source = PocketCapabilityKeys.timerGet
        let target = PocketCapabilityKeys.controlsVolumeGet
        let migration = PocketCapabilityReferenceMigration(
            id: "timer-countdown-get-v1-to-controls-volume-get-v1",
            source: source,
            target: target
        )

        do {
            let deprecatedCatalog = try catalog(
                status: .deprecated,
                hostVersion: "2.0.0",
                source: source,
                target: target,
                migration: migration
            )
            require(deprecatedCatalog.status(for: source) == .deprecated, "compatibility_deprecated_status", failures: &failures)
            require(deprecatedCatalog.issue(for: source)?.replacement == target, "compatibility_replacement", failures: &failures)
            try deprecatedCatalog.requireRuntimeExecutable(source)

            try withBundledPackage { sourceRoot in
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hover-pocket-migrated-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: destination) }
                let original = try PocketAppPackageRuntime(
                    compatibilityCatalog: deprecatedCatalog
                ).load(directory: sourceRoot)
                require(original.compatibilityIssues.count == 1, "migration_source_issue", failures: &failures)

                let receipt = try PocketAppCapabilityMigrator(catalog: deprecatedCatalog).migrate(
                    sourceDirectory: sourceRoot,
                    destinationDirectory: destination,
                    targetVersion: "1.0.1"
                )
                let migrated = try PocketAppPackageRuntime(
                    compatibilityCatalog: deprecatedCatalog
                ).load(directory: destination)
                require(receipt.packageID == original.manifest.id, "migration_package_id", failures: &failures)
                require(receipt.sourceVersion == "1.0.0" && receipt.targetVersion == "1.0.1", "migration_versions", failures: &failures)
                require(receipt.migrationIDs == [migration.id], "migration_ids", failures: &failures)
                require(receipt.replacementCounts[migration.id] == 1, "migration_count", failures: &failures)
                require(receipt.sourcePackageDigest == original.manifestDigest, "migration_source_digest", failures: &failures)
                require(receipt.targetPackageDigest == migrated.manifestDigest, "migration_target_digest", failures: &failures)
                require(receipt.stateSchemaDigest == original.stateSchemaDigest, "migration_state_schema", failures: &failures)
                require(receipt.userDataStore == original.manifest.stateStore, "migration_data_store", failures: &failures)
                require(migrated.compatibilityIssues.isEmpty, "migration_target_active", failures: &failures)
                require(
                    migrated.manifest.requestedCapabilities.contains(where: { $0.key == target })
                        && !migrated.manifest.requestedCapabilities.contains(where: { $0.key == source }),
                    "migration_manifest_reference",
                    failures: &failures
                )
                let sourceReadback = try PocketAppPackageRuntime(
                    compatibilityCatalog: deprecatedCatalog
                ).load(directory: sourceRoot)
                require(sourceReadback.manifest.version == "1.0.0", "migration_source_immutable", failures: &failures)
            }

            try withBundledPackage { sourceRoot in
                let lifecycleRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hover-pocket-migration-lifecycle-\(UUID().uuidString)", isDirectory: true)
                let dataRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hover-pocket-migration-data-\(UUID().uuidString)", isDirectory: true)
                defer {
                    try? FileManager.default.removeItem(at: lifecycleRoot)
                    try? FileManager.default.removeItem(at: dataRoot)
                }
                let manager = try PocketAppLifecycleManager(
                    rootDirectory: lifecycleRoot,
                    userDataRoot: dataRoot,
                    runtime: PocketAppPackageRuntime(compatibilityCatalog: deprecatedCatalog),
                    compatibilityCatalog: deprecatedCatalog
                )
                let initialProposal = try manager.stage(draftDirectory: sourceRoot)
                let initialGrant = try manager.approve(
                    requestID: initialProposal.requestID,
                    bindingDigest: initialProposal.bindingDigest
                )
                let initialReceipt = try manager.install(initialProposal, approvalGrant: initialGrant)
                require(initialReceipt.readbackVerified, "migration_lifecycle_initial_install", failures: &failures)
                let pendingSnapshot = try manager.managementSnapshot()
                require(
                    pendingSnapshot.issues.contains {
                        $0.packageID == initialProposal.packageID
                            && $0.errorCode == "LIFECYCLE_CAPABILITY_DEPRECATED"
                            && $0.migrationAvailable
                            && $0.suggestedVersion == "1.0.1"
                    },
                    "migration_lifecycle_management_issue",
                    failures: &failures
                )

                let migrationProposal = try manager.prepareCapabilityMigration(
                    packageID: initialProposal.packageID,
                    targetVersion: "1.0.1"
                )
                require(migrationProposal.approvalRequired, "migration_lifecycle_approval_required", failures: &failures)
                require(
                    !migrationProposal.capabilityGrantDiff.added.isEmpty
                        && !migrationProposal.capabilityGrantDiff.removed.isEmpty,
                    "migration_lifecycle_grant_diff",
                    failures: &failures
                )
                let activeBeforeApproval = try manager.activePackage(packageID: initialProposal.packageID)
                require(
                    activeBeforeApproval?.manifest.version == "1.0.0",
                    "migration_lifecycle_source_active_before_approval",
                    failures: &failures
                )
                let migrationGrant = try manager.approve(
                    requestID: migrationProposal.requestID,
                    bindingDigest: migrationProposal.bindingDigest
                )
                let migrationReceipt = try manager.install(migrationProposal, approvalGrant: migrationGrant)
                require(
                    migrationReceipt.readbackVerified && migrationReceipt.version == "1.0.1",
                    "migration_lifecycle_install_readback",
                    failures: &failures
                )
                let finalSnapshot = try manager.managementSnapshot()
                require(finalSnapshot.issues.isEmpty, "migration_lifecycle_issue_cleared", failures: &failures)
                require(
                    finalSnapshot.packages.first?.installedVersions == ["1.0.0", "1.0.1"],
                    "migration_lifecycle_versions_preserved",
                    failures: &failures
                )
                _ = try manager.remove(
                    packageID: initialProposal.packageID,
                    dataDisposition: .preserve
                )
            }
        } catch {
            failures.append("capability_migration_success:\(error)")
        }

        do {
            let removedCatalog = try catalog(
                status: .removed,
                hostVersion: "3.0.0",
                source: source,
                target: target,
                migration: migration
            )
            do {
                try removedCatalog.requireRuntimeExecutable(source)
                failures.append("compatibility_removed_executed")
            } catch CapabilityBrokerError.removedCapability(let key, let replacement) {
                require(key == source && replacement == target, "compatibility_removed_binding", failures: &failures)
            }
            try withBundledPackage { root in
                let snapshot = try PocketAppFileSnapshot.capture(directory: root)
                let runtime = PocketAppPackageRuntime(compatibilityCatalog: removedCatalog)
                do {
                    _ = try runtime.load(snapshot: snapshot)
                    failures.append("compatibility_removed_package_activated")
                } catch PocketAppPackageError.invalid(let path) {
                    require(path.contains(":removed"), "compatibility_removed_package_error", failures: &failures)
                }
                let migrationSource = try runtime.loadMigrationSource(snapshot: snapshot)
                require(migrationSource.compatibilityIssues.first?.status == .removed, "compatibility_removed_migration_source", failures: &failures)
            }
        } catch {
            failures.append("capability_removed_gate:\(error)")
        }

        do {
            _ = try PocketCapabilityCompatibilityCatalog(
                hostVersion: "2.0.0",
                records: [record(
                    status: .deprecated,
                    source: source,
                    target: target,
                    migrationID: migration.id,
                    deprecatedIn: "2.0.0",
                    removalNotBefore: "2.0.0"
                )],
                migrations: [migration]
            )
            failures.append("compatibility_zero_window_accepted")
        } catch PocketCapabilityCompatibilityError.invalidPolicy("deprecation_window") {
        } catch {
            failures.append("compatibility_zero_window_wrong_error:\(error)")
        }

        do {
            try withBundledPackage { root in
                let snapshot = try PocketAppFileSnapshot.capture(directory: root)
                let package = try PocketAppPackageRuntime().load(snapshot: snapshot)
                let calendarMigration = PocketCapabilityReferenceMigration(
                    id: "calendar-list-v1-to-v2",
                    source: PocketCapabilityKeys.calendarList,
                    target: PocketCapabilityKey(id: PocketCapabilityKeys.calendarList.id, version: 2)
                )
                let timerMigration = PocketCapabilityReferenceMigration(
                    id: "timer-start-v1-to-v2",
                    source: PocketCapabilityKeys.timerStart,
                    target: PocketCapabilityKey(id: PocketCapabilityKeys.timerStart.id, version: 2)
                )
                let rewritten = try PocketAppCapabilityMigrator().rewriteForVerification(
                    snapshot: snapshot,
                    package: package,
                    targetVersion: "1.0.1",
                    migrations: [calendarMigration, timerMigration],
                    destinationDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                )
                require(rewritten.counts[calendarMigration.id] == 2, "migration_surface_reference_count", failures: &failures)
                require(rewritten.counts[timerMigration.id] == 2, "migration_workflow_reference_count", failures: &failures)
                require(rewritten.snapshot.files[package.manifest.stateSchemaPath] == snapshot.files[package.manifest.stateSchemaPath], "migration_state_bytes_immutable", failures: &failures)
                let surface = try JSONSerialization.jsonObject(
                    with: rewritten.snapshot.files["surfaces/main.surface.json"]!,
                    options: []
                ) as? [String: Any]
                let surfaceText = String(data: try JSONSerialization.data(withJSONObject: surface ?? [:]), encoding: .utf8) ?? ""
                require(surfaceText.contains("calendar.events.list@2"), "migration_surface_reference", failures: &failures)
                let workflowText = String(
                    data: rewritten.snapshot.files["workflows/start-focus.workflow.json"]!,
                    encoding: .utf8
                ) ?? ""
                require(workflowText.contains("timer.countdown.start@2"), "migration_workflow_reference", failures: &failures)
            }
        } catch {
            failures.append("capability_migration_rewrite:\(error)")
        }
    }

    private static func catalog(
        status: PocketCapabilityLifecycleStatus,
        hostVersion: String,
        source: PocketCapabilityKey,
        target: PocketCapabilityKey,
        migration: PocketCapabilityReferenceMigration
    ) throws -> PocketCapabilityCompatibilityCatalog {
        try PocketCapabilityCompatibilityCatalog(
            hostVersion: hostVersion,
            records: [record(
                status: status,
                source: source,
                target: target,
                migrationID: migration.id,
                deprecatedIn: "2.0.0",
                removalNotBefore: "3.0.0"
            )],
            migrations: [migration]
        )
    }

    private static func record(
        status: PocketCapabilityLifecycleStatus,
        source: PocketCapabilityKey,
        target: PocketCapabilityKey,
        migrationID: String,
        deprecatedIn: String,
        removalNotBefore: String
    ) -> PocketCapabilityLifecycleRecord {
        PocketCapabilityLifecycleRecord(
            key: source,
            status: status,
            introducedInHostVersion: "1.0.0",
            deprecatedInHostVersion: deprecatedIn,
            removalNotBeforeHostVersion: removalNotBefore,
            replacement: target,
            migrationID: migrationID,
            noticeKey: "capability.timer.countdown.get.deprecated"
        )
    }

    private static func withBundledPackage(_ body: (URL) throws -> Void) throws {
        guard let resourceRoot = Bundle.module.resourceURL else {
            throw PocketAppCapabilityMigrationError.invalid("bundle")
        }
        let bundled = resourceRoot
            .appendingPathComponent("PocketApps", isDirectory: true)
            .appendingPathComponent("local.example.today-focus", isDirectory: true)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-pocket-migration-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: bundled, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try body(temporary)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ name: String, failures: inout [String]) {
        if !condition() { failures.append(name) }
    }
}
