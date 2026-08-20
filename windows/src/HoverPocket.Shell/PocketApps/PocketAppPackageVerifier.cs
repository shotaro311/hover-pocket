using System.Collections.Concurrent;
using System.Text;
using System.Text.Json.Nodes;
using HoverPocket.Shell.Capabilities;
using HoverPocket.Shell.Verification;

namespace HoverPocket.Shell.PocketApps;

internal sealed class PocketAppPackageVerifier
{
    private readonly List<string> _failures = [];

    public int Run()
    {
        PocketAppPackage? referencePackage = null;
        WithPackage(root =>
        {
            var package = new PocketAppPackageRuntime().Load(root);
            referencePackage = package;
            Require(package.Manifest.Id == "local.example.today-focus", "package_id");
            Require(package.Manifest.Version == "1.0.0", "package_version");
            Require(package.ManifestDigest.StartsWith("sha256:", StringComparison.Ordinal) && package.ManifestDigest.Length == 71, "manifest_digest");
            Require(
                package.ManifestDigest == "sha256:e9c369e0b52620d95c14baa2e04070535a1f21020308090f0467eed8cf4f04df",
                "package_digest_golden");
            Require(package.Surfaces["main"].NodeCount == 6, "package_surface");
            Require(package.Workflows["startFocus"].Steps.Count == 2, "package_workflow");
            Require(package.Workflows["startFocus"].RequiredPermissions.SetEquals(["sticky.write", "timer.write"]), "package_permissions");
            Require(package.StatePropertyNames.SetEquals(["selectedEventRef"]), "package_state_schema");
            Require(package.StatePropertyTypes["selectedEventRef"].SetEquals(["string", "null"]), "package_state_types");
            Require(
                package.StateProperties["selectedEventRef"] is
                {
                    IsRequired: true,
                    Format: null,
                    MaximumLength: null
                },
                "package_state_constraints");
            Require(
                package.TestCases.Count == 4
                && package.TestCases["calendar-read"] == "pass"
                && package.TestCases["start-focus-approved"] == "pass"
                && package.TestCases["start-focus-idempotent-replay"] == "pass"
                && package.TestCases["start-focus-rejected"] == "reject",
                "package_tests");
            VerifyConsole.WriteLine($"pocket_app_manifest_digest={package.ManifestDigest}");
        }, "valid_package");

        WithPackage(root =>
        {
            if (referencePackage is null)
            {
                throw new InvalidOperationException("reference_package");
            }
            File.WriteAllText(
                Path.Combine(root, "intent.md"),
                "Changed intent without manifest changes",
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            var changed = new PocketAppPackageRuntime().Load(root);
            Require(changed.ManifestDigest != referencePackage.ManifestDigest, "package_resource_digest");
        }, "package_resource_digest");

        try
        {
            if (referencePackage is null)
            {
                throw new InvalidOperationException("reference_package");
            }
            var bundledRoot = Path.Combine(AppContext.BaseDirectory, "PocketApps", "local.example.today-focus");
            var bundled = new PocketAppPackageRuntime().Load(bundledRoot);
            VerifyConsole.WriteLine($"pocket_app_bundled_manifest_digest={bundled.ManifestDigest}");
            Require(bundled.ManifestDigest == referencePackage.ManifestDigest, "bundled_manifest");
            Require(bundled.Surfaces["main"].CanonicalRenderModelBytes().AsSpan().SequenceEqual(
                referencePackage.Surfaces["main"].CanonicalRenderModelBytes()), "bundled_surfaces");
            Require(bundled.Workflows["startFocus"].Id == referencePackage.Workflows["startFocus"].Id
                && bundled.Workflows["startFocus"].Steps.Count == referencePackage.Workflows["startFocus"].Steps.Count
                && bundled.Workflows["startFocus"].RequiredPermissions.SetEquals(referencePackage.Workflows["startFocus"].RequiredPermissions), "bundled_workflows");
            Require(bundled.TestCases.OrderBy(item => item.Key).SequenceEqual(
                referencePackage.TestCases.OrderBy(item => item.Key)), "bundled_tests");
        }
        catch (Exception ex)
        {
            _failures.Add($"bundled_package:{ex.GetType().Name}:{ex.Message}");
        }

        RejectPackage("unlisted_file", root => File.WriteAllText(Path.Combine(root, "unexpected.txt"), "unexpected", Encoding.UTF8));
        RejectPackage("hidden_unlisted_file", root => File.WriteAllText(Path.Combine(root, ".unexpected"), "unexpected", Encoding.UTF8));
        RejectPackage("missing_file", root => File.Delete(Path.Combine(root, "intent.md")));
        RejectPackage("oversized_file", root => File.WriteAllBytes(Path.Combine(root, "intent.md"), new byte[PocketAppPackageRuntime.MaximumFileBytes + 1]));
        RejectPackage("unknown_capability", root => MutateJson(Path.Combine(root, "manifest.json"), manifest =>
        {
            manifest["requestedCapabilities"]![0]!["id"] = "calendar.events.delete";
        }));
        RejectPackage("path_traversal", root => MutateJson(Path.Combine(root, "manifest.json"), manifest =>
        {
            manifest["intent"] = "../intent.md";
        }));
        RejectPackage("cyclic_or_forward_dependency", root => MutateJson(Path.Combine(root, "workflows", "start-focus.workflow.json"), workflow =>
        {
            workflow["steps"]![0]!["dependsOn"] = new JsonArray("savePurpose");
        }));
        RejectPackage("unbounded_workflow", root => MutateJson(Path.Combine(root, "workflows", "start-focus.workflow.json"), workflow =>
        {
            workflow["limits"]!["maxSteps"] = 33;
        }));
        RejectPackage("unsupported_workflow_presentation", root => MutateJson(Path.Combine(root, "workflows", "start-focus.workflow.json"), workflow =>
        {
            workflow["steps"]![0]!["use"] = "calendar.events.list@1";
            workflow["steps"]![0]!["with"] = new JsonObject
            {
                ["range"] = "today"
            };
        }));
        RejectPackage("unbound_surface_input", root => MutateJson(Path.Combine(root, "surfaces", "main.surface.json"), surface =>
        {
            surface["root"]!["children"]![2]!["value"] = "$input.missing";
        }));
        RejectPackage("surface_input_type_mismatch", root => MutateJson(Path.Combine(root, "workflows", "start-focus.workflow.json"), workflow =>
        {
            workflow["inputs"]!["purpose"] = "integer";
        }));
        RejectPackage("state_workflow_type_mismatch", root => MutateJson(Path.Combine(root, "workflows", "start-focus.workflow.json"), workflow =>
        {
            workflow["inputs"]!["selectedEventRef"] = "integer";
        }));
        RejectPackage("workflow_input_bound_only_on_unreachable_surface", root =>
        {
            MutateJson(Path.Combine(root, "manifest.json"), manifest =>
            {
                manifest["surfaces"]!.AsArray().Add(new JsonObject
                {
                    ["id"] = "secondary",
                    ["kind"] = "declarative",
                    ["source"] = "surfaces/secondary.surface.json"
                });
            });
            MutateJson(Path.Combine(root, "surfaces", "main.surface.json"), surface =>
            {
                var children = surface["root"]!["children"]!.AsArray();
                children[1]!.AsObject().Remove("titleTarget");
                children.RemoveAt(3);
            });
            var secondary = new JsonObject
            {
                ["$schema"] = "hoverpocket://schemas/pocket-surface/v1",
                ["surfaceVersion"] = 1,
                ["id"] = "secondary",
                ["hostBoundary"] = new JsonObject
                {
                    ["region"] = "provider_host",
                    ["mayRenderHeader"] = false,
                    ["mayRenderVoiceLane"] = false,
                    ["mayRenderApproval"] = false,
                    ["mayRenderReceipt"] = false
                },
                ["root"] = new JsonObject
                {
                    ["type"] = "stack",
                    ["axis"] = "vertical",
                    ["children"] = new JsonArray
                    {
                        new JsonObject
                        {
                            ["type"] = "textField",
                            ["label"] = "Purpose",
                            ["value"] = "$input.purpose",
                            ["maxLength"] = 80
                        }
                    }
                }
            };
            File.WriteAllText(
                Path.Combine(root, "surfaces", "secondary.surface.json"),
                secondary.ToJsonString(),
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        });
        RejectPackage("unsupported_surface_query_shape", root => MutateJson(Path.Combine(root, "surfaces", "main.surface.json"), surface =>
        {
            surface["root"]!["children"]![1]!["items"]!["query"] = "sticky.note.get@1";
        }));
        RejectPackage("unsupported_test_case", root => MutateJson(Path.Combine(root, "tests", "calendar-read.json"), test =>
        {
            test["case"] = "custom-generated-case";
        }));
        RejectPackage("deep_empty_directories", root =>
        {
            var current = root;
            for (var index = 0; index < 17; index++)
            {
                current = Path.Combine(current, "nested");
                Directory.CreateDirectory(current);
            }
        });
        RejectPackage("excess_empty_directories", root =>
        {
            for (var index = 0; index < 257; index++)
            {
                Directory.CreateDirectory(Path.Combine(root, $"empty-{index}"));
            }
        });

        VerifyStableKey();
        VerifyLifecycle();
        _failures.AddRange(new PocketAppGenerationVerifier().Run());

        if (_failures.Count > 0)
        {
            VerifyConsole.WriteLine("pocket_app_package_verify=failed");
            foreach (var failure in _failures)
            {
                VerifyConsole.WriteLine($"failure={failure}");
            }
            return 1;
        }

        VerifyConsole.WriteLine("pocket_app_package_verify=ok");
        VerifyConsole.WriteLine("pocket_app_package_valid_files=9");
        VerifyConsole.WriteLine("pocket_app_package_bundled=ok");
        VerifyConsole.WriteLine("pocket_app_package_negative_cases=17");
        VerifyConsole.WriteLine("pocket_app_lifecycle_verify=ok");
        VerifyConsole.WriteLine("pocket_app_generation_verify=ok");
        return 0;
    }

    private void VerifyStableKey()
    {
        const string valid = "today-focus:2026-08-15";
        try
        {
            Require(PocketStableKey.Validate(valid) == valid, "stable_key_valid");
        }
        catch (Exception ex)
        {
            _failures.Add($"stable_key_valid:{ex.GetType().Name}:{ex.Message}");
        }

        var invalid = new[]
        {
            "today-focus:bad\nkey",
            "today-focus:key\n",
            "today-focus:bad\u202ekey",
            "today-focus:bad\u0007key",
            "today-focus:" + new string('a', 90),
            "Today-focus:2026-08-15",
            "today-focus:a:b"
        };
        for (var index = 0; index < invalid.Length; index++)
        {
            try
            {
                _ = PocketStableKey.Validate(invalid[index]);
                _failures.Add($"stable_key_reject_{index}");
            }
            catch (CapabilityBrokerException)
            {
            }
        }

        try
        {
            var now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
            var principal = new CapabilityPrincipal("verify", "local.example.today-focus");
            var args = CapabilityJson.From(new
            {
                stableKey = valid,
                title = "Focus purpose",
                body = "Focus",
                color = "yellow"
            });
            var plan = new CapabilityExecutionPlan(
                "verify-stable-key",
                now,
                CapabilityOrigin.PocketSurface,
                principal,
                new CapabilityAppContext(
                    "local.example.today-focus",
                    "1.0.0",
                    "sha256:" + new string('0', 64)),
                [new CapabilityPlanStep(
                    "savePurpose",
                    CapabilityIds.StickyUpsert,
                    args,
                    "verify-stable-key-0001",
                    Array.Empty<string>())],
                new HashSet<string>(["sticky.write"], StringComparer.Ordinal));
            var digest = CapabilityCanonicalJson.PlanDigest(plan);
            var draft = new PocketAppWorkflowDraft(
                "local.example.today-focus",
                "startFocus",
                plan,
                new CapabilityBrokerPreparation(digest, null));
            Require(PocketAppHostController.ApprovalSummary(draft, english: true).Contains(valid, StringComparison.Ordinal), "stable_key_approval_exact");
            var changedArgs = CapabilityJson.From(new
            {
                stableKey = "today-focus:2026-08-16",
                title = "Focus purpose",
                body = "Focus",
                color = "yellow"
            });
            var changedPlan = plan with
            {
                Steps = [new CapabilityPlanStep(
                    "savePurpose",
                    CapabilityIds.StickyUpsert,
                    changedArgs,
                    "verify-stable-key-0001",
                    Array.Empty<string>())]
            };
            Require(CapabilityCanonicalJson.PlanDigest(changedPlan) != digest, "stable_key_plan_digest");
        }
        catch (Exception ex)
        {
            _failures.Add($"stable_key_binding:{ex.GetType().Name}:{ex.Message}");
        }
    }

    private void VerifyLifecycle()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        WithPackage(draftRoot =>
        {
            var root = Path.Combine(Path.GetTempPath(), $"hover-pocket-lifecycle-{Guid.NewGuid():N}");
            var dataRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-lifecycle-data-{Guid.NewGuid():N}");
            try
            {
                var manager = new PocketAppLifecycleManager(root, dataRoot);
                var proposal = manager.Stage(draftRoot, now);
                Require(proposal.PackageDigest == "sha256:e9c369e0b52620d95c14baa2e04070535a1f21020308090f0467eed8cf4f04df", "lifecycle_stage_digest");
                Require(proposal.PreviewDigest.StartsWith("sha256:", StringComparison.Ordinal) && proposal.Previews.Count == 1, "lifecycle_preview");
                Require(proposal.PermissionDiff.Added.SequenceEqual(
                    new[] { "calendar.events.read", "sticky.read", "sticky.write", "timer.read", "timer.write" },
                    StringComparer.Ordinal), "lifecycle_permission_diff");
                Require(proposal.ApprovalRequired && proposal.CapabilityGrantDiff.Added.Count == 5, "lifecycle_grant_diff");
                Require(
                    proposal.Tests.Count == 6
                    && proposal.Tests.Take(2).All(item => item.Status == "pass")
                    && proposal.Tests.Skip(2).All(item => item.Status == item.Expected),
                    "lifecycle_tests");
                try
                {
                    _ = manager.Install(proposal, null, now);
                    _failures.Add("lifecycle_permission_increase_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_APPROVAL_REQUIRED")
                {
                }
                var duplicateProposal = manager.Stage(draftRoot, now);
                Require(
                    duplicateProposal.BindingDigest == proposal.BindingDigest,
                    "lifecycle_duplicate_binding_fixture");
                File.WriteAllText(Path.Combine(draftRoot, "intent.md"), "draft changed after staging", new UTF8Encoding(false));
                var grant = manager.Approve(proposal.RequestId, proposal.BindingDigest, now);
                try
                {
                    _ = manager.Install(duplicateProposal, grant, now);
                    _failures.Add("lifecycle_cross_request_grant_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_APPROVAL_INVALID")
                {
                }
                var previewBytes = proposal.Previews[0].CanonicalRenderModel;
                previewBytes[0] ^= 0xff;
                var tamperedPreview = new PocketAppPreviewSurface(
                    proposal.Previews[0].Id,
                    proposal.Previews[0].RenderDigest,
                    previewBytes);
                try
                {
                    _ = manager.Install(proposal with { Previews = new[] { tamperedPreview } }, grant, now);
                    _failures.Add("lifecycle_tampered_preview_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_PACKAGE_CHANGED")
                {
                }
                var installed = manager.Install(proposal, grant, now);
                manager.Reject(duplicateProposal.RequestId, duplicateProposal.BindingDigest);
                Require(installed.ReadbackVerified && manager.ActivePackage(proposal.PackageId)?.ManifestDigest == proposal.PackageDigest, "lifecycle_install_readback");
                var appsRoot = Path.Combine(root, "Apps");
                File.WriteAllText(Path.Combine(appsRoot, ".DS_Store"), "Finder metadata", new UTF8Encoding(false));
                Directory.CreateDirectory(Path.Combine(appsRoot, "not-a-package"));
                var snapshotWithUnmanagedEntries = manager.ManagementSnapshot();
                Require(
                    snapshotWithUnmanagedEntries.Packages.Any(item =>
                        item.PackageId == proposal.PackageId && item.State == PocketAppLifecycleState.Enabled)
                    && snapshotWithUnmanagedEntries.Issues.Count == 0,
                    "lifecycle_unmanaged_entries_do_not_block_snapshot");
                File.WriteAllBytes(Path.Combine(draftRoot, "intent.md"), FixtureData("package/intent.md"));

                var installedIntent = Path.Combine(
                    root,
                    "Apps",
                    proposal.PackageId,
                    "Versions",
                    VersionStorageKey(proposal.Version),
                    proposal.PackageDigest["sha256:".Length..],
                    "package",
                    "intent.md");
                File.SetAttributes(installedIntent, File.GetAttributes(installedIntent) & ~FileAttributes.ReadOnly);
                var reharden = manager.Stage(draftRoot, now.AddMilliseconds(500));
                var rehardenGrant = manager.Approve(reharden.RequestId, reharden.BindingDigest, now.AddMilliseconds(500));
                _ = manager.Install(reharden, rehardenGrant, now.AddMilliseconds(500));
                Require(
                    File.GetAttributes(installedIntent).HasFlag(FileAttributes.ReadOnly),
                    "lifecycle_existing_snapshot_rehardened");

                MutateJson(Path.Combine(draftRoot, "manifest.json"), manifest => manifest["version"] = "1.0.1");
                var update = manager.Stage(draftRoot, now.AddSeconds(1));
                Require(update.PermissionDiff.Added.Count == 0 && update.Action == PocketAppLifecycleAction.Update && update.ApprovalRequired, "lifecycle_update_diff");
                try
                {
                    _ = manager.Install(update, null, now.AddSeconds(1));
                    _failures.Add("lifecycle_update_without_approval");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_APPROVAL_REQUIRED")
                {
                }
                var updateGrant = manager.Approve(update.RequestId, update.BindingDigest, now.AddSeconds(1));
                _ = manager.Install(update, updateGrant, now.AddSeconds(1));
                MutateJson(Path.Combine(draftRoot, "manifest.json"), manifest => manifest["version"] = "1.0.0");
                try
                {
                    _ = manager.Stage(draftRoot, now.AddSeconds(2));
                    _failures.Add("lifecycle_downgrade_update_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_DOWNGRADE_REQUIRES_ROLLBACK")
                {
                }
                var rollback = manager.PrepareRollback(proposal.PackageId, "1.0.0", now.AddSeconds(2));
                Require(rollback.ApprovalRequired, "lifecycle_rollback_approval");
                File.SetAttributes(installedIntent, File.GetAttributes(installedIntent) & ~FileAttributes.ReadOnly);
                var rollbackGrant = manager.Approve(rollback.RequestId, rollback.BindingDigest, now.AddSeconds(2));
                _ = manager.Rollback(rollback, rollbackGrant, now.AddSeconds(2));
                Require(manager.ActivePackage(proposal.PackageId)?.Manifest.Version == "1.0.0", "lifecycle_rollback");
                Require(
                    File.GetAttributes(installedIntent).HasFlag(FileAttributes.ReadOnly),
                    "lifecycle_rollback_snapshot_rehardened");
                MutateJson(Path.Combine(draftRoot, "manifest.json"), manifest =>
                {
                    manifest["version"] = "1.0.2";
                    var stickyRequest = manifest["requestedCapabilities"]!.AsArray()
                        .First(item => item?["id"]?.GetValue<string>() == "sticky.note.get")!;
                    stickyRequest.AsObject().Remove("scope");
                });
                var authorityUpdate = manager.Stage(draftRoot, now.AddSeconds(2));
                Require(
                    authorityUpdate.PermissionDiff.Added.Count == 0
                    && authorityUpdate.CapabilityGrantDiff.Added.Count != 0
                    && authorityUpdate.CapabilityGrantDiff.Removed.Count != 0
                    && authorityUpdate.ApprovalRequired,
                    "lifecycle_effective_grant_diff");
                manager.Reject(authorityUpdate.RequestId, authorityUpdate.BindingDigest);
                var disabled = manager.Disable(proposal.PackageId, now.AddSeconds(3));
                Require(disabled.State == PocketAppLifecycleState.Disabled && manager.ActivePackage(proposal.PackageId) is null, "lifecycle_disable");

                var userPackage = Path.Combine(dataRoot, proposal.PackageId);
                Directory.CreateDirectory(userPackage);
                var sentinel = Path.Combine(userPackage, "sentinel.txt");
                File.WriteAllText(sentinel, "preserve", Encoding.UTF8);
                _ = manager.Remove(proposal.PackageId, PocketAppDataDisposition.Preserve, now.AddSeconds(4));
                Require(File.Exists(sentinel), "lifecycle_remove_preserve");
                MutateJson(Path.Combine(draftRoot, "manifest.json"), manifest => manifest["version"] = "1.0.0");
                var reinstall = manager.Stage(draftRoot, now.AddSeconds(5));
                var reinstallGrant = manager.Approve(reinstall.RequestId, reinstall.BindingDigest, now.AddSeconds(5));
                _ = manager.Install(reinstall, reinstallGrant, now.AddSeconds(5));
                try
                {
                    _ = manager.Remove(proposal.PackageId, PocketAppDataDisposition.Delete, now.AddSeconds(6));
                    _failures.Add("lifecycle_remove_delete_without_approval");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_APPROVAL_REQUIRED")
                {
                }
                Require(File.Exists(sentinel), "lifecycle_remove_delete_preserved");
                _ = manager.Remove(proposal.PackageId, PocketAppDataDisposition.Preserve, now.AddSeconds(7));
            }
            finally
            {
                try { if (Directory.Exists(root)) { PocketAppVerifierFileSystem.MakeTreeMutable(root); Directory.Delete(root, true); } } catch { }
                try { if (Directory.Exists(dataRoot)) { Directory.Delete(dataRoot, true); } } catch { }
            }
        }, "lifecycle_positive");

        WithPackage(draftRoot =>
        {
            var root = Path.Combine(Path.GetTempPath(), $"hover-pocket-lifecycle-negative-{Guid.NewGuid():N}");
            var dataRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-lifecycle-negative-data-{Guid.NewGuid():N}");
            try
            {
                var manager = new PocketAppLifecycleManager(root, dataRoot);
                var expired = manager.Stage(draftRoot, now);
                try
                {
                    _ = manager.Approve(expired.RequestId, expired.BindingDigest, now.AddSeconds(301));
                    _failures.Add("lifecycle_stale_approval_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_APPROVAL_EXPIRED")
                {
                }
                Require(
                    !Directory.Exists(Directory.GetParent(expired.StagingDirectory)!.FullName),
                    "lifecycle_expired_approval_cleanup");

                var expiredInstall = manager.Stage(draftRoot, now.AddSeconds(302));
                var expiredInstallGrant = manager.Approve(
                    expiredInstall.RequestId,
                    expiredInstall.BindingDigest,
                    now.AddSeconds(302));
                try
                {
                    _ = manager.Install(expiredInstall, expiredInstallGrant, now.AddSeconds(603));
                    _failures.Add("lifecycle_expired_install_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_APPROVAL_EXPIRED")
                {
                }
                Require(
                    !Directory.Exists(Directory.GetParent(expiredInstall.StagingDirectory)!.FullName),
                    "lifecycle_expired_install_cleanup");

                var abandoned = manager.Stage(draftRoot, now.AddSeconds(604));
                var replacement = manager.Stage(draftRoot, now.AddSeconds(905));
                Require(
                    !Directory.Exists(Directory.GetParent(abandoned.StagingDirectory)!.FullName),
                    "lifecycle_stage_purges_expired");
                try
                {
                    manager.Reject(replacement.RequestId, $"sha256:{new string('0', 64)}");
                    _failures.Add("lifecycle_reject_wrong_binding_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_APPROVAL_INVALID")
                {
                }
                Require(
                    Directory.Exists(replacement.StagingDirectory),
                    "lifecycle_reject_wrong_binding_preserves_proposal");
                _ = new PocketAppLifecycleManager(root, dataRoot);
                Require(
                    Directory.Exists(replacement.StagingDirectory),
                    "lifecycle_second_manager_preserves_live_staging");
                manager.Reject(replacement.RequestId, replacement.BindingDigest);

                using var capacityPeer = new PocketAppLifecycleManager(root, dataRoot);
                var capacityProposals = new List<(PocketAppLifecycleManager Owner, PocketAppLifecycleProposal Proposal)>();
                for (var index = 0; index < 4; index++)
                {
                    var owner = index % 2 == 0 ? manager : capacityPeer;
                    capacityProposals.Add((owner, owner.Stage(draftRoot, now.AddSeconds(906 + index))));
                }
                try
                {
                    _ = manager.Stage(draftRoot, now.AddSeconds(910));
                    _failures.Add("lifecycle_pending_limit_not_enforced");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_PENDING_LIMIT_EXCEEDED")
                {
                }
                Require(
                    capacityProposals.All(item => Directory.Exists(item.Proposal.StagingDirectory)),
                    "lifecycle_pending_limit_preserves_existing");
                foreach (var item in capacityProposals)
                {
                    item.Owner.Reject(item.Proposal.RequestId, item.Proposal.BindingDigest);
                }

                var abandonedRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-lifecycle-abandoned-{Guid.NewGuid():N}");
                var abandonedDataRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-lifecycle-abandoned-data-{Guid.NewGuid():N}");
                try
                {
                    string abandonedParent;
                    using (var abandonedManager = new PocketAppLifecycleManager(abandonedRoot, abandonedDataRoot))
                    {
                        var abandonedProposal = abandonedManager.Stage(draftRoot, now);
                        abandonedParent = Directory.GetParent(abandonedProposal.StagingDirectory)!.FullName;
                    }
                    _ = new PocketAppLifecycleManager(abandonedRoot, abandonedDataRoot);
                    Require(!Directory.Exists(abandonedParent), "lifecycle_abandoned_manager_cleans_staging");
                }
                finally
                {
                    PocketAppVerifierFileSystem.MakeTreeMutable(abandonedRoot);
                    try { Directory.Delete(abandonedRoot, true); } catch { }
                    try { Directory.Delete(abandonedDataRoot, true); } catch { }
                }

                var changed = manager.Stage(draftRoot, now);
                var changedGrant = manager.Approve(changed.RequestId, changed.BindingDigest, now);
                File.WriteAllText(Path.Combine(changed.StagingDirectory, "intent.md"), "tampered staged bytes", new UTF8Encoding(false));
                try
                {
                    _ = manager.Install(changed, changedGrant, now);
                    _failures.Add("lifecycle_digest_change_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_PACKAGE_CHANGED")
                {
                }

                var clean = manager.Stage(draftRoot, now);
                var cleanGrant = manager.Approve(clean.RequestId, clean.BindingDigest, now);
                _ = manager.Install(clean, cleanGrant, now);

                var activeRecord = Path.Combine(root, "Apps", clean.PackageId, "active.json");
                MutateJson(activeRecord, record => record["Permissions"] = new JsonArray());
                MutateJson(Path.Combine(draftRoot, "manifest.json"), manifest => manifest["version"] = "1.0.1");
                var reconciled = manager.Stage(draftRoot, now.AddSeconds(1));
                Require(reconciled.PermissionDiff.Added.Count == 0, "lifecycle_active_record_permission_reconciled");
                manager.Reject(reconciled.RequestId, reconciled.BindingDigest);

                var failingManager = new PocketAppLifecycleManager(
                    root,
                    dataRoot,
                    failureInjection: point => point == "active_write");
                var writeFailure = failingManager.Stage(draftRoot, now.AddSeconds(1));
                var writeFailureGrant = failingManager.Approve(writeFailure.RequestId, writeFailure.BindingDigest, now.AddSeconds(1));
                try
                {
                    _ = failingManager.Install(writeFailure, writeFailureGrant, now.AddSeconds(1));
                    _failures.Add("lifecycle_write_failure_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_STORAGE_FAILED")
                {
                }
                Require(failingManager.ActivePackage(clean.PackageId)?.Manifest.Version == "1.0.0", "lifecycle_write_failure_invariant");
                var failingRemoveManager = new PocketAppLifecycleManager(
                    root,
                    dataRoot,
                    failureInjection: point => point == "remove_stage");
                try
                {
                    _ = failingRemoveManager.Remove(clean.PackageId, PocketAppDataDisposition.Preserve, now.AddSeconds(2));
                    _failures.Add("lifecycle_remove_failure_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_STORAGE_FAILED")
                {
                }
                Require(failingRemoveManager.ActivePackage(clean.PackageId)?.Manifest.Version == "1.0.0", "lifecycle_remove_failure_invariant");
                var recoveredIntent = Path.Combine(
                    root,
                    "Apps",
                    clean.PackageId,
                    "Versions",
                    VersionStorageKey(clean.Version),
                    clean.PackageDigest["sha256:".Length..],
                    "package",
                    "intent.md");
                Require(
                    File.GetAttributes(recoveredIntent).HasFlag(FileAttributes.ReadOnly),
                    "lifecycle_remove_failure_rehardened");
                var recoveryVersions = Path.Combine(root, "Apps", clean.PackageId, "Versions");
                var recoveryTombstone = Path.Combine(root, "Apps", clean.PackageId, ".removed-Versions-recovery");
                PocketAppVerifierFileSystem.MakeTreeMutable(recoveryVersions);
                Directory.Move(recoveryVersions, recoveryTombstone);
                var startupRecoveredManager = new PocketAppLifecycleManager(root, dataRoot);
                Require(
                    startupRecoveredManager.ActivePackage(clean.PackageId)?.Manifest.Version == "1.0.0",
                    "lifecycle_startup_remove_recovery_active");
                Require(
                    File.GetAttributes(recoveredIntent).HasFlag(FileAttributes.ReadOnly),
                    "lifecycle_startup_remove_recovery_rehardened");
                PocketAppVerifierFileSystem.MakeTreeMutable(recoveryVersions);
                _ = new PocketAppLifecycleManager(root, dataRoot);
                Require(
                    File.GetAttributes(recoveredIntent).HasFlag(FileAttributes.ReadOnly),
                    "lifecycle_startup_existing_versions_rehardened");
                MutateJson(Path.Combine(draftRoot, "manifest.json"), manifest => manifest["version"] = "1.0.0");
                MutateJson(Path.Combine(draftRoot, "data.schema.json"), schema =>
                {
                    schema["properties"]!["newState"] = new JsonObject { ["type"] = "string" };
                });
                try
                {
                    _ = manager.Stage(draftRoot, now.AddSeconds(1));
                    _failures.Add("lifecycle_migration_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_MIGRATION_REQUIRED")
                {
                }

                var corrupt = Path.Combine(
                    root,
                    "Apps",
                    clean.PackageId,
                    "Versions",
                    VersionStorageKey(clean.Version),
                    clean.PackageDigest["sha256:".Length..],
                    "package",
                    "intent.md");
                File.SetAttributes(corrupt, File.GetAttributes(corrupt) & ~FileAttributes.ReadOnly);
                File.WriteAllText(corrupt, "corrupt", new UTF8Encoding(false));
                try
                {
                    _ = manager.ActivePackage(clean.PackageId);
                    _failures.Add("lifecycle_corrupt_version_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_CORRUPT_VERSION")
                {
                }

                var interrupted = Path.Combine(root, "Apps", clean.PackageId, "Versions", "9.9.9", ".installing-fixture");
                Directory.CreateDirectory(interrupted);
                _ = new PocketAppLifecycleManager(root, dataRoot);
                Require(!Directory.Exists(interrupted), "lifecycle_interrupted_cleanup");
            }
            finally
            {
                try { if (Directory.Exists(root)) { PocketAppVerifierFileSystem.MakeTreeMutable(root); Directory.Delete(root, true); } } catch { }
                try { if (Directory.Exists(dataRoot)) { Directory.Delete(dataRoot, true); } } catch { }
            }
        }, "lifecycle_negative");

        WithPackage(draftRoot =>
        {
            var root = Path.Combine(Path.GetTempPath(), $"hover-pocket-lifecycle-state-binding-{Guid.NewGuid():N}");
            var dataRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-lifecycle-state-binding-data-{Guid.NewGuid():N}");
            var absentRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-lifecycle-absent-binding-{Guid.NewGuid():N}");
            var absentDataRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-lifecycle-absent-binding-data-{Guid.NewGuid():N}");
            try
            {
                var manager = new PocketAppLifecycleManager(root, dataRoot);
                var initial = manager.Stage(draftRoot, now);
                var initialGrant = manager.Approve(initial.RequestId, initial.BindingDigest, now);
                _ = manager.Install(initial, initialGrant, now);
                MutateJson(Path.Combine(draftRoot, "manifest.json"), manifest => manifest["version"] = "1.0.1");
                var enabledProposal = manager.Stage(draftRoot, now.AddSeconds(1));
                var enabledGrant = manager.Approve(enabledProposal.RequestId, enabledProposal.BindingDigest, now.AddSeconds(1));
                _ = manager.Disable(initial.PackageId, now.AddSeconds(2));
                try
                {
                    _ = manager.Install(enabledProposal, enabledGrant, now.AddSeconds(2));
                    _failures.Add("lifecycle_enabled_proposal_after_disable_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_ACTIVE_CHANGED")
                {
                }
                Require(manager.ActivePackage(initial.PackageId) is null, "lifecycle_disabled_state_preserved");
                var disabledUpdate = manager.Stage(draftRoot, now.AddSeconds(3));
                Require(
                    disabledUpdate.PermissionDiff.Added.Count == 5
                    && disabledUpdate.PermissionDiff.Removed.Count == 0
                    && disabledUpdate.CapabilityGrantDiff.Added.Count == 5
                    && disabledUpdate.CapabilityGrantDiff.Removed.Count == 0,
                    "lifecycle_disabled_update_restores_grants_only_with_approval");
                manager.Reject(disabledUpdate.RequestId, disabledUpdate.BindingDigest);

                MutateJson(Path.Combine(draftRoot, "manifest.json"), manifest => manifest["version"] = "1.0.0");
                var absentManager = new PocketAppLifecycleManager(absentRoot, absentDataRoot);
                var absentProposal = absentManager.Stage(draftRoot, now);
                var absentGrant = absentManager.Approve(absentProposal.RequestId, absentProposal.BindingDigest, now);
                _ = absentManager.Remove(absentProposal.PackageId, PocketAppDataDisposition.Preserve, now.AddSeconds(1));
                try
                {
                    _ = absentManager.Install(absentProposal, absentGrant, now.AddSeconds(1));
                    _failures.Add("lifecycle_absent_proposal_after_remove_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_ACTIVE_CHANGED")
                {
                }
                Require(absentManager.ActivePackage(absentProposal.PackageId) is null, "lifecycle_removed_state_preserved");
            }
            finally
            {
                foreach (var directory in new[] { root, absentRoot })
                {
                    try
                    {
                        if (Directory.Exists(directory))
                        {
                            PocketAppVerifierFileSystem.MakeTreeMutable(directory);
                            Directory.Delete(directory, true);
                        }
                    }
                    catch { }
                }
                try { if (Directory.Exists(dataRoot)) { Directory.Delete(dataRoot, true); } } catch { }
                try { if (Directory.Exists(absentDataRoot)) { Directory.Delete(absentDataRoot, true); } } catch { }
            }
        }, "lifecycle_state_binding");

        WithPackage(draftRoot =>
        {
            var root = Path.Combine(Path.GetTempPath(), $"hover-pocket-lifecycle-concurrency-{Guid.NewGuid():N}");
            var dataRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-lifecycle-concurrency-data-{Guid.NewGuid():N}");
            using var activationReached = new ManualResetEventSlim(false);
            using var allowActivation = new ManualResetEventSlim(false);
            using var disableStarted = new ManualResetEventSlim(false);
            using var disableDone = new ManualResetEventSlim(false);
            var errors = new ConcurrentQueue<string>();
            var pauseActivation = 0;
            try
            {
                var manager = new PocketAppLifecycleManager(
                    root,
                    dataRoot,
                    failureInjection: point =>
                    {
                        if (point != "before_active_commit" || Interlocked.Exchange(ref pauseActivation, 0) != 1)
                        {
                            return false;
                        }
                        activationReached.Set();
                        return !allowActivation.Wait(TimeSpan.FromSeconds(5));
                    });
                var initial = manager.Stage(draftRoot, now);
                var initialGrant = manager.Approve(initial.RequestId, initial.BindingDigest, now);
                _ = manager.Install(initial, initialGrant, now);

                MutateJson(Path.Combine(draftRoot, "manifest.json"), manifest => manifest["version"] = "1.0.1");
                var update = manager.Stage(draftRoot, now.AddSeconds(1));
                var updateGrant = manager.Approve(update.RequestId, update.BindingDigest, now.AddSeconds(1));
                var competingManager = new PocketAppLifecycleManager(root, dataRoot);
                Interlocked.Exchange(ref pauseActivation, 1);

                var activationTask = Task.Run(() =>
                {
                    try
                    {
                        _ = manager.Install(update, updateGrant, now.AddSeconds(2));
                    }
                    catch (Exception ex)
                    {
                        errors.Enqueue($"activate:{ex.GetType().Name}:{ex.Message}");
                    }
                });
                Require(activationReached.Wait(TimeSpan.FromSeconds(5)), "lifecycle_concurrent_activation_reached");

                var disableTask = Task.Run(() =>
                {
                    disableStarted.Set();
                    try
                    {
                        _ = competingManager.Disable(initial.PackageId, now.AddSeconds(3));
                    }
                    catch (Exception ex)
                    {
                        errors.Enqueue($"disable:{ex.GetType().Name}:{ex.Message}");
                    }
                    finally
                    {
                        disableDone.Set();
                    }
                });
                Require(disableStarted.Wait(TimeSpan.FromSeconds(5)), "lifecycle_concurrent_disable_started");
                var disableWasSerialized = !disableDone.Wait(TimeSpan.FromMilliseconds(100));
                allowActivation.Set();
                Require(Task.WaitAll([activationTask, disableTask], TimeSpan.FromSeconds(5)), "lifecycle_concurrent_tasks_completed");
                Require(disableWasSerialized, "lifecycle_concurrent_disable_serialized");
                Require(errors.IsEmpty, $"lifecycle_concurrent_errors:{string.Join("|", errors)}");
                Require(manager.ActivePackage(initial.PackageId) is null, "lifecycle_concurrent_disable_wins");
            }
            finally
            {
                allowActivation.Set();
                try { if (Directory.Exists(root)) { PocketAppVerifierFileSystem.MakeTreeMutable(root); Directory.Delete(root, true); } } catch { }
                try { if (Directory.Exists(dataRoot)) { Directory.Delete(dataRoot, true); } } catch { }
            }
        }, "lifecycle_concurrency");

        WithPackage(draftRoot =>
        {
            var root = Path.Combine(Path.GetTempPath(), $"hover-pocket-lifecycle-large-version-{Guid.NewGuid():N}");
            var dataRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-lifecycle-large-version-data-{Guid.NewGuid():N}");
            try
            {
                var manager = new PocketAppLifecycleManager(root, dataRoot);
                var largeVersion = new string('9', 59) + ".0.0";
                MutateJson(Path.Combine(draftRoot, "manifest.json"), manifest => manifest["version"] = largeVersion);
                var install = manager.Stage(draftRoot, now);
                var grant = manager.Approve(install.RequestId, install.BindingDigest, now);
                _ = manager.Install(install, grant, now);
                MutateJson(Path.Combine(draftRoot, "manifest.json"), manifest => manifest["version"] = "1.0.0");
                try
                {
                    _ = manager.Stage(draftRoot, now.AddSeconds(1));
                    _failures.Add("lifecycle_large_version_downgrade_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_DOWNGRADE_REQUIRES_ROLLBACK")
                {
                }
            }
            finally
            {
                try { if (Directory.Exists(root)) { PocketAppVerifierFileSystem.MakeTreeMutable(root); Directory.Delete(root, true); } } catch { }
                try { if (Directory.Exists(dataRoot)) { Directory.Delete(dataRoot, true); } } catch { }
            }
        }, "lifecycle_large_version");

        WithPackage(draftRoot =>
        {
            var root = Path.Combine(Path.GetTempPath(), $"hover-pocket-lifecycle-case-version-{Guid.NewGuid():N}");
            var dataRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-lifecycle-case-version-data-{Guid.NewGuid():N}");
            try
            {
                using var manager = new PocketAppLifecycleManager(root, dataRoot);
                MutateJson(Path.Combine(draftRoot, "manifest.json"), manifest => manifest["version"] = "1.0.0-ALPHA");
                var initial = manager.Stage(draftRoot, now);
                var initialGrant = manager.Approve(initial.RequestId, initial.BindingDigest, now);
                _ = manager.Install(initial, initialGrant, now);
                MutateJson(Path.Combine(draftRoot, "manifest.json"), manifest => manifest["version"] = "1.0.0-alpha");
                var update = manager.Stage(draftRoot, now.AddSeconds(1));
                var updateGrant = manager.Approve(update.RequestId, update.BindingDigest, now.AddSeconds(1));
                _ = manager.Install(update, updateGrant, now.AddSeconds(1));
                Require(
                    manager.ActivePackage(initial.PackageId)?.Manifest.Version == "1.0.0-alpha",
                    "lifecycle_case_distinct_version_update");
                var rollback = manager.PrepareRollback(initial.PackageId, "1.0.0-ALPHA", now.AddSeconds(2));
                var rollbackGrant = manager.Approve(rollback.RequestId, rollback.BindingDigest, now.AddSeconds(2));
                _ = manager.Rollback(rollback, rollbackGrant, now.AddSeconds(2));
                Require(
                    manager.ActivePackage(initial.PackageId)?.Manifest.Version == "1.0.0-ALPHA",
                    "lifecycle_case_distinct_version_rollback");
                Require(
                    Directory.EnumerateDirectories(Path.Combine(root, "Apps", initial.PackageId, "Versions"))
                        .Select(Path.GetFileName)
                        .Distinct(StringComparer.OrdinalIgnoreCase)
                        .Count() == 2,
                    "lifecycle_case_distinct_version_storage");
            }
            finally
            {
                try { if (Directory.Exists(root)) { PocketAppVerifierFileSystem.MakeTreeMutable(root); Directory.Delete(root, true); } } catch { }
                try { if (Directory.Exists(dataRoot)) { Directory.Delete(dataRoot, true); } } catch { }
            }
        }, "lifecycle_case_distinct_version");

        WithPackage(draftRoot =>
        {
            var root = Path.Combine(Path.GetTempPath(), $"hover-pocket-lifecycle-test-gate-{Guid.NewGuid():N}");
            var dataRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-lifecycle-test-gate-data-{Guid.NewGuid():N}");
            try
            {
                var manager = new PocketAppLifecycleManager(root, dataRoot);
                MutateJson(Path.Combine(draftRoot, "tests", "calendar-read.json"), test => test["expected"] = "reject");
                try
                {
                    _ = manager.Stage(draftRoot, now);
                    _failures.Add("lifecycle_declared_test_not_executed");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_STAGING_TEST_FAILED")
                {
                }
            }
            finally
            {
                try { if (Directory.Exists(root)) { PocketAppVerifierFileSystem.MakeTreeMutable(root); Directory.Delete(root, true); } } catch { }
                try { if (Directory.Exists(dataRoot)) { Directory.Delete(dataRoot, true); } } catch { }
            }
        }, "lifecycle_test_gate");

        WithPackage(draftRoot =>
        {
            var root = Path.Combine(Path.GetTempPath(), $"hover-pocket-lifecycle-host-version-{Guid.NewGuid():N}");
            var dataRoot = Path.Combine(Path.GetTempPath(), $"hover-pocket-lifecycle-host-version-data-{Guid.NewGuid():N}");
            try
            {
                MutateJson(Path.Combine(draftRoot, "manifest.json"), manifest => manifest["minHostVersion"] = "2.0.0");
                var incompatibleHost = new PocketAppLifecycleManager(root, dataRoot);
                try
                {
                    _ = incompatibleHost.Stage(draftRoot, now);
                    _failures.Add("lifecycle_incompatible_stage_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_HOST_VERSION_UNSUPPORTED")
                {
                }
                var hostTwo = new PocketAppLifecycleManager(root, dataRoot, hostVersion: "2.0.0");
                var initial = hostTwo.Stage(draftRoot, now);
                var initialGrant = hostTwo.Approve(initial.RequestId, initial.BindingDigest, now);
                _ = hostTwo.Install(initial, initialGrant, now);

                var hostOne = new PocketAppLifecycleManager(root, dataRoot);
                try
                {
                    _ = hostOne.ActivePackage(initial.PackageId);
                    _failures.Add("lifecycle_incompatible_active_package_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_HOST_VERSION_UNSUPPORTED")
                {
                }

                MutateJson(Path.Combine(draftRoot, "manifest.json"), manifest =>
                {
                    manifest["version"] = "2.0.0";
                    manifest["minHostVersion"] = "1.0.0";
                });
                var update = hostTwo.Stage(draftRoot, now.AddSeconds(1));
                var updateGrant = hostTwo.Approve(update.RequestId, update.BindingDigest, now.AddSeconds(1));
                _ = hostTwo.Install(update, updateGrant, now.AddSeconds(1));
                try
                {
                    _ = hostOne.PrepareRollback(initial.PackageId, "1.0.0", now.AddSeconds(2));
                    _failures.Add("lifecycle_incompatible_rollback_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_HOST_VERSION_UNSUPPORTED")
                {
                }
            }
            finally
            {
                try { if (Directory.Exists(root)) { PocketAppVerifierFileSystem.MakeTreeMutable(root); Directory.Delete(root, true); } } catch { }
                try { if (Directory.Exists(dataRoot)) { Directory.Delete(dataRoot, true); } } catch { }
            }
        }, "lifecycle_host_version");
    }

    private void RejectPackage(string label, Action<string> mutation)
    {
        WithPackage(root =>
        {
            mutation(root);
            try
            {
                _ = new PocketAppPackageRuntime().Load(root);
                _failures.Add($"accepted:{label}");
            }
            catch (PocketAppPackageRuntimeException)
            {
            }
            catch (PocketSurfaceRuntimeException)
            {
            }
        }, label);
    }

    private void WithPackage(Action<string> body, string label)
    {
        var root = Path.Combine(Path.GetTempPath(), $"hover-pocket-package-{Guid.NewGuid():N}");
        VerifyConsole.WriteLine($"POCKET_PACKAGE_CASE_BEGIN {label}");
        try
        {
            AssemblePackage(root);
            body(root);
            VerifyConsole.WriteLine($"POCKET_PACKAGE_CASE_END {label}");
        }
        catch (Exception ex)
        {
            _failures.Add($"{label}:fixture:{ex.GetType().Name}:{ex.Message}");
            VerifyConsole.WriteLine($"POCKET_PACKAGE_CASE_FAIL {label} {ex.GetType().Name}:{ex.Message}");
        }
        finally
        {
            try
            {
                if (Directory.Exists(root))
                {
                    Directory.Delete(root, recursive: true);
                }
            }
            catch
            {
            }
        }
    }

    private static void AssemblePackage(string root)
    {
        Directory.CreateDirectory(Path.Combine(root, "surfaces"));
        Directory.CreateDirectory(Path.Combine(root, "workflows"));
        Directory.CreateDirectory(Path.Combine(root, "tests"));

        var files = new (string Destination, string Fixture)[]
        {
            ("manifest.json", "valid/pocket-app.today-focus.json"),
            ("intent.md", "package/intent.md"),
            ("data.schema.json", "package/data.schema.json"),
            ("surfaces/main.surface.json", "valid/pocket-surface.today-focus.json"),
            ("workflows/start-focus.workflow.json", "valid/pocket-workflow.today-focus.json"),
            ("tests/calendar-read.json", "package/test.calendar-read.json"),
            ("tests/start-focus-approved.json", "package/test.start-focus-approved.json"),
            ("tests/start-focus-idempotent-replay.json", "package/test.start-focus-idempotent-replay.json"),
            ("tests/start-focus-rejected.json", "package/test.start-focus-rejected.json")
        };
        foreach (var file in files)
        {
            File.WriteAllBytes(
                Path.Combine(root, file.Destination.Replace('/', Path.DirectorySeparatorChar)),
                FixtureData(file.Fixture));
        }
    }

    private static void MutateJson(string path, Action<JsonNode> mutation)
    {
        var root = JsonNode.Parse(File.ReadAllBytes(path))
            ?? throw new InvalidOperationException("fixture_parse");
        mutation(root);
        File.WriteAllBytes(path, Encoding.UTF8.GetBytes(root.ToJsonString()));
    }

    private static byte[] FixtureData(string relativePath)
    {
        var current = new DirectoryInfo(Environment.CurrentDirectory);
        while (current is not null)
        {
            var candidate = Path.Combine(current.FullName, "contracts", "pocket", "v1", "fixtures", relativePath.Replace('/', Path.DirectorySeparatorChar));
            if (File.Exists(candidate))
            {
                return File.ReadAllBytes(candidate);
            }
            current = current.Parent;
        }
        throw new FileNotFoundException(relativePath);
    }

    private static string VersionStorageKey(string version) =>
        "v-" + Convert.ToHexString(Encoding.UTF8.GetBytes(version)).ToLowerInvariant();

    private void Require(bool condition, string label)
    {
        if (!condition)
        {
            _failures.Add(label);
        }
    }
}


internal static class PocketAppVerifierFileSystem
{
    public static void MakeTreeMutable(string root)
    {
        if (!Directory.Exists(root)) { return; }
        foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
        {
            File.SetAttributes(file, File.GetAttributes(file) & ~FileAttributes.ReadOnly);
        }
    }
}
