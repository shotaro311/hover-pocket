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
            }
        }
    }
}

internal sealed class PocketSurfaceRegistry
{
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
    private readonly Func<IReadOnlyList<PocketAppManagedPackage>> _managedPackagesSource;
    private readonly Func<string, Candidate?> _candidateSource;
    private readonly Func<string, bool>? _failureInjection;
    private bool _disposed;

    public PocketExecutionRuntimeRegistry ExecutionRegistry { get; } = new();
    public PocketSurfaceRegistry SurfaceRegistry { get; } = new();

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
        _managedPackagesSource = lifecycle.ManagedPackages;
        _candidateSource = packageId =>
        {
            var package = lifecycle.ActivePackageForActivation(packageId);
            if (package is null) { return null; }
            var effectivePermissions = package.Manifest.RequestedCapabilities
                .SelectMany(item => item.Permissions)
                .Distinct(StringComparer.Ordinal)
                .Order(StringComparer.Ordinal)
                .ToArray();
            var stateStore = new PocketAppUserStateStore(
                package.Manifest.Id,
                package.StatePropertyNames,
                userDataRoot);
            var activationLease = new PocketAppActivationLease();
            var runtime = new PocketAppExecutionRuntime(
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
        };
        _failureInjection = failureInjection;
    }

    internal PocketAppRuntimeActivationRegistry(
        Func<IReadOnlyList<PocketAppManagedPackage>> managedPackagesSource,
        Func<string, Candidate?> candidateSource,
        Func<string, bool>? failureInjection = null)
    {
        _managedPackagesSource = managedPackagesSource;
        _candidateSource = candidateSource;
        _failureInjection = failureInjection;
    }

    public PocketAppRuntimeReadback Synchronize(PocketAppLifecycleReceipt receipt)
    {
        ThrowIfDisposed();
        if (ReservedAppIds.Contains(receipt.PackageId))
        {
            FailClosed(receipt.PackageId);
            throw Failure("RUNTIME_ACTIVATION_RESERVED_ID");
        }

        if (receipt.State == PocketAppLifecycleState.Enabled)
        {
            var candidate = _candidateSource(receipt.PackageId);
            if (candidate is null || !candidate.Readback.Matches(receipt))
            {
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
        ThrowIfDisposed();
        IReadOnlyList<PocketAppManagedPackage> packages;
        try
        {
            packages = _managedPackagesSource();
        }
        catch
        {
            return ["*"];
        }

        var failures = new List<string>();
        foreach (var package in packages.OrderBy(item => item.PackageId, StringComparer.Ordinal))
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
                    throw Failure("RUNTIME_ACTIVATION_READBACK_MISMATCH");
                }
                _ = Activate(candidate);
            }
            catch
            {
                FailClosed(package.PackageId);
                failures.Add(package.PackageId);
            }
        }
        return failures;
    }

    public void Dispose()
    {
        if (_disposed) { return; }
        foreach (var appId in ExecutionRegistry.ActiveAppIds
            .Concat(SurfaceRegistry.ActiveAppIds)
            .Distinct(StringComparer.Ordinal))
        {
            FailClosed(appId);
        }
        _sourceLifecycle?.Dispose();
        _disposed = true;
    }

    private PocketAppRuntimeReadback Activate(Candidate candidate)
    {
        if (_failureInjection?.Invoke("before_runtime_registry_commit") == true)
        {
            FailClosed(candidate.Readback.AppId);
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
