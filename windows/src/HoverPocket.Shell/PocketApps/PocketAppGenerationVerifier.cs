using System.Text.Json;
using System.Text.Json.Nodes;

namespace HoverPocket.Shell.PocketApps;

internal sealed class PocketAppGenerationVerifier
{
    private readonly List<string> _failures = [];

    public IReadOnlyList<string> Run()
    {
        VerifyE2E();
        VerifySettingsApprovalBoundary().GetAwaiter().GetResult();
        VerifyPreviewOnlyBoundary().GetAwaiter().GetResult();
        VerifyCommittedReceiptSurvivesManagedRefreshFailure().GetAwaiter().GetResult();
        VerifyUnrelatedActionPreservesPendingProposal().GetAwaiter().GetResult();
        VerifyApprovalTextSanitization();
        return _failures;
    }

    private void VerifyE2E()
    {
        var root = Path.Combine(Path.GetTempPath(), $"hover-pocket-generation-host-{Guid.NewGuid():N}");
        var dataRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-generation-data-{Guid.NewGuid():N}");
        var draftRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-generation-drafts-{Guid.NewGuid():N}");
        try
        {
            Directory.CreateDirectory(draftRoot);
            var fixture = FixtureDocument();
            var fixtureRoot = FixtureRoot();
            var adapter = new FixturePocketAppGenerationAdapter(fixtureRoot);
            var materializer = new PocketAppGenerationMaterializer(draftRoot);
            using var lifecycle = new PocketAppLifecycleManager(root, dataRoot);

            var request = MakeRequest(
                RequiredString(fixture, "requestId"),
                RequiredString(fixture, "userRequest"),
                RequiredString(fixture, "appId"),
                RequiredString(fixture, "initialVersion"),
                RequiredString(fixture, "namespace"));
            Require(request.RequestDigest() == RequiredString(fixture, "expectedRequestDigest"), "generation_request_digest");
            var envelope = adapter.GenerateAsync(request, CancellationToken.None).GetAwaiter().GetResult();
            var materialized = materializer.Materialize(envelope, request);
            try
            {
                Require(
                    materialized.Package.ManifestDigest == RequiredString(fixture, "expectedInitialPackageDigest"),
                    "generation_initial_digest");
                var proposal = lifecycle.Stage(materialized.Directory);
                var expectedPermissions = fixture.GetProperty("expectedAddedPermissions")
                    .EnumerateArray()
                    .Select(item => item.GetString() ?? string.Empty)
                    .ToHashSet(StringComparer.Ordinal);
                Require(proposal.PermissionDiff.Added.ToHashSet(StringComparer.Ordinal).SetEquals(expectedPermissions), "generation_permission_diff");
                Require(proposal.ApprovalRequired && proposal.Previews.Count == 1, "generation_preview");
                Require(proposal.Tests.All(item => item.Status == item.Expected), "generation_tests");
                var grant = lifecycle.Approve(proposal.RequestId, proposal.BindingDigest);
                var installed = lifecycle.Install(proposal, grant);
                Require(installed.ReadbackVerified, "generation_install_readback");
                Require(lifecycle.ActivePackage(request.AppId)?.ManifestDigest == proposal.PackageDigest, "generation_active_digest");
            }
            finally
            {
                TryDeleteDraft(materialized.Directory);
            }

            var updateRequest = MakeRequest(
                "generation-fixture-0002",
                request.UserRequest,
                request.AppId,
                RequiredString(fixture, "updateVersion"),
                request.Namespace);
            var updateEnvelope = adapter.GenerateAsync(updateRequest, CancellationToken.None).GetAwaiter().GetResult();
            var updateMaterialized = materializer.Materialize(updateEnvelope, updateRequest);
            PocketAppLifecycleProposal update;
            try
            {
                update = lifecycle.Stage(updateMaterialized.Directory);
                Require(update.Action == PocketAppLifecycleAction.Update && update.PermissionDiff.Added.Count == 0, "generation_update");
                var updateGrant = lifecycle.Approve(update.RequestId, update.BindingDigest);
                var updated = lifecycle.Install(update, updateGrant);
                Require(updated.ReadbackVerified && updated.Version == updateRequest.Version, "generation_update_readback");
            }
            finally
            {
                TryDeleteDraft(updateMaterialized.Directory);
            }

            var managed = lifecycle.ManagedPackages().FirstOrDefault(item => item.PackageId == request.AppId);
            Require(
                managed?.Version == updateRequest.Version
                    && managed?.PackageDigest == update.PackageDigest
                    && managed?.InstalledVersions.Contains(request.Version, StringComparer.Ordinal) == true,
                "generation_managed_readback");

            var rollback = lifecycle.PrepareRollback(request.AppId, request.Version);
            var rollbackGrant = lifecycle.Approve(rollback.RequestId, rollback.BindingDigest);
            var rolledBack = lifecycle.Rollback(rollback, rollbackGrant);
            Require(rolledBack.ReadbackVerified && rolledBack.Version == request.Version, "generation_rollback");

            var disabled = lifecycle.Disable(request.AppId);
            Require(disabled.ReadbackVerified && disabled.State == PocketAppLifecycleState.Disabled, "generation_disable");
            var enabled = lifecycle.Enable(request.AppId);
            Require(
                enabled.ReadbackVerified
                    && enabled.State == PocketAppLifecycleState.Enabled
                    && lifecycle.ActivePackage(request.AppId)?.ManifestDigest == enabled.PackageDigest,
                "generation_enable_readback");
            var disabledAgain = lifecycle.Disable(request.AppId);
            Require(
                disabledAgain.ReadbackVerified && disabledAgain.State == PocketAppLifecycleState.Disabled,
                "generation_disable_after_enable");
            var failEnableReadback = true;
            using (var failingEnableLifecycle = new PocketAppLifecycleManager(
                root,
                dataRoot,
                failureInjection: point =>
                {
                    if (point != "enable_readback" || !failEnableReadback) { return false; }
                    failEnableReadback = false;
                    return true;
                }))
            {
                try
                {
                    _ = failingEnableLifecycle.Enable(request.AppId);
                    _failures.Add("generation_enable_readback_failure_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_READBACK_FAILED")
                {
                }
                var restoredDisabled = failingEnableLifecycle.ManagedPackages()
                    .FirstOrDefault(item => item.PackageId == request.AppId);
                Require(
                    restoredDisabled?.State == PocketAppLifecycleState.Disabled
                        && failingEnableLifecycle.ActivePackage(request.AppId) is null,
                    "generation_enable_readback_failure_restored_disabled");
            }
            var installedIntent = Path.Combine(
                root,
                "Apps",
                request.AppId,
                "Versions",
                VersionStorageKey(disabledAgain.Version!),
                disabledAgain.PackageDigest!["sha256:".Length..],
                "package",
                "intent.md");
            var originalIntent = File.ReadAllBytes(installedIntent);
            var packageRaceApplied = false;
            using (var packageRaceLifecycle = new PocketAppLifecycleManager(
                root,
                dataRoot,
                failureInjection: point =>
                {
                    if (point != "enable_package_readback" || packageRaceApplied) { return false; }
                    File.SetAttributes(installedIntent, File.GetAttributes(installedIntent) & ~FileAttributes.ReadOnly);
                    File.WriteAllText(installedIntent, "corrupt-during-enable-readback");
                    packageRaceApplied = true;
                    return false;
                }))
            {
                try
                {
                    _ = packageRaceLifecycle.Enable(request.AppId);
                    _failures.Add("generation_enable_package_race_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_CORRUPT_VERSION")
                {
                }
                File.WriteAllBytes(installedIntent, originalIntent);
                File.SetAttributes(installedIntent, File.GetAttributes(installedIntent) | FileAttributes.ReadOnly);
                var restoredDisabled = packageRaceLifecycle.ManagedPackages()
                    .FirstOrDefault(item => item.PackageId == request.AppId);
                Require(
                    packageRaceApplied
                        && restoredDisabled?.State == PocketAppLifecycleState.Disabled
                        && packageRaceLifecycle.ActivePackage(request.AppId) is null,
                    "generation_enable_package_race_restored_disabled");
            }
            var packageDataRoot = Path.Combine(dataRoot, request.AppId);
            Directory.CreateDirectory(packageDataRoot);
            var sentinel = Path.Combine(packageDataRoot, "sentinel.txt");
            File.WriteAllText(sentinel, "preserve");
            var removed = lifecycle.Remove(request.AppId, PocketAppDataDisposition.Preserve);
            Require(
                removed.ReadbackVerified
                    && removed.State == PocketAppLifecycleState.Removed
                    && removed.DataDisposition == PocketAppDataDisposition.Preserve
                    && File.Exists(sentinel),
                "generation_remove_preserve");

            var tampered = envelope with { RequestDigest = "sha256:" + new string('0', 64) };
            try
            {
                _ = materializer.Materialize(tampered, request);
                _failures.Add("generation_tampered_envelope_accepted");
            }
            catch (PocketAppGenerationException ex) when (ex.Code == "GENERATION_ENVELOPE_MISMATCH")
            {
            }

            var unsafeFiles = envelope.Files.ToArray();
            unsafeFiles[0] = unsafeFiles[0] with { Path = "../manifest.json" };
            var unsafeEnvelope = envelope with { Files = unsafeFiles };
            try
            {
                _ = materializer.Materialize(unsafeEnvelope, request);
                _failures.Add("generation_unsafe_path_accepted");
            }
            catch (PocketAppGenerationException ex) when (ex.Code == "GENERATION_PATH_UNSAFE")
            {
            }

            using (var cancelled = new CancellationTokenSource())
            {
                cancelled.Cancel();
                try
                {
                    _ = adapter.GenerateAsync(request, cancelled.Token).GetAwaiter().GetResult();
                    _failures.Add("generation_cancel_ignored");
                }
                catch (OperationCanceledException)
                {
                }
            }

            VerifySchemaParity();
            VerifyRealOutputFixture(request);
            VerifyPromptAndVersioning(request);
            VerifyRootPin();
            VerifyGenerationStartupDoesNotRecover();
        }
        catch (Exception ex)
        {
            _failures.Add($"generation_e2e:{ex.GetType().Name}:{ex.Message}");
        }
        finally
        {
            try
            {
                if (Directory.Exists(root))
                {
                    PocketAppVerifierFileSystem.MakeTreeMutable(root);
                    Directory.Delete(root, true);
                }
            }
            catch { }
            try { if (Directory.Exists(dataRoot)) { Directory.Delete(dataRoot, true); } } catch { }
            try { if (Directory.Exists(draftRoot)) { Directory.Delete(draftRoot, true); } } catch { }
        }
    }

    private void VerifySchemaParity()
    {
        var source = JsonNode.Parse(File.ReadAllText(ContractPath("pocket-app-generation-output.schema.json")));
        var runtime = JsonNode.Parse(PocketAppGenerationContract.OutputSchemaJson);
        Require(
            source is not null
                && runtime is not null
                && source.ToJsonString() == runtime.ToJsonString(),
            "generation_schema_parity");
        var schemaProperty = source?["properties"]?["$schema"];
        Require(
            schemaProperty?["type"]?.GetValue<string>() == "string"
                && schemaProperty?["const"]?.GetValue<string>() == PocketAppGenerationContract.SchemaId,
            "generation_schema_const_type");
    }

    private void VerifyRealOutputFixture(PocketAppGenerationRequest request)
    {
        var root = Path.Combine(Path.GetTempPath(), $"hover-pocket-real-output-host-{Guid.NewGuid():N}");
        var dataRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-real-output-data-{Guid.NewGuid():N}");
        var draftRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-real-output-draft-{Guid.NewGuid():N}");
        try
        {
            Directory.CreateDirectory(draftRoot);
            var bytes = File.ReadAllBytes(Path.Combine(FixtureRoot(), "support", "pocket-app-generation.real-codex-output.json"));
            var envelope = PocketAppGenerationContract.DecodeEnvelope(bytes);
            var materializer = new PocketAppGenerationMaterializer(draftRoot);
            var materialized = materializer.Materialize(envelope, request);
            try
            {
                using var lifecycle = new PocketAppLifecycleManager(root, dataRoot);
                var proposal = lifecycle.Stage(materialized.Directory);
                Require(proposal.Tests.All(item => item.Status == item.Expected), "generation_real_output_tests");
                Require(proposal.Previews.Count > 0, "generation_real_output_preview");
                Require(proposal.PermissionDiff.Added.Count > 0, "generation_real_output_permission_diff");
                Require(proposal.CapabilityGrantDiff.Added.Count > 0, "generation_real_output_grant_diff");
                var grant = lifecycle.Approve(proposal.RequestId, proposal.BindingDigest);
                var receipt = lifecycle.Install(proposal, grant);
                var active = lifecycle.ActivePackage(request.AppId);
                Require(
                    receipt.ReadbackVerified
                        && receipt.PackageDigest == proposal.PackageDigest
                        && active?.ManifestDigest == proposal.PackageDigest,
                    "generation_real_output_active_readback");
            }
            finally
            {
                TryDeleteDraft(materialized.Directory);
            }
        }
        finally
        {
            try
            {
                if (Directory.Exists(root))
                {
                    PocketAppVerifierFileSystem.MakeTreeMutable(root);
                    Directory.Delete(root, true);
                }
            }
            catch { }
            try { if (Directory.Exists(dataRoot)) { Directory.Delete(dataRoot, true); } } catch { }
            try { if (Directory.Exists(draftRoot)) { Directory.Delete(draftRoot, true); } } catch { }
        }
    }

    private void VerifyPromptAndVersioning(PocketAppGenerationRequest request)
    {
        var prompt = PocketAppGenerationContract.Prompt(request);
        Require(prompt.Contains("\"apiVersion\":\"hoverpocket.app/v1\"", StringComparison.Ordinal), "generation_prompt_manifest_shape");
        Require(prompt.Contains("\"approval\":{\"mode\":\"before_writes\"", StringComparison.Ordinal), "generation_prompt_workflow_shape");
        Require(prompt.Contains("Explicitly forbidden legacy output", StringComparison.Ordinal), "generation_prompt_legacy_rejection");
        var largePatch = new string('9', 59);
        var expected = "1.0.1" + new string('0', 59);
        Require(
            PocketAppGenerationController.NextPatchVersion($"1.0.{largePatch}") == expected,
            "generation_large_patch_increment");
        Require(
            PocketAppGenerationController.NextVersion(["1.0.0", "1.0.1"], "1.0.0") == "1.0.2",
            "generation_update_after_rollback_uses_highest_version");
        Require(
            PocketAppGenerationController.RollbackVersions(["1.0.0", "1.0.1"], "1.0.0").Count == 0
                && PocketAppGenerationController.RollbackVersions(["1.0.0", "1.0.1"], "1.0.1")
                    .SequenceEqual(["1.0.0"], StringComparer.Ordinal),
            "generation_rollback_targets_only_older_versions");
        Require(
            PocketAppGenerationController.ShouldRejectPendingProposal(
                "local.example.focus",
                "local.example.focus")
                && !PocketAppGenerationController.ShouldRejectPendingProposal(
                    "local.example.calendar",
                    "local.example.focus"),
            "generation_remove_rejects_only_same_package_proposal");
        Require(
            CodexPocketAppGenerationAdapter.ResolveExecutable() is null,
            "generation_real_codex_confidentiality_gate");
    }

    private void VerifyRootPin()
    {
        var parent = Path.Combine(Path.GetTempPath(), $"hover-pocket-generation-pin-{Guid.NewGuid():N}");
        var file = Path.Combine(parent, "not-a-directory");
        try
        {
            Directory.CreateDirectory(parent);
            File.WriteAllText(file, "fixture");
            try
            {
                using var _ = new PocketAppPinnedDirectory(Path.Combine(file, "child"));
                _failures.Add("generation_unsafe_root_accepted");
            }
            catch (Exception ex) when (ex is PocketAppGenerationException or IOException or UnauthorizedAccessException)
            {
            }
        }
        finally
        {
            try { if (Directory.Exists(parent)) { Directory.Delete(parent, true); } } catch { }
        }
    }

    private void VerifyGenerationStartupDoesNotRecover()
    {
        var root = Path.Combine(Path.GetTempPath(), $"hover-pocket-generation-no-recovery-host-{Guid.NewGuid():N}");
        var dataRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-generation-no-recovery-data-{Guid.NewGuid():N}");
        var draftRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-generation-no-recovery-draft-{Guid.NewGuid():N}");
        try
        {
            var abandoned = Path.Combine(root, "Staging", "abandoned");
            Directory.CreateDirectory(abandoned);
            var sentinel = Path.Combine(abandoned, "sentinel.txt");
            File.WriteAllText(sentinel, "preserve-until-explicit-recovery");
            using var controller = new PocketAppGenerationController(root, dataRoot, draftRoot, null);
            Require(File.Exists(sentinel), "generation_startup_recovery_disabled");
        }
        finally
        {
            try
            {
                if (Directory.Exists(root))
                {
                    PocketAppVerifierFileSystem.MakeTreeMutable(root);
                    Directory.Delete(root, true);
                }
            }
            catch { }
            try { if (Directory.Exists(dataRoot)) { Directory.Delete(dataRoot, true); } } catch { }
            try { if (Directory.Exists(draftRoot)) { Directory.Delete(draftRoot, true); } } catch { }
        }
    }

    private async Task VerifySettingsApprovalBoundary()
    {
        var root = Path.Combine(Path.GetTempPath(), $"hover-pocket-generation-approval-host-{Guid.NewGuid():N}");
        var dataRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-generation-approval-data-{Guid.NewGuid():N}");
        var draftRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-generation-approval-draft-{Guid.NewGuid():N}");
        try
        {
            var approve = false;
            using var controller = new PocketAppGenerationController(
                root,
                dataRoot,
                draftRoot,
                new FixturePocketAppGenerationAdapter(FixtureRoot()));
            var settings = new HoverPocket.Shell.Bridge.BridgeDispatcher();
            controller.AttachSettings(settings, approvalDecision: _ => approve);
            var panel = new HoverPocket.Shell.Bridge.BridgeDispatcher();
            var panelResponse = await panel.ProcessRawMessageAsync(
                """{"id":"panel","method":"pocketApps.presentApproval","params":{}}""");
            Require(panelResponse?.Contains("\"code\":\"unknown_method\"", StringComparison.Ordinal) == true, "generation_panel_route_absent");

            const string generate =
                """{"id":"generate","method":"pocketApps.generate","params":{"request":"Create a Today Focus panel."}}""";
            var generated = await settings.ProcessRawMessageAsync(generate);
            Require(generated?.Contains("\"phase\":\"awaiting_approval\"", StringComparison.Ordinal) == true, "generation_native_approval_stage");
            var rejected = await settings.ProcessRawMessageAsync(
                """{"id":"reject-native","method":"pocketApps.presentApproval","params":{}}""");
            Require(
                rejected?.Contains("\"phase\":\"idle\"", StringComparison.Ordinal) == true
                    && rejected.Contains("\"managedApps\":[]", StringComparison.Ordinal),
                "generation_native_approval_no_click");

            generated = await settings.ProcessRawMessageAsync(generate.Replace("\"generate\"", "\"generate-2\"", StringComparison.Ordinal));
            Require(generated?.Contains("\"phase\":\"awaiting_approval\"", StringComparison.Ordinal) == true, "generation_native_approval_restage");
            approve = true;
            var installed = await settings.ProcessRawMessageAsync(
                """{"id":"approve-native","method":"pocketApps.presentApproval","params":{}}""");
            Require(
                installed?.Contains("\"phase\":\"installed\"", StringComparison.Ordinal) == true
                    && installed.Contains("\"readbackVerified\":true", StringComparison.Ordinal),
                "generation_native_approval_readback");
            var replay = await settings.ProcessRawMessageAsync(
                """{"id":"approve-replay","method":"pocketApps.presentApproval","params":{}}""");
            Require(
                replay?.Contains("GENERATION_APPROVAL_MISMATCH", StringComparison.Ordinal) == true,
                "generation_native_approval_replay");
        }
        catch (Exception ex)
        {
            _failures.Add($"generation_native_approval:{ex.GetType().Name}:{ex.Message}");
        }
        finally
        {
            try
            {
                if (Directory.Exists(root))
                {
                    PocketAppVerifierFileSystem.MakeTreeMutable(root);
                    Directory.Delete(root, true);
                }
            }
            catch { }
            try { if (Directory.Exists(dataRoot)) { Directory.Delete(dataRoot, true); } } catch { }
            try { if (Directory.Exists(draftRoot)) { Directory.Delete(draftRoot, true); } } catch { }
        }
    }

    private async Task VerifyPreviewOnlyBoundary()
    {
        var root = Path.Combine(Path.GetTempPath(), $"hover-pocket-generation-preview-host-{Guid.NewGuid():N}");
        var dataRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-generation-preview-data-{Guid.NewGuid():N}");
        var draftRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-generation-preview-draft-{Guid.NewGuid():N}");
        try
        {
            using var controller = new PocketAppGenerationController(
                root,
                dataRoot,
                draftRoot,
                new PreviewOnlyFixtureAdapter(FixtureRoot()));
            var settings = new HoverPocket.Shell.Bridge.BridgeDispatcher();
            controller.AttachSettings(settings, approvalDecision: _ => true);
            var generated = await settings.ProcessRawMessageAsync(
                """{"id":"preview-generate","method":"pocketApps.generate","params":{"request":"Create a Today Focus panel."}}""");
            Require(
                generated is not null
                    && generated.Contains("\"phase\":\"awaiting_approval\"", StringComparison.Ordinal)
                    && generated.Contains("\"activationAllowed\":false", StringComparison.Ordinal),
                "generation_preview_only_stage");
            var attempted = await settings.ProcessRawMessageAsync(
                """{"id":"preview-approve","method":"pocketApps.presentApproval","params":{}}""");
            Require(
                attempted is not null
                    && attempted.Contains("GENERATION_PREVIEW_ONLY", StringComparison.Ordinal)
                    && !attempted.Contains("\"phase\":\"installed\"", StringComparison.Ordinal),
                "generation_preview_only_activation_denied");
        }
        catch (Exception ex)
        {
            _failures.Add($"generation_preview_only:{ex.GetType().Name}:{ex.Message}");
        }
        finally
        {
            try
            {
                if (Directory.Exists(root))
                {
                    PocketAppVerifierFileSystem.MakeTreeMutable(root);
                    Directory.Delete(root, true);
                }
            }
            catch { }
            try { if (Directory.Exists(dataRoot)) { Directory.Delete(dataRoot, true); } } catch { }
            try { if (Directory.Exists(draftRoot)) { Directory.Delete(draftRoot, true); } } catch { }
        }
    }

    private async Task VerifyCommittedReceiptSurvivesManagedRefreshFailure()
    {
        var root = Path.Combine(Path.GetTempPath(), $"hover-pocket-generation-refresh-host-{Guid.NewGuid():N}");
        var dataRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-generation-refresh-data-{Guid.NewGuid():N}");
        var draftRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-generation-refresh-draft-{Guid.NewGuid():N}");
        try
        {
            Directory.CreateDirectory(draftRoot);
            var adapter = new FixturePocketAppGenerationAdapter(FixtureRoot());
            var materializer = new PocketAppGenerationMaterializer(draftRoot);
            using var lifecycle = new PocketAppLifecycleManager(root, dataRoot);
            var selected = MakeRequest(
                "generation-refresh-selected",
                "Create the selected focus app.",
                "local.example.selected",
                "1.0.0",
                "today-focus");
            var unrelated = MakeRequest(
                "generation-refresh-unrelated",
                "Create an unrelated focus app.",
                "local.example.unrelated",
                "1.0.0",
                "today-focus");
            _ = InstallFixture(selected, adapter, materializer, lifecycle);
            var unrelatedReceipt = InstallFixture(unrelated, adapter, materializer, lifecycle);
            if (unrelatedReceipt.Version is null || unrelatedReceipt.PackageDigest is null)
            {
                throw new InvalidOperationException("Fixture install did not produce a versioned receipt.");
            }
            var digestRoot = Path.Combine(
                root,
                "Apps",
                unrelated.AppId,
                "Versions",
                VersionStorageKey(unrelatedReceipt.Version),
                unrelatedReceipt.PackageDigest["sha256:".Length..]);
            var intent = Path.Combine(digestRoot, "package", "intent.md");
            var corruptionApplied = false;
            using var controller = new PocketAppGenerationController(
                root,
                dataRoot,
                draftRoot,
                null,
                postCommitHook: () =>
                {
                    if (corruptionApplied) { return; }
                    PocketAppVerifierFileSystem.MakeTreeMutable(digestRoot);
                    File.WriteAllText(intent, "corrupt-after-commit");
                    corruptionApplied = true;
                });
            var settings = new HoverPocket.Shell.Bridge.BridgeDispatcher();
            controller.AttachSettings(settings, approvalDecision: _ => true);
            var response = await settings.ProcessRawMessageAsync(
                """{"id":"disable-refresh","method":"pocketApps.disable","params":{"appId":"local.example.selected"}}""");
            Require(corruptionApplied, "generation_post_commit_corruption_fixture");
            Require(
                response is not null
                    && response.Contains("\"phase\":\"disabled\"", StringComparison.Ordinal)
                    && response.Contains("\"errorCode\":null", StringComparison.Ordinal)
                    && response.Contains("\"action\":\"disable\"", StringComparison.Ordinal)
                    && response.Contains("\"readbackVerified\":true", StringComparison.Ordinal)
                    && response.Contains("\"appId\":\"local.example.selected\",\"state\":\"disabled\"", StringComparison.Ordinal),
                "generation_committed_receipt_survives_unrelated_refresh_failure");
        }
        catch (Exception ex)
        {
            _failures.Add($"generation_committed_receipt:{ex.GetType().Name}:{ex.Message}");
        }
        finally
        {
            try
            {
                if (Directory.Exists(root))
                {
                    PocketAppVerifierFileSystem.MakeTreeMutable(root);
                    Directory.Delete(root, true);
                }
            }
            catch { }
            try { if (Directory.Exists(dataRoot)) { Directory.Delete(dataRoot, true); } } catch { }
            try { if (Directory.Exists(draftRoot)) { Directory.Delete(draftRoot, true); } } catch { }
        }
    }

    private async Task VerifyUnrelatedActionPreservesPendingProposal()
    {
        var root = Path.Combine(Path.GetTempPath(), $"hover-pocket-generation-pending-host-{Guid.NewGuid():N}");
        var dataRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-generation-pending-data-{Guid.NewGuid():N}");
        var draftRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-generation-pending-draft-{Guid.NewGuid():N}");
        try
        {
            Directory.CreateDirectory(draftRoot);
            var adapter = new FixturePocketAppGenerationAdapter(FixtureRoot());
            var materializer = new PocketAppGenerationMaterializer(draftRoot);
            var pendingV1 = MakeRequest(
                "generation-pending-v1",
                "Create the pending focus app.",
                "local.example.pending",
                "1.0.0",
                "today-focus");
            var pendingV2 = MakeRequest(
                "generation-pending-v2",
                pendingV1.UserRequest,
                pendingV1.AppId,
                "1.0.1",
                pendingV1.Namespace);
            var unrelated = MakeRequest(
                "generation-pending-unrelated",
                "Create the unrelated focus app.",
                "local.example.pending-unrelated",
                "1.0.0",
                "today-focus");
            using (var lifecycle = new PocketAppLifecycleManager(root, dataRoot))
            {
                _ = InstallFixture(pendingV1, adapter, materializer, lifecycle);
                _ = InstallFixture(pendingV2, adapter, materializer, lifecycle);
                _ = InstallFixture(unrelated, adapter, materializer, lifecycle);
            }
            using var controller = new PocketAppGenerationController(root, dataRoot, draftRoot, null);
            var settings = new HoverPocket.Shell.Bridge.BridgeDispatcher();
            controller.AttachSettings(settings, approvalDecision: _ => true);
            var pending = await settings.ProcessRawMessageAsync(
                """{"id":"pending-rollback","method":"pocketApps.prepareRollback","params":{"appId":"local.example.pending","version":"1.0.0"}}""");
            var disabled = await settings.ProcessRawMessageAsync(
                """{"id":"pending-disable","method":"pocketApps.disable","params":{"appId":"local.example.pending-unrelated"}}""");
            Require(
                pending is not null
                    && pending.Contains("\"phase\":\"awaitingApproval\"", StringComparison.Ordinal)
                    && disabled is not null
                    && disabled.Contains("\"phase\":\"awaitingApproval\"", StringComparison.Ordinal)
                    && disabled.Contains("\"appId\":\"local.example.pending\"", StringComparison.Ordinal)
                    && disabled.Contains("\"action\":\"disable\"", StringComparison.Ordinal)
                    && disabled.Contains("\"appId\":\"local.example.pending-unrelated\",\"state\":\"disabled\"", StringComparison.Ordinal),
                "generation_unrelated_action_preserves_pending_proposal");
        }
        catch (Exception ex)
        {
            _failures.Add($"generation_pending_preservation:{ex.GetType().Name}:{ex.Message}");
        }
        finally
        {
            try
            {
                if (Directory.Exists(root))
                {
                    PocketAppVerifierFileSystem.MakeTreeMutable(root);
                    Directory.Delete(root, true);
                }
            }
            catch { }
            try { if (Directory.Exists(dataRoot)) { Directory.Delete(dataRoot, true); } } catch { }
            try { if (Directory.Exists(draftRoot)) { Directory.Delete(draftRoot, true); } } catch { }
        }
    }

    private void VerifyApprovalTextSanitization()
    {
        var now = DateTimeOffset.UtcNow;
        var proposal = new PocketAppLifecycleProposal(
            "request-safe",
            PocketAppLifecycleAction.Install,
            "local.example.safe",
            "1.0.0",
            "sha256:" + new string('a', 64),
            null,
            null,
            "sha256:" + new string('b', 64),
            Array.Empty<PocketAppPreviewSurface>(),
            new PocketAppPermissionDiff(["calendar.events.read\nspoof\u202E"], []),
            new PocketAppCapabilityGrantDiff(["{\"capabilityId\":\"safe\u202Eevil\",\"capabilityVersion\":1}"], []),
            Array.Empty<PocketAppStagingTestResult>(),
            "sha256:" + new string('c', 64),
            now,
            now.AddMinutes(5),
            true,
            "staging",
            "sha256:" + new string('d', 64),
            new HashSet<string>(StringComparer.Ordinal));
        var text = PocketAppGenerationController.ApprovalPresentationText(proposal);
        Require(
            !text.Contains('\u202E')
                && !text.Contains("read\nspoof", StringComparison.Ordinal)
                && text.Contains("capabilityVersion", StringComparison.Ordinal)
                && text.Contains(proposal.PackageDigest, StringComparison.Ordinal)
                && text.Contains(proposal.BindingDigest, StringComparison.Ordinal),
            "generation_native_approval_sanitized_exact");
    }

    private sealed class PreviewOnlyFixtureAdapter(string fixtureRoot) : IPocketAppGenerationAdapter
    {
        private readonly FixturePocketAppGenerationAdapter _inner = new(fixtureRoot);

        public bool AllowsActivation => false;

        public Task<PocketAppGenerationEnvelope> GenerateAsync(
            PocketAppGenerationRequest request,
            CancellationToken cancellationToken) =>
            _inner.GenerateAsync(request, cancellationToken);
    }

    private static PocketAppGenerationRequest MakeRequest(
        string requestId,
        string userRequest,
        string appId,
        string version,
        string @namespace)
    {
        var request = new PocketAppGenerationRequest(
            requestId,
            userRequest,
            appId,
            version,
            @namespace,
            PocketAppGenerationCapability.BoundedCatalog(@namespace));
        request.Validate();
        return request;
    }

    private static PocketAppLifecycleReceipt InstallFixture(
        PocketAppGenerationRequest request,
        FixturePocketAppGenerationAdapter adapter,
        PocketAppGenerationMaterializer materializer,
        PocketAppLifecycleManager lifecycle)
    {
        var envelope = adapter.GenerateAsync(request, CancellationToken.None).GetAwaiter().GetResult();
        var materialized = materializer.Materialize(envelope, request);
        try
        {
            var proposal = lifecycle.Stage(materialized.Directory);
            var grant = lifecycle.Approve(proposal.RequestId, proposal.BindingDigest);
            return lifecycle.Install(proposal, grant);
        }
        finally
        {
            TryDeleteDraft(materialized.Directory);
        }
    }

    private static string VersionStorageKey(string version) =>
        "v-" + Convert.ToHexString(System.Text.Encoding.UTF8.GetBytes(version)).ToLowerInvariant();

    private static JsonElement FixtureDocument()
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(FixtureRoot(), "support", "pocket-app-generation.e2e.json")));
        return document.RootElement.Clone();
    }

    private static string RequiredString(JsonElement element, string property) =>
        element.GetProperty(property).GetString() ?? string.Empty;

    private static string FixtureRoot() => ContractPath("fixtures");

    private static string ContractPath(string relativePath)
    {
        var current = new DirectoryInfo(Environment.CurrentDirectory);
        while (current is not null)
        {
            var candidate = Path.Combine(current.FullName, "contracts", "pocket", "v1", relativePath.Replace('/', Path.DirectorySeparatorChar));
            if (File.Exists(candidate) || Directory.Exists(candidate)) { return candidate; }
            current = current.Parent;
        }
        throw new FileNotFoundException(relativePath);
    }

    private static void TryDeleteDraft(string directory)
    {
        try { if (Directory.Exists(directory)) { Directory.Delete(directory, true); } } catch { }
    }

    private void Require(bool condition, string label)
    {
        if (!condition) { _failures.Add(label); }
    }
}
