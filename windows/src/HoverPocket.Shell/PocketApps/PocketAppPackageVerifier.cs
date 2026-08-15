using System.Text;
using System.Text.Json.Nodes;
using HoverPocket.Shell.Capabilities;

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
            Require(
                package.TestCases.Count == 4
                && package.TestCases["calendar-read"] == "pass"
                && package.TestCases["start-focus-approved"] == "pass"
                && package.TestCases["start-focus-idempotent-replay"] == "pass"
                && package.TestCases["start-focus-rejected"] == "reject",
                "package_tests");
            Console.WriteLine($"pocket_app_manifest_digest={package.ManifestDigest}");
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
        RejectPackage("unbound_surface_input", root => MutateJson(Path.Combine(root, "surfaces", "main.surface.json"), surface =>
        {
            surface["root"]!["children"]![2]!["value"] = "$input.missing";
        }));

        VerifyStableKey();
        VerifyLifecycle();

        if (_failures.Count > 0)
        {
            Console.Error.WriteLine("pocket_app_package_verify=failed");
            foreach (var failure in _failures)
            {
                Console.Error.WriteLine($"failure={failure}");
            }
            return 1;
        }

        Console.WriteLine("pocket_app_package_verify=ok");
        Console.WriteLine("pocket_app_package_valid_files=9");
        Console.WriteLine("pocket_app_package_bundled=ok");
        Console.WriteLine("pocket_app_package_negative_cases=9");
        Console.WriteLine("pocket_app_lifecycle_verify=ok");
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
                    && proposal.Tests.Skip(2).All(item => item.Status == "validated_declaration"),
                    "lifecycle_tests");
                try
                {
                    _ = manager.Install(proposal, null, now);
                    _failures.Add("lifecycle_permission_increase_accepted");
                }
                catch (PocketAppLifecycleException ex) when (ex.Code == "LIFECYCLE_APPROVAL_REQUIRED")
                {
                }
                File.WriteAllText(Path.Combine(draftRoot, "intent.md"), "draft changed after staging", new UTF8Encoding(false));
                var grant = manager.Approve(proposal.RequestId, proposal.BindingDigest, now);
                var installed = manager.Install(proposal, grant, now);
                Require(installed.ReadbackVerified && manager.ActivePackage(proposal.PackageId)?.ManifestDigest == proposal.PackageDigest, "lifecycle_install_readback");
                File.WriteAllBytes(Path.Combine(draftRoot, "intent.md"), FixtureData("package/intent.md"));

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
                var rollbackGrant = manager.Approve(rollback.RequestId, rollback.BindingDigest, now.AddSeconds(2));
                _ = manager.Rollback(rollback, rollbackGrant, now.AddSeconds(2));
                Require(manager.ActivePackage(proposal.PackageId)?.Manifest.Version == "1.0.0", "lifecycle_rollback");
                MutateJson(Path.Combine(draftRoot, "manifest.json"), manifest =>
                {
                    manifest["version"] = "1.0.2";
                    var calendarRequest = manifest["requestedCapabilities"]!.AsArray()
                        .First(item => item?["id"]?.GetValue<string>() == "calendar.events.list")!;
                    calendarRequest.AsObject().Remove("scope");
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
                    clean.Version,
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
        try
        {
            AssemblePackage(root);
            body(root);
        }
        catch (Exception ex)
        {
            _failures.Add($"{label}:fixture:{ex.GetType().Name}:{ex.Message}");
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
