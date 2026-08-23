using System.Text;
using System.Text.Json.Nodes;
using HoverPocket.Shell.Capabilities;
using HoverPocket.Shell.Verification;

namespace HoverPocket.Shell.PocketApps;

internal sealed class PocketAppCapabilityMigrationVerifier
{
    private readonly List<string> _failures = [];

    internal IReadOnlyList<string> Run()
    {
        var source = CapabilityIds.TimerGet;
        var target = CapabilityIds.ControlsVolumeGet;
        var migration = new PocketCapabilityReferenceMigration(
            "timer-countdown-get-v1-to-controls-volume-get-v1",
            source,
            target);

        try
        {
            var deprecatedCatalog = Catalog(
                PocketCapabilityLifecycleStatus.Deprecated,
                "2.0.0",
                source,
                target,
                migration);
            Require(deprecatedCatalog.Status(source) == PocketCapabilityLifecycleStatus.Deprecated, "compatibility_deprecated_status");
            Require(deprecatedCatalog.Issue(source)?.Replacement == target, "compatibility_replacement");
            deprecatedCatalog.RequireRuntimeExecutable(source);

            WithBundledPackage(sourceRoot =>
            {
                var destination = Path.Combine(Path.GetTempPath(), $"hover-pocket-migrated-{Guid.NewGuid():N}");
                try
                {
                    var original = new PocketAppPackageRuntime(
                        compatibilityCatalog: deprecatedCatalog).Load(sourceRoot);
                    Require(original.CompatibilityIssues.Count == 1, "migration_source_issue");
                    var receipt = new PocketAppCapabilityMigrator(catalog: deprecatedCatalog).Migrate(
                        sourceRoot,
                        destination,
                        "1.0.1");
                    var migrated = new PocketAppPackageRuntime(
                        compatibilityCatalog: deprecatedCatalog).Load(destination);
                    Require(receipt.PackageId == original.Manifest.Id, "migration_package_id");
                    Require(receipt.SourceVersion == "1.0.0" && receipt.TargetVersion == "1.0.1", "migration_versions");
                    Require(receipt.MigrationIds.SequenceEqual([migration.Id]), "migration_ids");
                    Require(receipt.ReplacementCounts[migration.Id] == 1, "migration_count");
                    Require(receipt.SourcePackageDigest == original.ManifestDigest, "migration_source_digest");
                    Require(receipt.TargetPackageDigest == migrated.ManifestDigest, "migration_target_digest");
                    Require(receipt.StateSchemaDigest == original.StateSchemaDigest, "migration_state_schema");
                    Require(receipt.UserDataStore == original.Manifest.StateStore, "migration_data_store");
                    Require(migrated.CompatibilityIssues.Count == 0, "migration_target_active");
                    Require(
                        migrated.Manifest.RequestedCapabilities.Any(item => item.Key == target)
                        && !migrated.Manifest.RequestedCapabilities.Any(item => item.Key == source),
                        "migration_manifest_reference");
                    var sourceReadback = new PocketAppPackageRuntime(
                        compatibilityCatalog: deprecatedCatalog).Load(sourceRoot);
                    Require(sourceReadback.Manifest.Version == "1.0.0", "migration_source_immutable");
                }
                finally
                {
                    if (Directory.Exists(destination)) { Directory.Delete(destination, recursive: true); }
                }
            });

            WithBundledPackage(sourceRoot =>
            {
                var lifecycleRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-migration-lifecycle-{Guid.NewGuid():N}");
                var dataRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-migration-data-{Guid.NewGuid():N}");
                try
                {
                    using var manager = new PocketAppLifecycleManager(
                        lifecycleRoot,
                        dataRoot,
                        runtime: new PocketAppPackageRuntime(compatibilityCatalog: deprecatedCatalog),
                        compatibilityCatalog: deprecatedCatalog);
                    var initialProposal = manager.Stage(sourceRoot);
                    var initialGrant = manager.Approve(initialProposal.RequestId, initialProposal.BindingDigest);
                    var initialReceipt = manager.Install(initialProposal, initialGrant);
                    Require(initialReceipt.ReadbackVerified, "migration_lifecycle_initial_install");
                    var pendingSnapshot = manager.ManagementSnapshot();
                    Require(
                        pendingSnapshot.Issues.Any(issue =>
                            issue.PackageId == initialProposal.PackageId
                            && issue.ErrorCode == "LIFECYCLE_CAPABILITY_DEPRECATED"
                            && issue.MigrationAvailable
                            && issue.SuggestedVersion == "1.0.1"),
                        "migration_lifecycle_management_issue");

                    var migrationProposal = manager.PrepareCapabilityMigration(
                        initialProposal.PackageId,
                        "1.0.1");
                    Require(migrationProposal.ApprovalRequired, "migration_lifecycle_approval_required");
                    Require(
                        migrationProposal.CapabilityGrantDiff.Added.Count != 0
                        && migrationProposal.CapabilityGrantDiff.Removed.Count != 0,
                        "migration_lifecycle_grant_diff");
                    Require(
                        manager.ActivePackage(initialProposal.PackageId)?.Manifest.Version == "1.0.0",
                        "migration_lifecycle_source_active_before_approval");
                    var migrationGrant = manager.Approve(
                        migrationProposal.RequestId,
                        migrationProposal.BindingDigest);
                    var migrationReceipt = manager.Install(migrationProposal, migrationGrant);
                    Require(
                        migrationReceipt.ReadbackVerified && migrationReceipt.Version == "1.0.1",
                        "migration_lifecycle_install_readback");
                    var finalSnapshot = manager.ManagementSnapshot();
                    Require(finalSnapshot.Issues.Count == 0, "migration_lifecycle_issue_cleared");
                    Require(
                        finalSnapshot.Packages.FirstOrDefault()?.InstalledVersions.SequenceEqual(["1.0.0", "1.0.1"]) == true,
                        "migration_lifecycle_versions_preserved");
                    _ = manager.Remove(initialProposal.PackageId, PocketAppDataDisposition.Preserve);
                }
                finally
                {
                    try { if (Directory.Exists(lifecycleRoot)) { Directory.Delete(lifecycleRoot, true); } } catch { }
                    try { if (Directory.Exists(dataRoot)) { Directory.Delete(dataRoot, true); } } catch { }
                }
            });
        }
        catch (Exception error)
        {
            _failures.Add($"capability_migration_success:{error.GetType().Name}:{error.Message}");
        }

        try
        {
            var removedCatalog = Catalog(
                PocketCapabilityLifecycleStatus.Removed,
                "3.0.0",
                source,
                target,
                migration);
            try
            {
                removedCatalog.RequireRuntimeExecutable(source);
                _failures.Add("compatibility_removed_executed");
            }
            catch (CapabilityBrokerException error)
            {
                Require(error.Code == "CAPABILITY_REMOVED", "compatibility_removed_binding");
            }
            WithBundledPackage(root =>
            {
                var snapshot = PocketAppFileSnapshot.Capture(root);
                var runtime = new PocketAppPackageRuntime(compatibilityCatalog: removedCatalog);
                try
                {
                    _ = runtime.Load(snapshot);
                    _failures.Add("compatibility_removed_package_activated");
                }
                catch (PocketAppPackageRuntimeException error)
                {
                    Require(error.Path.Contains(":removed", StringComparison.Ordinal), "compatibility_removed_package_error");
                }
                var migrationSource = runtime.LoadMigrationSource(snapshot);
                Require(
                    migrationSource.CompatibilityIssues.FirstOrDefault()?.Status == PocketCapabilityLifecycleStatus.Removed,
                    "compatibility_removed_migration_source");
            });
        }
        catch (Exception error)
        {
            _failures.Add($"capability_removed_gate:{error.GetType().Name}:{error.Message}");
        }

        try
        {
            _ = new PocketCapabilityCompatibilityCatalog(
                "2.0.0",
                [Record(
                    PocketCapabilityLifecycleStatus.Deprecated,
                    source,
                    target,
                    migration.Id,
                    "2.0.0",
                    "2.0.0")],
                [migration]);
            _failures.Add("compatibility_zero_window_accepted");
        }
        catch (PocketCapabilityCompatibilityException error)
        {
            Require(error.Code == "deprecation_window", "compatibility_zero_window_wrong_error");
        }

        try
        {
            WithBundledPackage(root =>
            {
                var snapshot = PocketAppFileSnapshot.Capture(root);
                var package = new PocketAppPackageRuntime().Load(snapshot);
                var calendarMigration = new PocketCapabilityReferenceMigration(
                    "calendar-list-v1-to-v2",
                    CapabilityIds.CalendarList,
                    new PocketCapabilityKey(CapabilityIds.CalendarList.Id, 2));
                var timerMigration = new PocketCapabilityReferenceMigration(
                    "timer-start-v1-to-v2",
                    CapabilityIds.TimerStart,
                    new PocketCapabilityKey(CapabilityIds.TimerStart.Id, 2));
                var rewritten = new PocketAppCapabilityMigrator().RewriteForVerification(
                    snapshot,
                    package,
                    "1.0.1",
                    [calendarMigration, timerMigration],
                    Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N")));
                Require(rewritten.Counts[calendarMigration.Id] == 2, "migration_surface_reference_count");
                Require(rewritten.Counts[timerMigration.Id] == 2, "migration_workflow_reference_count");
                Require(
                    rewritten.Snapshot.Files[package.Manifest.StateSchemaPath].AsSpan()
                        .SequenceEqual(snapshot.Files[package.Manifest.StateSchemaPath]),
                    "migration_state_bytes_immutable");
                var surface = Encoding.UTF8.GetString(rewritten.Snapshot.Files["surfaces/main.surface.json"]);
                var workflow = Encoding.UTF8.GetString(rewritten.Snapshot.Files["workflows/start-focus.workflow.json"]);
                Require(surface.Contains("calendar.events.list@2", StringComparison.Ordinal), "migration_surface_reference");
                Require(workflow.Contains("timer.countdown.start@2", StringComparison.Ordinal), "migration_workflow_reference");
            });
        }
        catch (Exception error)
        {
            _failures.Add($"capability_migration_rewrite:{error.GetType().Name}:{error.Message}");
        }

        VerifyConsole.WriteLine($"pocket_app_capability_migration_verify={(_failures.Count == 0 ? "ok" : "failed")}");
        return _failures;
    }

    private static PocketCapabilityCompatibilityCatalog Catalog(
        PocketCapabilityLifecycleStatus status,
        string hostVersion,
        PocketCapabilityKey source,
        PocketCapabilityKey target,
        PocketCapabilityReferenceMigration migration) =>
        new(
            hostVersion,
            [Record(status, source, target, migration.Id, "2.0.0", "3.0.0")],
            [migration]);

    private static PocketCapabilityLifecycleRecord Record(
        PocketCapabilityLifecycleStatus status,
        PocketCapabilityKey source,
        PocketCapabilityKey target,
        string migrationId,
        string deprecatedIn,
        string removalNotBefore) =>
        new(
            source,
            status,
            "1.0.0",
            deprecatedIn,
            removalNotBefore,
            target,
            migrationId,
            "capability.timer.countdown.get.deprecated");

    private void WithBundledPackage(Action<string> body)
    {
        var bundled = Path.Combine(AppContext.BaseDirectory, "PocketApps", "local.example.today-focus");
        var temporary = Path.Combine(Path.GetTempPath(), $"hover-pocket-migration-source-{Guid.NewGuid():N}");
        CopyTree(bundled, temporary);
        try
        {
            body(temporary);
        }
        finally
        {
            if (Directory.Exists(temporary)) { Directory.Delete(temporary, recursive: true); }
        }
    }

    private static void CopyTree(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var directory in Directory.EnumerateDirectories(source, "*", SearchOption.AllDirectories))
        {
            Directory.CreateDirectory(Path.Combine(destination, Path.GetRelativePath(source, directory)));
        }
        foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            var target = Path.Combine(destination, Path.GetRelativePath(source, file));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(file, target, overwrite: false);
        }
    }

    private void Require(bool condition, string name)
    {
        if (!condition) { _failures.Add(name); }
    }
}
