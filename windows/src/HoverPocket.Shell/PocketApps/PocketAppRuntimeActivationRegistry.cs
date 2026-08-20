using HoverPocket.Shell.Capabilities;
using HoverPocket.Shell.Configuration;

namespace HoverPocket.Shell.PocketApps;

internal sealed record PocketAppRuntimeReadback(
    string AppId,
    string? Version,
    string? PackageDigest,
    IReadOnlyList<string> EffectivePermissions)
{
    public bool Matches(PocketAppLifecycleReceipt receipt) =>
        string.Equals(AppId, receipt.PackageId, StringComparison.Ordinal)
        && string.Equals(Version, receipt.Version, StringComparison.Ordinal)
        && string.Equals(PackageDigest, receipt.PackageDigest, StringComparison.Ordinal)
        && EffectivePermissions.Order(StringComparer.Ordinal).SequenceEqual(
            receipt.EffectivePermissions.Order(StringComparer.Ordinal),
            StringComparer.Ordinal);
}

internal sealed class PocketAppRuntimeActivationException(string code) : Exception(code)
{
    public string Code { get; } = code;
}

internal sealed class PocketAppActivationLease
{
    private int _active = 1;
    private readonly CancellationTokenSource _cancellation = new();

    public bool IsActive => Volatile.Read(ref _active) == 1;

    public CancellationToken CancellationToken => _cancellation.Token;

    public void RequireActive()
    {
        if (!IsActive)
        {
            throw new PocketAppRuntimeActivationException("RUNTIME_ACTIVATION_UNAVAILABLE");
        }
    }

    public void Invalidate()
    {
        if (Interlocked.Exchange(ref _active, 0) == 1)
        {
            _cancellation.Cancel();
        }
    }
}

internal sealed class PocketExecutionRuntimeRegistry
{
    private sealed record Entry(
        PocketAppRuntimeReadback Readback,
        object RuntimeHandle,
        PocketAppActivationLease? ActivationLease);
    private readonly Dictionary<string, Entry> _entries = new(StringComparer.Ordinal);
    private readonly object _sync = new();

    public IReadOnlyList<string> ActiveAppIds
    {
        get
        {
            lock (_sync) { return _entries.Keys.Order(StringComparer.Ordinal).ToArray(); }
        }
    }

    public PocketAppExecutionRuntime? Runtime(string appId)
    {
        lock (_sync)
        {
            return _entries.TryGetValue(appId, out var entry)
                ? entry.RuntimeHandle as PocketAppExecutionRuntime
                : null;
        }
    }

    public PocketAppRuntimeReadback? Readback(string appId)
    {
        lock (_sync) { return _entries.TryGetValue(appId, out var entry) ? entry.Readback : null; }
    }

    internal void Activate(
        PocketAppRuntimeReadback readback,
        object runtimeHandle,
        PocketAppActivationLease? activationLease)
    {
        lock (_sync)
        {
            if (_entries.Remove(readback.AppId, out var previous))
            {
                previous.ActivationLease?.Invalidate();
                DisposeRuntime(previous.RuntimeHandle);
            }
            _entries[readback.AppId] = new Entry(readback, runtimeHandle, activationLease);
        }
    }

    internal void Deactivate(string appId)
    {
        lock (_sync)
        {
            if (_entries.Remove(appId, out var previous))
            {
                previous.ActivationLease?.Invalidate();
                DisposeRuntime(previous.RuntimeHandle);
            }
        }
    }

    private static void DisposeRuntime(object runtimeHandle)
    {
        if (runtimeHandle is IDisposable disposable) { disposable.Dispose(); }
    }
}

internal sealed class PocketSurfaceRegistry
{
    internal sealed record Route(
        string AppId,
        string ProviderId,
        string SurfaceId,
        string Title);

    private sealed record Entry(
        PocketAppRuntimeReadback Readback,
        object HostHandle,
        IReadOnlySet<string> SurfaceIds);

    private readonly Dictionary<string, Entry> _entries = new(StringComparer.Ordinal);
    private readonly object _sync = new();

    public IReadOnlyList<string> ActiveAppIds
    {
        get
        {
            lock (_sync) { return _entries.Keys.Order(StringComparer.Ordinal).ToArray(); }
        }
    }

