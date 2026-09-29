using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace HoverPocket.Shell.PocketApps;

internal sealed class PocketAppWorkspaceBackupVerifier
{
    private readonly List<string> _failures = [];

    public IReadOnlyList<string> Run()
    {
        var root = Path.Combine(Path.GetTempPath(), $"HoverPocket-WorkspaceBackup-{Guid.NewGuid():N}");
        var definitionRoot = Path.Combine(root, "GeneratedHost");
        var dataRoot = Path.Combine(root, "UserData");
        var transactionRoot = Path.Combine(root, "BackupRestore");
        try
        {
            Directory.CreateDirectory(root);
            PocketAppRuntimeReadback RuntimeReadback(PocketAppLifecycleReceipt receipt) => new(
                receipt.PackageId,
                receipt.Version,
                receipt.PackageDigest,
                receipt.EffectivePermissions);

            using var lifecycle = new PocketAppLifecycleManager(
                definitionRoot,
                dataRoot,
                activationReadback: RuntimeReadback);
            var packageRoot = Path.Combine(AppContext.BaseDirectory, "PocketApps", "local.example.today-focus");
            var package = new PocketAppPackageRuntime().Load(packageRoot);
            var proposal = lifecycle.Stage(packageRoot);
            var grant = lifecycle.Approve(proposal.RequestId, proposal.BindingDigest);
            _ = lifecycle.Install(proposal, grant);
            using var stateStore = new PocketAppUserStateStore(package.Manifest.Id, package.StateProperties, dataRoot);
            stateStore.SetString("selectedEventRef", "event-original");

            var manager = new PocketAppWorkspaceBackupManager(
                definitionRoot,
                dataRoot,
                transactionRoot,
                lifecycle,
                RuntimeReadback);
            var fixedNow = DateTimeOffset.FromUnixTimeSeconds(1_787_536_800);
            var backup = manager.ExportBytes(fixedNow);
            var repeated = manager.ExportBytes(fixedNow);
            Require(backup.AsSpan().SequenceEqual(repeated), "workspace_backup_deterministic");
            Require(backup.Length < PocketAppWorkspaceBackupManager.MaximumBackupFileBytes, "workspace_backup_bounded");

            using (var document = JsonDocument.Parse(backup))
            {
                var paths = document.RootElement.GetProperty("files").EnumerateArray()
                    .Select(item => item.GetProperty("path").GetString() ?? string.Empty)
                    .ToArray();
                Require(paths.All(path => path.StartsWith("apps/", StringComparison.Ordinal)
                    || path.StartsWith("data/", StringComparison.Ordinal)), "workspace_backup_boundary");
                Require(paths.All(path =>
                {
                    var lowered = path.ToLowerInvariant();
                    return !lowered.Contains("credential", StringComparison.Ordinal)
                        && !lowered.Contains("oauth", StringComparison.Ordinal)
                        && !lowered.Contains("audit", StringComparison.Ordinal)
                        && !lowered.Contains("codexworkspaces", StringComparison.Ordinal);
                }), "workspace_backup_secret_exclusion");
                Require(paths.Contains("data/local.example.today-focus/state.json", StringComparer.Ordinal), "workspace_backup_data");
            }

            var crossPlatformRoot = JsonNode.Parse(backup)?.AsObject() ?? throw new InvalidOperationException();
            crossPlatformRoot["sourcePlatform"] = "macos";
            var crossPlatformBytes = Encoding.UTF8.GetBytes(
                crossPlatformRoot.ToJsonString(new JsonSerializerOptions { WriteIndented = false }));
            var crossPlatformProposal = manager.PrepareRestore(crossPlatformBytes, fixedNow);
            Require(crossPlatformProposal.Changes.Count == 1, "workspace_restore_macos_portability");
            manager.Reject(crossPlatformProposal.RequestId, crossPlatformProposal.BindingDigest);

            stateStore.SetString("selectedEventRef", "event-changed");
            var restoreProposal = manager.PrepareRestore(backup, fixedNow);
            Require(
                restoreProposal.Changes.Count == 1
                && restoreProposal.Changes[0].AppId == package.Manifest.Id
                && restoreProposal.Changes[0].ToVersion == package.Manifest.Version,
                "workspace_restore_preview");
            var restoreGrant = manager.Approve(restoreProposal.RequestId, restoreProposal.BindingDigest, fixedNow);
            var receipt = manager.Restore(restoreProposal, restoreGrant, fixedNow);
            Require(
                receipt.ReadbackVerified
                && !receipt.RollbackPerformed
                && receipt.RestoredApps.Count == 1
                && receipt.RestoredApps[0].DataVersion == 1
                && StateValue(dataRoot, package.Manifest.Id, "selectedEventRef") == "event-original",
                "workspace_restore_roundtrip");

            var staleProposal = manager.PrepareRestore(backup, fixedNow);
            stateStore.SetString("selectedEventRef", "event-stale");
            var staleGrant = manager.Approve(staleProposal.RequestId, staleProposal.BindingDigest, fixedNow);
            try
            {
                _ = manager.Restore(staleProposal, staleGrant, fixedNow);
                _failures.Add("workspace_restore_stale_preview_accepted");
            }
            catch (PocketAppWorkspaceBackupException) { }
            Require(
                StateValue(dataRoot, package.Manifest.Id, "selectedEventRef") == "event-stale",
                "workspace_restore_stale_preview_side_effect");
            manager.Reject(staleProposal.RequestId, staleProposal.BindingDigest);

            var rejection = manager.PrepareRestore(backup, fixedNow);
            try
            {
                _ = manager.Approve(
                    rejection.RequestId,
                    "sha256:" + new string('0', 64),
                    fixedNow);
                _failures.Add("workspace_restore_binding_mismatch_accepted");
            }
            catch (PocketAppWorkspaceBackupException) { }
            manager.Reject(rejection.RequestId, rejection.BindingDigest);
            try
            {
                _ = manager.Approve(rejection.RequestId, rejection.BindingDigest, fixedNow);
                _failures.Add("workspace_restore_rejection_accepted");
            }
            catch (PocketAppWorkspaceBackupException) { }

            RejectMutation(backup, "workspace_restore_tamper", manager, fixedNow, rootNode =>
            {
                var files = rootNode["files"]?.AsArray() ?? throw new InvalidOperationException();
                files[0]!["contentBase64"] = "e30=";
            });
            RejectMutation(backup, "workspace_restore_traversal", manager, fixedNow, rootNode =>
            {
                var files = rootNode["files"]?.AsArray() ?? throw new InvalidOperationException();
                files[0]!["path"] = "data/local.example.today-focus/../credential.json";
            });
            RejectMutation(backup, "workspace_restore_case_collision", manager, fixedNow, rootNode =>
            {
                var files = rootNode["files"]?.AsArray() ?? throw new InvalidOperationException();
                var source = files.First(node => node?["path"]?.GetValue<string>().Contains("/package/intent.md", StringComparison.Ordinal) == true);
                var duplicate = JsonNode.Parse(source!.ToJsonString())!.AsObject();
                duplicate["path"] = duplicate["path"]!.GetValue<string>().Replace("intent.md", "Intent.md", StringComparison.Ordinal);
                files.Add(duplicate);
            });
            RejectMutation(backup, "workspace_restore_oversized_file", manager, fixedNow, rootNode =>
            {
                var files = rootNode["files"]?.AsArray() ?? throw new InvalidOperationException();
                var bytes = Enumerable.Repeat((byte)0x41, PocketAppPackageRuntime.MaximumFileBytes + 1).ToArray();
                files[0]!["size"] = bytes.Length;
                files[0]!["contentBase64"] = Convert.ToBase64String(bytes);
            });

            stateStore.SetString("selectedEventRef", "event-before-failure");
            var commitFailureRemaining = 1;
            var failingManager = new PocketAppWorkspaceBackupManager(
                definitionRoot,
                dataRoot,
                Path.Combine(root, "BackupRestoreFailure"),
                lifecycle,
                RuntimeReadback,
                point =>
                {
                    if (point != "after_app_commit" || commitFailureRemaining <= 0) { return false; }
                    commitFailureRemaining--;
                    return true;
                });
            var failingProposal = failingManager.PrepareRestore(backup, fixedNow);
            var failingGrant = failingManager.Approve(failingProposal.RequestId, failingProposal.BindingDigest, fixedNow);
            try
            {
                _ = failingManager.Restore(failingProposal, failingGrant, fixedNow);
                _failures.Add("workspace_restore_commit_failure_accepted");
            }
            catch (PocketAppWorkspaceBackupException) { }
            Require(
                StateValue(dataRoot, package.Manifest.Id, "selectedEventRef") == "event-before-failure",
                "workspace_restore_commit_failure_rollback");

            var readbackFailureRemaining = 1;
            var readbackFailingManager = new PocketAppWorkspaceBackupManager(
                definitionRoot,
                dataRoot,
                Path.Combine(root, "BackupRestoreReadbackFailure"),
                lifecycle,
                RuntimeReadback,
                point =>
                {
                    if (point != "runtime_readback" || readbackFailureRemaining <= 0) { return false; }
                    readbackFailureRemaining--;
                    return true;
                });
            var readbackProposal = readbackFailingManager.PrepareRestore(backup, fixedNow);
            var readbackGrant = readbackFailingManager.Approve(
                readbackProposal.RequestId,
                readbackProposal.BindingDigest,
                fixedNow);
            try
            {
                _ = readbackFailingManager.Restore(readbackProposal, readbackGrant, fixedNow);
                _failures.Add("workspace_restore_readback_failure_accepted");
            }
            catch (PocketAppWorkspaceBackupException) { }
            Require(
                StateValue(dataRoot, package.Manifest.Id, "selectedEventRef") == "event-before-failure",
                "workspace_restore_readback_failure_rollback");

            VerifySettingsBoundary(root, RuntimeReadback);
        }
        catch (Exception ex)
        {
            _failures.Add($"workspace_backup_fixture:{ex.GetType().Name}:{ex.Message}");
        }
        finally
        {
            try { if (Directory.Exists(root)) { Directory.Delete(root, true); } } catch { }
        }
        return _failures;
    }

