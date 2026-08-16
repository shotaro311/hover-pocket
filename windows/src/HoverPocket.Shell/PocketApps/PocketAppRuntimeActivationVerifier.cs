namespace HoverPocket.Shell.PocketApps;

internal static class PocketAppRuntimeActivationVerifier
{
    public static int Verify()
    {
        var failures = Run();
        Console.WriteLine($"pocket_app_runtime_activation_verify={(failures.Count == 0 ? "ok" : "failed")}");
        if (failures.Count != 0)
        {
            Console.WriteLine($"pocket_app_runtime_activation_failures={string.Join(',', failures)}");
        }
        return failures.Count == 0 ? 0 : 1;
    }

    public static IReadOnlyList<string> Run()
    {
        var failures = new List<string>();
        const string appA = "local.generated.activation-a";
        const string appB = "local.generated.activation-b";
        const string appC = "local.generated.activation-c";
        var digest1 = "sha256:" + new string('1', 64);
        var digest2 = "sha256:" + new string('2', 64);
        var digest3 = "sha256:" + new string('3', 64);
        string[] permissions = ["sticky.read"];

        var managed = new Dictionary<string, PocketAppManagedPackage>(StringComparer.Ordinal);
        var candidates = new Dictionary<string, PocketAppRuntimeActivationRegistry.Candidate>(StringComparer.Ordinal);

        PocketAppRuntimeActivationRegistry.Candidate Candidate(
            string appId,
            string version,
            string digest) =>
            new(
                new PocketAppRuntimeReadback(appId, version, digest, permissions),
                new object(),
                new object(),
                new HashSet<string>(["main"], StringComparer.Ordinal),
                new PocketAppActivationLease());

        PocketAppLifecycleReceipt Receipt(
            string action,
            string appId,
            string? version,
            string? digest,
            PocketAppLifecycleState state) =>
            new(
                action,
                appId,
                version,
                digest,
                state == PocketAppLifecycleState.Enabled ? permissions : Array.Empty<string>(),
                state,
                true,
                state == PocketAppLifecycleState.Removed ? PocketAppDataDisposition.Preserve : null);

        PocketAppManagedPackage Managed(
            string appId,
            string version,
            string digest,
            PocketAppLifecycleState state) =>
            new(appId, state, version, digest, ["1.0.0", "1.1.0"]);

        using var registry = new PocketAppRuntimeActivationRegistry(
            () => managed.Values.ToArray(),
            appId => candidates.GetValueOrDefault(appId));
        var cancellationLease = new PocketAppActivationLease();
        cancellationLease.Invalidate();
        Require(
            !cancellationLease.IsActive && cancellationLease.CancellationToken.IsCancellationRequested,
            "activation_inflight_cancellation",
            failures);
        Require(
            PocketSurfaceRegistry.GeneratedProviderId(appA).StartsWith("generated-pocket-app:", StringComparison.Ordinal)
            && PocketSurfaceRegistry.GeneratedSurfaceRouteId(appA, "main")
                .StartsWith($"generated-pocket-app:{appA}/", StringComparison.Ordinal),
            "activation_identity_namespace",
            failures);

        try
        {
            candidates[appA] = Candidate(appA, "1.0.0", digest1);
            candidates[appB] = Candidate(appB, "1.0.0", digest1);
            managed[appA] = Managed(appA, "1.0.0", digest1, PocketAppLifecycleState.Enabled);
            managed[appB] = Managed(appB, "1.0.0", digest1, PocketAppLifecycleState.Enabled);
            _ = registry.Synchronize(Receipt("install", appA, "1.0.0", digest1, PocketAppLifecycleState.Enabled));
            _ = registry.Synchronize(Receipt("install", appB, "1.0.0", digest1, PocketAppLifecycleState.Enabled));
            Require(
                registry.ExecutionRegistry.ActiveAppIds.SequenceEqual([appA, appB], StringComparer.Ordinal)
                && registry.SurfaceRegistry.ActiveAppIds.SequenceEqual([appA, appB], StringComparer.Ordinal),
                "activation_multiple_apps",
                failures);

            candidates[appA] = Candidate(appA, "1.1.0", digest2);
            managed[appA] = Managed(appA, "1.1.0", digest2, PocketAppLifecycleState.Enabled);
            _ = registry.Synchronize(Receipt("update", appA, "1.1.0", digest2, PocketAppLifecycleState.Enabled));
            Require(
                registry.ExecutionRegistry.Readback(appA)?.PackageDigest == digest2
                && registry.ExecutionRegistry.Readback(appB)?.PackageDigest == digest1,
                "activation_update_isolated",
                failures);

            managed[appA] = Managed(appA, "1.1.0", digest2, PocketAppLifecycleState.Disabled);
            candidates.Remove(appA);
            _ = registry.Synchronize(Receipt("disable", appA, "1.1.0", digest2, PocketAppLifecycleState.Disabled));
            Require(
                registry.ExecutionRegistry.Readback(appA) is null
                && registry.SurfaceRegistry.Readback(appA) is null
                && registry.ExecutionRegistry.Readback(appB) is not null,
                "activation_disable",
                failures);

            candidates[appA] = Candidate(appA, "1.1.0", digest2);
            managed[appA] = Managed(appA, "1.1.0", digest2, PocketAppLifecycleState.Enabled);
            _ = registry.Synchronize(Receipt("enable", appA, "1.1.0", digest2, PocketAppLifecycleState.Enabled));
            Require(
                registry.ExecutionRegistry.Readback(appA)?.Version == "1.1.0",
                "activation_enable",
                failures);

            using (var restarted = new PocketAppRuntimeActivationRegistry(
                () => managed.Values.ToArray(),
                appId => candidates.GetValueOrDefault(appId)))
            {
                var restartFailures = restarted.RestoreEnabledApps();
                Require(
                    restartFailures.Count == 0
                    && restarted.ExecutionRegistry.ActiveAppIds.SequenceEqual([appA, appB], StringComparer.Ordinal)
                    && restarted.SurfaceRegistry.ActiveAppIds.SequenceEqual([appA, appB], StringComparer.Ordinal),
                    "activation_restart_restore",
                    failures);
            }

            candidates[appA] = Candidate(appA, "1.0.0", digest3);
            managed[appA] = Managed(appA, "1.0.0", digest3, PocketAppLifecycleState.Enabled);
            _ = registry.Synchronize(Receipt("rollback", appA, "1.0.0", digest3, PocketAppLifecycleState.Enabled));
            Require(
                registry.ExecutionRegistry.Readback(appA)?.PackageDigest == digest3
                && registry.ExecutionRegistry.Readback(appB)?.PackageDigest == digest1,
                "activation_rollback",
                failures);

            managed.Remove(appA);
            candidates.Remove(appA);
            _ = registry.Synchronize(Receipt("remove", appA, null, null, PocketAppLifecycleState.Removed));
            Require(
                registry.ExecutionRegistry.Readback(appA) is null
                && registry.SurfaceRegistry.Readback(appA) is null
                && registry.ExecutionRegistry.Readback(appB) is not null,
                "activation_remove",
                failures);

            candidates[appC] = Candidate(appC, "1.0.0", digest1);
            managed[appC] = Managed(appC, "1.0.0", digest1, PocketAppLifecycleState.Enabled);
            try
            {
                _ = registry.Synchronize(Receipt("install", appC, "1.0.0", digest2, PocketAppLifecycleState.Enabled));
                failures.Add("activation_mismatch_accepted");
            }
            catch (PocketAppRuntimeActivationException ex) when (ex.Code == "RUNTIME_ACTIVATION_READBACK_MISMATCH")
            {
            }
            Require(
                registry.ExecutionRegistry.Readback(appC) is null
                && registry.ExecutionRegistry.Readback(appB) is not null,
                "activation_mismatch_fail_closed",
                failures);

            var injectFailure = false;
            using var failing = new PocketAppRuntimeActivationRegistry(
                () => managed.Values.ToArray(),
                appId => candidates.GetValueOrDefault(appId),
                failureInjection: point => point == "before_runtime_registry_commit" && injectFailure);
            _ = failing.Synchronize(Receipt("install", appB, "1.0.0", digest1, PocketAppLifecycleState.Enabled));
            injectFailure = true;
            try
            {
                _ = failing.Synchronize(Receipt("install", appC, "1.0.0", digest1, PocketAppLifecycleState.Enabled));
                failures.Add("activation_failure_injection_accepted");
            }
            catch (PocketAppRuntimeActivationException ex) when (ex.Code == "RUNTIME_ACTIVATION_UNAVAILABLE")
            {
            }
            Require(
                failing.ExecutionRegistry.Readback(appC) is null
                    && failing.SurfaceRegistry.Readback(appC) is null
                    && failing.ExecutionRegistry.Readback(appB) is not null,
                "activation_failure_injection_fail_closed",
                failures);
            failing.Shutdown();
            Require(
                failing.ExecutionRegistry.ActiveAppIds.Count == 0
                    && failing.SurfaceRegistry.ActiveAppIds.Count == 0,
                "activation_shutdown_revokes_all_apps",
                failures);

            managed[appC] = Managed(appC, "1.0.0", digest1, PocketAppLifecycleState.Enabled);
            candidates.Remove(appC);
            var restoreFailurePersisted = false;
            using var restoreFailing = new PocketAppRuntimeActivationRegistry(
                () => managed.Values.ToArray(),
                appId => candidates.GetValueOrDefault(appId),
                restoreFailurePersistence: package =>
                {
                    if (!string.Equals(package.PackageId, appC, StringComparison.Ordinal)
                        || package.Version is null
                        || package.PackageDigest is null)
                    {
                        return false;
                    }
                    managed[appC] = Managed(
                        appC,
                        package.Version,
                        package.PackageDigest,
                        PocketAppLifecycleState.Disabled);
                    restoreFailurePersisted = true;
                    return true;
                });
            var restoreFailureIds = restoreFailing.RestoreEnabledApps();
            Require(
                restoreFailureIds.Contains(appC, StringComparer.Ordinal)
                    && restoreFailurePersisted
                    && managed[appC].State == PocketAppLifecycleState.Disabled
                    && restoreFailing.ExecutionRegistry.Readback(appC) is null
                    && restoreFailing.SurfaceRegistry.Readback(appC) is null,
                "activation_restore_failure_persists_disabled",
                failures);

            using var activationEntered = new ManualResetEventSlim(false);
            using var allowActivationCommit = new ManualResetEventSlim(false);
            var blockActivation = false;
            using var racing = new PocketAppRuntimeActivationRegistry(
                () => managed.Values.ToArray(),
                appId => candidates.GetValueOrDefault(appId),
                failureInjection: point =>
                {
                    if (point == "before_runtime_registry_commit" && blockActivation)
                    {
                        activationEntered.Set();
                        allowActivationCommit.Wait(TimeSpan.FromSeconds(5));
                    }
                    return false;
                });
            candidates[appB] = Candidate(appB, "1.0.0", digest1);
            managed[appB] = Managed(appB, "1.0.0", digest1, PocketAppLifecycleState.Enabled);
            blockActivation = true;
            var activationTask = Task.Run(() => racing.Synchronize(
                Receipt("enable", appB, "1.0.0", digest1, PocketAppLifecycleState.Enabled)));
            Require(
                activationEntered.Wait(TimeSpan.FromSeconds(5)),
                "activation_shutdown_race_entered",
                failures);
            using var disableStarted = new ManualResetEventSlim(false);
            var disableTask = Task.Run(() =>
            {
                disableStarted.Set();
                racing.SetEnabled(false);
            });
            Require(
                disableStarted.Wait(TimeSpan.FromSeconds(5)),
                "activation_shutdown_race_disable_started",
                failures);
            allowActivationCommit.Set();
            Require(
                Task.WaitAll([activationTask, disableTask], TimeSpan.FromSeconds(5)),
                "activation_shutdown_race_completed",
                failures);
            Require(
                racing.ExecutionRegistry.ActiveAppIds.Count == 0
                    && racing.SurfaceRegistry.ActiveAppIds.Count == 0,
                "activation_shutdown_race_no_survivor",
                failures);
            racing.SetEnabled(true);
            _ = racing.Synchronize(
                Receipt("enable", appB, "1.0.0", digest1, PocketAppLifecycleState.Enabled));
            Require(
                racing.ExecutionRegistry.Readback(appB) is not null
                    && racing.SurfaceRegistry.Readback(appB) is not null,
                "activation_reenable_accepts_new_transition",
                failures);
        }
        catch
        {
            failures.Add("activation_verifier_unexpected_error");
        }

        return failures;
    }

    private static void Require(bool condition, string name, ICollection<string> failures)
    {
        if (!condition) { failures.Add(name); }
    }
}