    public IReadOnlyList<Route> Routes
    {
        get
        {
            lock (_sync)
            {
                return _entries.Values
                    .Select(entry =>
                    {
                        var surfaceId = entry.SurfaceIds.Contains("main")
                            ? "main"
                            : entry.SurfaceIds.Order(StringComparer.Ordinal).FirstOrDefault();
                        if (surfaceId is null) { return null; }
                        var host = entry.HostHandle as PocketAppHostController;
                        return new Route(
                            entry.Readback.AppId,
                            GeneratedProviderId(entry.Readback.AppId),
                            surfaceId,
                            host?.AppName ?? entry.Readback.AppId);
                    })
                    .Where(route => route is not null)
                    .Cast<Route>()
                    .OrderBy(route => route.ProviderId, StringComparer.Ordinal)
                    .ToArray();
            }
        }
    }

    public PocketAppRuntimeReadback? Readback(string appId)
    {
        lock (_sync) { return _entries.TryGetValue(appId, out var entry) ? entry.Readback : null; }
    }

    public PocketAppHostController? HostController(string appId, string? surfaceId = null)
    {
        lock (_sync)
        {
            if (!_entries.TryGetValue(appId, out var entry)
                || (surfaceId is not null && !entry.SurfaceIds.Contains(surfaceId)))
            {
                return null;
            }
            return entry.HostHandle as PocketAppHostController;
        }
    }

    public static string GeneratedProviderId(string appId) =>
        $"generated-pocket-app:{appId}";

    public static string GeneratedSurfaceRouteId(string appId, string surfaceId) =>
        $"{GeneratedProviderId(appId)}/{surfaceId}";

    internal void Activate(
        PocketAppRuntimeReadback readback,
        object hostHandle,
        IReadOnlySet<string> surfaceIds)
    {
        lock (_sync) { _entries[readback.AppId] = new Entry(readback, hostHandle, surfaceIds); }
    }

    internal void Deactivate(string appId)
    {
        lock (_sync) { _entries.Remove(appId); }
    }
}

internal sealed class PocketAppRuntimeActivationRegistry : IDisposable
{
    internal sealed record Candidate(
        PocketAppRuntimeReadback Readback,
        object RuntimeHandle,
        object HostHandle,
        IReadOnlySet<string> SurfaceIds,
        PocketAppActivationLease? ActivationLease);

    private static readonly IReadOnlySet<string> ReservedAppIds =
        new HashSet<string>(["local.example.today-focus"], StringComparer.Ordinal);

    private readonly PocketAppLifecycleManager? _sourceLifecycle;
    private readonly Func<PocketAppManagementSnapshot> _managementSnapshotSource;
    private readonly Func<string, Candidate?> _candidateSource;
    private readonly Func<string, bool> _restoreFailurePersistence;
    private readonly Func<string, bool>? _failureInjection;
    private readonly object _activationSync = new();
    private bool _enabled = true;
    private bool _disposed;

    public PocketExecutionRuntimeRegistry ExecutionRegistry { get; } = new();
    public PocketSurfaceRegistry SurfaceRegistry { get; } = new();

    public bool TryGetManagedAppIds(out IReadOnlyList<string> appIds)
    {
        lock (_activationSync)
        {
            if (_disposed)
            {
                appIds = Array.Empty<string>();
                return false;
            }
            try
            {
                appIds = _managementSnapshotSource().Packages
                    .Where(package => package.State != PocketAppLifecycleState.Removed)
                    .Select(package => package.PackageId)
                    .Distinct(StringComparer.Ordinal)
                    .Order(StringComparer.Ordinal)
                    .ToArray();
                return true;
            }
            catch
            {
                appIds = Array.Empty<string>();
                return false;
            }
        }
    }

