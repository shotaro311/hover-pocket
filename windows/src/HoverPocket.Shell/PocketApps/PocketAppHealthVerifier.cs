namespace HoverPocket.Shell.PocketApps;

internal sealed class PocketAppHealthVerifier
{
    private const int WindowsPrivilegeNotHeldHResult = unchecked((int)0x80070522);
    private readonly List<string> _failures = [];

    internal IReadOnlyList<string> Run()
    {
        var root = Path.Combine(Path.GetTempPath(), $"hover-pocket-health-{Guid.NewGuid():N}");
        try
        {
            var store = new PocketAppHealthStore(root);
            const string appId = "local.generated.health";
            var enabled = Package(appId, PocketAppLifecycleState.Enabled);
            var disabled = Package(appId, PocketAppLifecycleState.Disabled);
            var start = new DateTimeOffset(2026, 8, 24, 0, 0, 0, TimeSpan.Zero);

            store.RecordActivationSuccess(appId, start);
            var snapshot = store.Snapshots([enabled], [], start).FirstOrDefault();
            Require(snapshot?.Status == PocketAppHealthStatus.Healthy, "health_initial_healthy");

            var unusedAt = start + PocketAppHealthStore.UnusedInterval + TimeSpan.FromSeconds(1);
            snapshot = store.Snapshots([enabled], [], unusedAt).FirstOrDefault();
            Require(
                snapshot is { Status: PocketAppHealthStatus.Unused, DisableSuggested: true },
                "health_unused_suggestion");

            store.RecordUse(appId, unusedAt);
            snapshot = store.Snapshots([enabled], [], unusedAt).FirstOrDefault();
            Require(
                snapshot is { Status: PocketAppHealthStatus.Healthy, DisableSuggested: false },
                "health_use_recovers");

            for (var offset = 1; offset <= 3; offset++)
            {
                store.RecordActivationFailure(appId, unusedAt + TimeSpan.FromSeconds(offset));
            }
            snapshot = store.Snapshots([enabled], [], unusedAt + TimeSpan.FromSeconds(3)).FirstOrDefault();
            Require(
                snapshot is
                {
                    Status: PocketAppHealthStatus.Attention,
                    ReasonCode: "ACTIVATION_FAILURES",
                    ConsecutiveActivationFailures: 3
                },
                "health_activation_failures");

            var recoveredAt = unusedAt + TimeSpan.FromSeconds(4);
            store.RecordActivationSuccess(appId, recoveredAt);
            snapshot = store.Snapshots([enabled], [], recoveredAt).FirstOrDefault();
            Require(
                snapshot is
                {
                    Status: PocketAppHealthStatus.Healthy,
                    ConsecutiveActivationFailures: 0
                },
                "health_activation_recovery");
            snapshot = store.Snapshots([disabled], [], recoveredAt).FirstOrDefault();
            Require(
                snapshot is { Status: PocketAppHealthStatus.Disabled, DisableSuggested: false },
                "health_disabled_no_suggestion");

            var recordPath = Path.Combine(root, $"{appId}.json");
            store.RecordUse(appId, recoveredAt);
            var beforeSoak = File.ReadAllBytes(recordPath);
            for (var index = 0; index < 512; index++)
            {
                store.RecordUse(appId, recoveredAt + TimeSpan.FromMilliseconds(index * 250));
            }
            var afterSoak = File.ReadAllBytes(recordPath);
            Require(beforeSoak.AsSpan().SequenceEqual(afterSoak), "health_usage_debounce");
            var remaining = Directory.EnumerateFileSystemEntries(root).ToArray();
            Require(
                remaining.Length == 1
                    && Path.GetFileName(remaining[0]) == $"{appId}.json"
                    && !File.GetAttributes(remaining[0]).HasFlag(FileAttributes.ReparsePoint),
                "health_soak_atomic_cleanup");

            const string corruptId = "local.generated.corrupt";
            File.WriteAllText(Path.Combine(root, $"{corruptId}.json"), "not-json");
            snapshot = store.Snapshots(
                [Package(corruptId, PocketAppLifecycleState.Enabled)],
                [],
                recoveredAt).FirstOrDefault();
            Require(
                snapshot is
                {
                    Status: PocketAppHealthStatus.Attention,
                    ReasonCode: "HEALTH_METADATA_CORRUPT",
                    DisableSuggested: false
                },
                "health_corrupt_fail_safe");

            VerifySymlinkFailSafe(store, root, corruptId, recoveredAt);
        }
        catch (Exception exception)
        {
            _failures.Add($"health_verification:{exception.GetType().Name}:{exception.Message}");
        }
        finally
        {
            try { if (Directory.Exists(root)) { Directory.Delete(root, recursive: true); } } catch { }
        }
        return _failures;
    }

    private void VerifySymlinkFailSafe(
        PocketAppHealthStore store,
        string root,
        string corruptId,
        DateTimeOffset now)
    {
        const string linkedId = "local.generated.linked";
        try
        {
            _ = File.CreateSymbolicLink(
                Path.Combine(root, $"{linkedId}.json"),
                Path.Combine(root, $"{corruptId}.json"));
            var snapshot = store.Snapshots(
                [Package(linkedId, PocketAppLifecycleState.Enabled)],
                [],
                now).FirstOrDefault();
            Require(
                snapshot is { Status: PocketAppHealthStatus.Attention, DisableSuggested: false },
                "health_symlink_fail_safe");

            const string danglingId = "local.generated.dangling";
            _ = File.CreateSymbolicLink(
                Path.Combine(root, $"{danglingId}.json"),
                Path.Combine(root, "missing.json"));
            snapshot = store.Snapshots(
                [Package(danglingId, PocketAppLifecycleState.Enabled)],
                [],
                now).FirstOrDefault();
            Require(
                snapshot is { Status: PocketAppHealthStatus.Attention, DisableSuggested: false },
                "health_dangling_symlink_fail_safe");
        }
        catch (UnauthorizedAccessException)
        {
        }
        catch (IOException exception) when (
            OperatingSystem.IsWindows()
            && exception.HResult == WindowsPrivilegeNotHeldHResult)
        {
        }
        catch (PlatformNotSupportedException)
        {
        }
    }

    private static PocketAppManagedPackage Package(string appId, PocketAppLifecycleState state) =>
        new(
            appId,
            state,
            "1.0.0",
            $"sha256:{new string('a', 64)}",
            ["1.0.0"]);

    private void Require(bool condition, string label)
    {
        if (!condition) { _failures.Add(label); }
    }
}