    private void VerifySettingsBoundary(
        string root,
        Func<PocketAppLifecycleReceipt, PocketAppRuntimeReadback> runtimeReadback)
    {
        var definitionRoot = Path.Combine(root, "SettingsHost");
        var dataRoot = Path.Combine(root, "SettingsData");
        var draftRoot = Path.Combine(root, "SettingsDrafts");
        var exportPath = Path.Combine(root, "settings-boundary.hoverpocket-backup.json");
        var approve = false;
        using var controller = new PocketAppGenerationController(
            definitionRoot,
            dataRoot,
            draftRoot,
            null,
            runtimeActivationReadback: runtimeReadback);
        var dispatcher = new HoverPocket.Shell.Bridge.BridgeDispatcher();
        controller.AttachSettings(
            dispatcher,
            workspaceBackupExportTarget: () => exportPath,
            workspaceBackupRestoreSource: () => exportPath,
            workspaceRestoreDecision: _ => approve);

        var exported = dispatcher.ProcessRawMessageAsync(
            """{"id":"backup-export","method":"pocketApps.exportBackup"}""").GetAwaiter().GetResult();
        Require(
            exported?.Contains("\"lastBackupDigest\":\"sha256:", StringComparison.Ordinal) == true
                && !exported.Contains(exportPath, StringComparison.Ordinal),
            "workspace_backup_settings_export_boundary");

        var prepared = dispatcher.ProcessRawMessageAsync(
            """{"id":"restore-prepare","method":"pocketApps.prepareRestore"}""").GetAwaiter().GetResult();
        Require(
            prepared?.Contains("\"pending\":{", StringComparison.Ordinal) == true
                && !prepared.Contains(exportPath, StringComparison.Ordinal),
            "workspace_restore_settings_preview_boundary");
        var cancelled = dispatcher.ProcessRawMessageAsync(
            """{"id":"restore-cancel","method":"pocketApps.cancelRestore"}""").GetAwaiter().GetResult();
        Require(
            cancelled?.Contains("\"pending\":null", StringComparison.Ordinal) == true,
            "workspace_restore_settings_cancel");

        _ = dispatcher.ProcessRawMessageAsync(
            """{"id":"restore-prepare-reject","method":"pocketApps.prepareRestore"}""").GetAwaiter().GetResult();
        var rejected = dispatcher.ProcessRawMessageAsync(
            """{"id":"restore-reject","method":"pocketApps.presentRestoreApproval"}""").GetAwaiter().GetResult();
        Require(
            rejected?.Contains("\"pending\":null", StringComparison.Ordinal) == true
                && rejected.Contains("\"receipt\":null", StringComparison.Ordinal),
            "workspace_restore_settings_native_rejection");

        approve = true;
        _ = dispatcher.ProcessRawMessageAsync(
            """{"id":"restore-prepare-approve","method":"pocketApps.prepareRestore"}""").GetAwaiter().GetResult();
        var restored = dispatcher.ProcessRawMessageAsync(
            """{"id":"restore-approve","method":"pocketApps.presentRestoreApproval"}""").GetAwaiter().GetResult();
        Require(
            restored?.Contains("\"readbackVerified\":true", StringComparison.Ordinal) == true
                && restored.Contains("\"restoredApps\":[]", StringComparison.Ordinal)
                && !restored.Contains(exportPath, StringComparison.Ordinal),
            "workspace_restore_settings_readback_boundary");
    }

    private void RejectMutation(
        byte[] backup,
        string label,
        PocketAppWorkspaceBackupManager manager,
        DateTimeOffset now,
        Action<JsonObject> mutate)
    {
        try
        {
            var root = JsonNode.Parse(backup)?.AsObject() ?? throw new InvalidOperationException();
            mutate(root);
            var bytes = Encoding.UTF8.GetBytes(root.ToJsonString(new JsonSerializerOptions { WriteIndented = false }));
            _ = manager.PrepareRestore(bytes, now);
            _failures.Add($"{label}_accepted");
        }
        catch (PocketAppWorkspaceBackupException) { }
    }

    private static string? StateValue(string dataRoot, string appId, string key)
    {
        var bytes = PocketAppFileSnapshot.ReadFileNoFollow(
            dataRoot,
            $"{appId}/state.json",
            PocketAppUserStateStore.MaximumDocumentBytes);
        using var document = JsonDocument.Parse(bytes);
        return document.RootElement.TryGetProperty(key, out var value) ? value.GetString() : null;
    }

    private void Require(bool condition, string label)
    {
        if (!condition) { _failures.Add(label); }
    }
}