    public PocketAppRuntimeActivationRegistry(
        string rootDirectory,
        string userDataRoot,
        CapabilityBroker broker,
        string userId,
        Func<UserSettings> settings,
        Func<string, bool>? failureInjection = null)
    {
        var lifecycle = new PocketAppLifecycleManager(
            rootDirectory,
            userDataRoot,
            performStartupRecovery: true);
        _sourceLifecycle = lifecycle;
        _managementSnapshotSource = lifecycle.ManagementSnapshot;
        _candidateSource = packageId =>
        {
            var package = lifecycle.ActivePackageForActivation(packageId);
            if (package is null) { return null; }
            var effectivePermissions = package.Manifest.RequestedCapabilities
                .SelectMany(item => item.Permissions)
                .Distinct(StringComparer.Ordinal)
                .Order(StringComparer.Ordinal)
                .ToArray();
            PocketAppUserStateStore? stateStore = null;
            PocketAppActivationLease? activationLease = null;
            PocketAppExecutionRuntime? runtime = null;
            try
            {
                stateStore = new PocketAppUserStateStore(
                    package.Manifest.Id,
                    package.StatePropertyTypes,
                    userDataRoot);
                activationLease = new PocketAppActivationLease();
                runtime = new PocketAppExecutionRuntime(
                    package,
                    broker,
                    userId,
                    effectivePermissions.ToHashSet(StringComparer.Ordinal),
                    userStateStore: stateStore,
                    activationLease: activationLease);
                var host = new PocketAppHostController(runtime, settings);
                return new Candidate(
                    new PocketAppRuntimeReadback(
                        package.Manifest.Id,
                        package.Manifest.Version,
                        package.ManifestDigest,
                        effectivePermissions),
                    runtime,
                    host,
                    package.Surfaces.Keys.ToHashSet(StringComparer.Ordinal),
                    activationLease);
            }
            catch
            {
                activationLease?.Invalidate();
                if (runtime is not null) { runtime.Dispose(); }
                else { stateStore?.Dispose(); }
                throw;
            }
        };
        _restoreFailurePersistence = packageId =>
        {
            try
            {
                var receipt = lifecycle.Disable(packageId);
                var observed = lifecycle.DurableManagedPackage(packageId);
                return receipt.State == PocketAppLifecycleState.Disabled
                    && receipt.EffectivePermissions.Count == 0
                    && observed is not null
                    && observed.State == PocketAppLifecycleState.Disabled
                    && observed.Version == receipt.Version
                    && observed.PackageDigest == receipt.PackageDigest;
            }
            catch
            {
                return false;
            }
        };
        _failureInjection = failureInjection;
    }

    internal PocketAppRuntimeActivationRegistry(
        Func<IReadOnlyList<PocketAppManagedPackage>> managedPackagesSource,
        Func<string, Candidate?> candidateSource,
        Func<IReadOnlyList<PocketAppManagementIssue>>? managementIssuesSource = null,
        Func<string, bool>? restoreFailurePersistence = null,
        Func<string, bool>? failureInjection = null)
    {
        _managementSnapshotSource = () => new PocketAppManagementSnapshot(
            managedPackagesSource(),
            managementIssuesSource?.Invoke() ?? Array.Empty<PocketAppManagementIssue>());
        _candidateSource = candidateSource;
        _restoreFailurePersistence = restoreFailurePersistence ?? (_ => false);
        _failureInjection = failureInjection;
    }

    public PocketAppRuntimeReadback Synchronize(PocketAppLifecycleReceipt receipt)
    {
        lock (_activationSync)
        {
            return SynchronizeLocked(receipt);
        }
    }

    private PocketAppRuntimeReadback SynchronizeLocked(PocketAppLifecycleReceipt receipt)
    {
        ThrowIfDisposed();
        if (ReservedAppIds.Contains(receipt.PackageId))
        {
            FailClosed(receipt.PackageId);
            throw Failure("RUNTIME_ACTIVATION_RESERVED_ID");
        }

        if (receipt.State == PocketAppLifecycleState.Enabled)
        {
            if (!_enabled)
            {
                FailClosed(receipt.PackageId);
                throw Failure("RUNTIME_ACTIVATION_UNAVAILABLE");
            }
            var candidate = _candidateSource(receipt.PackageId);
            if (candidate is null)
            {
                FailClosed(receipt.PackageId);
                throw Failure("RUNTIME_ACTIVATION_READBACK_MISMATCH");
            }
            if (!candidate.Readback.Matches(receipt))
            {
                DisposeCandidate(candidate);
                FailClosed(receipt.PackageId);
                throw Failure("RUNTIME_ACTIVATION_READBACK_MISMATCH");
            }
            return Activate(candidate);
        }

        if (receipt.EffectivePermissions.Count != 0)
        {
            FailClosed(receipt.PackageId);
            throw Failure("RUNTIME_ACTIVATION_READBACK_MISMATCH");
        }
        FailClosed(receipt.PackageId);
        if (ExecutionRegistry.Readback(receipt.PackageId) is not null
            || SurfaceRegistry.Readback(receipt.PackageId) is not null)
        {
            throw Failure("RUNTIME_ACTIVATION_READBACK_MISMATCH");
        }
        return new PocketAppRuntimeReadback(
            receipt.PackageId,
            receipt.Version,
            receipt.PackageDigest,
            Array.Empty<string>());
    }

    public IReadOnlyList<string> RestoreEnabledApps()
    {
        lock (_activationSync)
        {
            return RestoreEnabledAppsLocked();
        }
    }

    private IReadOnlyList<string> RestoreEnabledAppsLocked()
    {
        ThrowIfDisposed();
        if (!_enabled) { return ["*"]; }
        PocketAppManagementSnapshot snapshot;
        try
        {
            snapshot = _managementSnapshotSource();
        }
        catch
        {
            return ["*"];
        }

        var failures = snapshot.Issues.Select(item => item.PackageId).ToList();
        foreach (var issue in snapshot.Issues)
        {
            FailClosed(issue.PackageId);
            _ = _restoreFailurePersistence(issue.PackageId);
        }
        foreach (var package in snapshot.Packages.OrderBy(item => item.PackageId, StringComparer.Ordinal))
        {
            if (package.State != PocketAppLifecycleState.Enabled)
            {
                FailClosed(package.PackageId);
                continue;
            }
            try
            {
                if (ReservedAppIds.Contains(package.PackageId))
                {
                    throw Failure("RUNTIME_ACTIVATION_RESERVED_ID");
                }
                var candidate = _candidateSource(package.PackageId);
                if (candidate is null
                    || candidate.Readback.AppId != package.PackageId
                    || candidate.Readback.Version != package.Version
                    || candidate.Readback.PackageDigest != package.PackageDigest)
                {
                    DisposeCandidate(candidate);
                    throw Failure("RUNTIME_ACTIVATION_READBACK_MISMATCH");
                }
                _ = Activate(candidate);
            }
            catch
            {
                FailClosed(package.PackageId);
                _ = _restoreFailurePersistence(package.PackageId);
                failures.Add(package.PackageId);
            }
        }
        return failures.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray();
    }

    public void Dispose()
    {
        lock (_activationSync)
        {
            if (_disposed) { return; }
            _enabled = false;
            RevokeAllLocked();
            _sourceLifecycle?.Dispose();
            _disposed = true;
        }
    }

    public void Shutdown()
    {
        SetEnabled(false);
    }

    public void SetEnabled(bool enabled)
    {
        lock (_activationSync)
        {
            ThrowIfDisposed();
            _enabled = enabled;
            if (!enabled)
            {
                RevokeAllLocked();
            }
        }
    }

    private void RevokeAllLocked()
    {
        foreach (var appId in ExecutionRegistry.ActiveAppIds
            .Concat(SurfaceRegistry.ActiveAppIds)
            .Distinct(StringComparer.Ordinal))
        {
            FailClosed(appId);
        }
    }

    private PocketAppRuntimeReadback Activate(Candidate candidate)
    {
        if (_failureInjection?.Invoke("before_runtime_registry_commit") == true)
        {
            FailClosed(candidate.Readback.AppId);
            DisposeCandidate(candidate);
            throw Failure("RUNTIME_ACTIVATION_UNAVAILABLE");
        }
        if (!_enabled)
        {
            FailClosed(candidate.Readback.AppId);
            DisposeCandidate(candidate);
            throw Failure("RUNTIME_ACTIVATION_UNAVAILABLE");
        }

        ExecutionRegistry.Activate(
            candidate.Readback,
            candidate.RuntimeHandle,
            candidate.ActivationLease);
        SurfaceRegistry.Activate(candidate.Readback, candidate.HostHandle, candidate.SurfaceIds);

        if (_failureInjection?.Invoke("runtime_readback_mismatch") == true
            || ExecutionRegistry.Readback(candidate.Readback.AppId) != candidate.Readback
            || SurfaceRegistry.Readback(candidate.Readback.AppId) != candidate.Readback)
        {
            FailClosed(candidate.Readback.AppId);
            throw Failure("RUNTIME_ACTIVATION_READBACK_MISMATCH");
        }
        return candidate.Readback;
    }

    private static void DisposeCandidate(Candidate? candidate)
    {
        if (candidate is null) { return; }
        candidate.ActivationLease?.Invalidate();
        if (candidate.RuntimeHandle is IDisposable disposable) { disposable.Dispose(); }
    }

    private void FailClosed(string appId)
    {
        SurfaceRegistry.Deactivate(appId);
        ExecutionRegistry.Deactivate(appId);
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }

    private static PocketAppRuntimeActivationException Failure(string code) => new(code);
}
